#lang racket/base
;; Who is asking: the session cookie into a user, and a user into a session cookie.
(require racket/contract/base db web-server/http
         "session.rkt" "../config.rkt" "../db/accounts.rkt" "../domain.rkt")
(provide (contract-out
          [request-user (-> connection? config? request? (or/c user? #f))]
          [session-cookie (-> connection? config? id/c header?)]))

;; Connection Config Request -> (or User #f)
;; the logged-in user: #f without a valid cookie, when the user no longer exists or when the cookie
;; was issued under an older session epoch
(define (request-user c cfg req)
  (define t (request-login-token req cfg))
  (and t (get-session-user c (login-token-user-id t) (login-token-epoch t))))

;; Connection Config Id -> Header
;; the cookie that starts a session for the user, under their current epoch
(define (session-cookie c cfg id)
  (user-cookie id (session-epoch c id) cfg))
