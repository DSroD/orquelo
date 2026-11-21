#lang racket/base
;; SQL for users and their login credentials (see repo.rkt for the rest). Functions take a connection first and
;; return domain structs; the logic that combines them is in auth/users.rkt.
(require racket/contract/base racket/match db "query.rkt" "../domain.rkt")
(provide (contract-out
          [struct credential ([user-id id/c] [hash string?] [status status/c])]
          [get-user (-> connection? id/c (or/c user? #f))]
          [get-session-user (-> connection? id/c natural-number/c (or/c user? #f))]
          [session-epoch (-> connection? id/c natural-number/c)]
          [bump-session-epoch! (-> connection? id/c natural-number/c)]
          [set-user-status! (-> connection? id/c status/c void?)]
          [set-password! (-> connection? id/c string? void?)]
          [find-credential (-> connection? string? (or/c credential? #f))]
          [list-users (-> connection? (listof user?))]
          [count-users (-> connection? natural-number/c)]
          [find-user-id-by-verified-email (-> connection? string? (or/c id/c #f))]
          [create-user! (-> connection? (or/c string? #f) boolean? string? id/c)]
          [touch-login! (-> connection? id/c void?)]
          [storage-used (-> connection? id/c natural-number/c)]))

;; A Credential is a (credential Id String Status)
;; interp. a user's id, stored password hash and account status, for checking a password login
(struct credential (user-id hash status) #:transparent)

(define user-select
  "SELECT u.id, u.email, u.email_verified, u.name, u.status FROM users u")

;; Vector -> User
(define (row->user r)
  (match-define (vector id email verified? name status) r)
  (user id (if (sql-null? email) #f email) verified? name status))

(define-query (get-user c id) #:maybe-row row->user
  user-select " WHERE u.id=$1")

;; Connection Id Natural -> (or User #f)
;; the user when the session epoch of a cookie is still current
(define-query (get-session-user c id epoch) #:maybe-row row->user
  user-select " WHERE u.id=$1 AND u.session_epoch=$2")

;; Connection Id -> Natural
;; the user's current session epoch (the user exists)
(define-query (session-epoch c id) #:value
  "SELECT session_epoch FROM users WHERE id=$1")

;; Connection Id -> Natural
;; ends every session of the user (their old cookies stop matching); the new epoch
(define-query (bump-session-epoch! c id) #:value
  "UPDATE users SET session_epoch = session_epoch + 1 WHERE id=$1 RETURNING session_epoch")

;; Connection Id Status -> Void
;; a suspension also ends the user's sessions, in the same statement
(define-query (set-user-status! c id status) #:exec
  "UPDATE users SET status=$2::text, session_epoch = session_epoch + (CASE WHEN $2::text='suspended' THEN 1 ELSE 0 END)
    WHERE id=$1")

;; Connection Id String -> Void
;; stores the password hash (see auth/password.rkt) as the user's only one
(define-query (set-password! c id hash) #:exec
  "INSERT INTO password_credentials (user_id, hash) VALUES ($1, $2)
   ON CONFLICT (user_id) DO UPDATE SET hash=EXCLUDED.hash, updated_at=now()")

;; Vector -> Credential
(define (row->credential r)
  (match-define (vector id hash status) r)
  (credential id hash status))

;; Connection String -> (or Credential #f)
;; the credential of the user whose verified email is `email` (any case)
(define-query (find-credential c email) #:maybe-row row->credential
  "SELECT u.id, p.hash, u.status FROM users u JOIN password_credentials p ON p.user_id=u.id
    WHERE u.email_verified AND lower(u.email)=lower($1)")

;; Connection -> [Listof User]
;; every user, oldest first
(define-query (list-users c) #:rows row->user
  user-select " ORDER BY u.id")

;; Connection -> Natural
;; counts all registered accounts, including suspended accounts
(define-query (count-users c) #:value
  "SELECT count(*) FROM users")

(define-query (find-user-id-by-verified-email c email) #:maybe-value
  "SELECT id FROM users WHERE email_verified AND lower(email)=lower($1)")

;; email is kept for display even when not trusted
(define-query (create-user! c [email #:nullable] verified? name) #:value
  "INSERT INTO users (email, email_verified, name) VALUES ($1, $2, $3) RETURNING id")

(define-query (touch-login! c id) #:exec "UPDATE users SET last_login_at=now() WHERE id=$1")

(define-query (storage-used c id) #:value
  "SELECT COALESCE(SUM(pdf_bytes), 0)::bigint FROM presentations WHERE owner_id=$1")
