#lang racket/base
;; Password login (POST /auth/password) and password change (PUT /api/me/password). Part of the core
;; edition's plugin.
(require racket/contract/base racket/list racket/string web-server/dispatch web-server/http
         "../auth/password.rkt" "../auth/session.rkt" "../auth/throttle.rkt" "../auth/users.rkt"
         "../config.rkt" "../db/accounts.rkt" "../domain.rkt" "../edition.rkt"
         "client-ip.rkt" "deps.rkt" "endpoint.rkt" "inputs.rkt" "json.rkt")
(provide (contract-out
          [make-password-routes (-> throttle? boolean? routes/c)]))

;; Throttle Boolean -> Routes
;; POST /auth/password and PUT /api/me/password; everything else goes to the fallback
(define ((make-password-routes throttle trust-proxy?) kit fallback)
  (define d (route-kit-deps kit))
  (define db (deps-db d))
  (define named (route-kit-named kit))
  (define signed-in (route-kit-signed-in kit))
  (define check-origin! (route-kit-check-origin! kit))

  ;; String String -> Void
  ;; 429 when the pair is backing off
  (define (check-throttle! email ip)
    (define wait (throttle-wait throttle email ip))
    (when wait (throttled! wait)))

  ;; String String (or Credential #f) -> Void
  ;; 401 unless `password` matches the credential; strikes the pair otherwise. The scrypt check runs
  ;; with the pooled connection released. A stale hash is replaced by a current one.
  (define (verify! email ip password cred)
    (define verdict (after-db d (λ () (check-password password (and cred (credential-hash cred))))))
    (unless verdict
      (throttle-fail! throttle email ip)
      (api-error! 401 "invalid_credentials" "wrong email or password"))
    (when (eq? verdict 'rehash) (set-password! db (credential-user-id cred) (hash-password password))))

  (define-endpoint (login d req)
    #:json [in (login-input [email (string 1 320)] [password (string 1 1024)])]
    (define email (string-downcase (string-trim (login-input-email in))))
    (define ip (client-ip req trust-proxy?))
    (check-throttle! email ip)
    (define cred (find-credential db email))
    (verify! email ip (login-input-password in) cred)
    (when (equal? (credential-status cred) "suspended") (api-error! 403 "suspended" "account suspended"))
    (throttle-clear! throttle email ip)
    (touch-login! db (credential-user-id cred))
    (no-content #:headers (list (session-cookie db (deps-cfg d) (credential-user-id cred)))))

  (define-endpoint (change-password d req me)
    #:json [in (password-change-input [current (string 1 1024)] [new (string 1 1024)])]
    (define email (or (user-email me) (number->string (user-id me))))
    (define ip (client-ip req trust-proxy?))
    (check-throttle! email ip)
    (verify! email ip (password-change-input-current in) (and (user-email me) (find-credential db (user-email me))))
    (unless (valid-new-password? (password-change-input-new in))
      (api-error! 422 "invalid" "the new password must be 10 to 1024 bytes" "new"))
    (define hash (after-db d (λ () (hash-password (password-change-input-new in)))))
    (replace-password! db (user-id me) hash)
    (throttle-clear! throttle email ip)
    (no-content #:headers (list (session-cookie db (deps-cfg d) (user-id me)))))

  ;; (-> Response) -> Response
  ;; the thunk's response, or the 429 when a throttle refused it
  (define (or-429 thunk)
    (with-handlers ([exn:throttled? (λ (e) (too-many-requests (exn:throttled-seconds e)))])
      (thunk)))

  (define-values (dispatch _url)
    (dispatch-rules
     [("auth" "password") #:method "post"
      (named "/auth/password" (λ (req) (check-origin! req) (or-429 (λ () (login d req)))))]
     [("api" "me" "password") #:method "put"
      (signed-in "/api/me/password" (λ (d req me) (or-429 (λ () (change-password d req me)))))]
     [else fallback]))
  dispatch)
