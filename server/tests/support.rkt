#lang racket/base
;; Shared helpers for integration tests (need TEST_DATABASE_URL, see scripts/with-ephemeral-pg).
(require racket/runtime-path racket/list racket/promise racket/string db "../auth/password.rkt" "../db/accounts.rkt" "../db/conn.rkt"
         "../db/migrate.rkt" "../db/repo.rkt" "../domain.rkt" "http-client.rkt")
(provide test-db-url migrations-dir test-sources fresh-db! new-owner! new-deck! reset-oauth-users!
         test-password ensure-password-user! login-cookie!)

(define-runtime-path migrations-dir "../migrations")

;; [Listof MigrationSource]
;; core's migrations, as the tests apply them
(define test-sources (list (migration-source "core" migrations-dir)))

(define (test-db-url) (getenv "TEST_DATABASE_URL"))

;; [Listof MigrationSource] -> Connection
;; a direct connection to a freshly migrated, empty schema
(define (fresh-db! [sources test-sources])
  (define c (connect-direct (test-db-url)))
  (query-exec c "DROP SCHEMA public CASCADE")
  (query-exec c "CREATE SCHEMA public")
  (migrate! c sources)
  c)

;; Connection [(listof Natural)] -> Void
;; empties the OAuth tables and the users, then creates users with exactly these ids (the subjects
;; the OAuth tests grant to)
(define (reset-oauth-users! c [ids '(7 8)])
  (query-exec c "DELETE FROM oauth_clients")
  (query-exec c "DELETE FROM oauth_pending")
  (query-exec c "DELETE FROM users")
  (for ([id (in-list ids)])
    (query-exec c "INSERT INTO users (id) OVERRIDING SYSTEM VALUE VALUES ($1)" id)))

;; Connection -> Id
;; a new user with a verified, unique email, to own decks in tests
(define (new-owner! c)
  (define n (query-value c "SELECT count(*) FROM users"))
  (create-user! c (format "owner~a@example.org" n) #t "Owner"))

;; Connection Id String Natural [Natural] -> Id
;; a new deck of `bytes` bytes (its key still pending) owned by `owner`
(define (new-deck! c owner title page-count [bytes 0])
  (add-presentation! c (λ (c id) (limits 104857600 #f #f)) owner title page-count bytes))


;; String
;; the password of the users the tests create
(define test-password "correct horse battery")

;; the hash of test-password, computed once: scrypt costs ~60 ms
(define test-hash (delay (hash-password test-password)))

;; Connection String -> Id
;; the user with this verified email (created when missing), set to log in with test-password
(define (ensure-password-user! c email)
  (define id (or (find-user-id-by-verified-email c email)
                 (create-user! c email #t (car (string-split email "@")))))
  (set-password! c id (force test-hash))
  id)

;; String [String] -> String
;; logs `email` in at the server under `current-base` with a password and returns the session cookie as
;; "orquelo_user=<value>"
(define (login-cookie! email [password test-password])
  (define r (http "POST" "/auth/password" #:json (hasheq 'email email 'password password)))
  (define set-cookie (and (= (resp-status r) 204) (resp-header r "Set-Cookie")))
  (unless set-cookie (error 'login-cookie! "login of ~a was refused: ~a" email (resp-status r)))
  (car (string-split set-cookie ";")))

(module+ test)
