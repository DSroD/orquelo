#lang racket/base
;; The shared OAuth store suite against Postgres, plus what only a database has: foreign-key cascades.
(require rackunit rackunit/text-ui db "support.rkt" "../db/conn.rkt" "../db/oauth-store.rkt"
         "../oauth/data.rkt" "../oauth/store.rkt" "../oauth/store-suite.rkt")

;; OAuthStore String -> Void
;; a code, an access token and a refresh token of the grant
(define (put-credentials! st gid)
  (store-code-put! st (code-record #"code" gid "https://app.example/cb" #t "chal" "r" '("decks") 100))
  (store-token-put! st (token-record #"at" gid 'access '("decks") "r" 100))
  (store-token-put! st (token-record #"rt" gid 'refresh '("decks") "r" 100)))

;; Connection -> Boolean
;; does any grant, code or token remain?
(define (credentials-left? c)
  (for/or ([t '("oauth_codes" "oauth_access_tokens" "oauth_refresh_tokens" "oauth_grants")])
    (> (query-value c (string-append "SELECT count(*) FROM " t)) 0)))

;; Connection Connection -> Void
(define (cascade-tests c pool)
  (define st (make-pg-oauth-store pool))
  (define (setup!)
    (reset-oauth-users! c)
    (store-client-put! st (client "c1" 'registered "App" #f #f '("https://app.example/cb") #f 0 #f))
    (define g (store-grant-create! st 7 "c1" '("decks") 0 0))
    (put-credentials! st (grant-id g)))
  (test-case "deleting a user removes their grants, codes and tokens"
    (setup!)
    (check-true (credentials-left? c))
    (query-exec c "DELETE FROM users WHERE id=7")
    (check-false (credentials-left? c)))
  (test-case "deleting a client removes its grants, codes and tokens"
    (setup!)
    (query-exec c "DELETE FROM oauth_clients WHERE client_id='c1'")
    (check-false (credentials-left? c))))

(module+ test
  (cond
    [(test-db-url)
     (define c (fresh-db!))
     (define pool (make-pool (test-db-url)))
     (define (make-store) (reset-oauth-users! c) (make-pg-oauth-store pool))
     (check-equal? (run-tests (store-suite make-store) 'normal) 0)
     (cascade-tests c pool)]
    [else (eprintf "SKIPPED oauth-store-test: TEST_DATABASE_URL not set (use scripts/with-ephemeral-pg)\n")]))
