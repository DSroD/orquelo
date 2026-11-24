#lang racket/base
;; User session cookie, participant cookie, signed-cookie helpers and the safe return_to.
(require racket/contract/base racket/list racket/match racket/string net/cookies/server (except-in web-server/http make-cookie) web-server/http/id-cookie
         "../config.rkt" "../domain.rkt" "../live/codes.rkt")
(provide user-cookie-name
         (contract-out
          [struct login-token ([user-id id/c] [epoch natural-number/c])]
          [signed-cookie-header (->* (config? string? string? #:max-age exact-nonnegative-integer?) (#:path string?) header?)]
          [read-signed-cookie (->* (config? string? request?) (#:shelf-life real?) (or/c string? #f))]
          [clear-cookie-header* (->* (string?) (#:path string?) header?)]
          [request-login-token (-> request? config? (or/c login-token? #f))]
          [user-cookie (-> id/c natural-number/c config? header?)]
          [clear-user-cookie (-> header?)]
          [request-participant (-> request? string? (or/c string? #f))]
          [participant-cookie (-> string? id/c string? config? header?)]
          [remembered-participant (-> request? config? (or/c string? #f))]
          [participant-cookie-choice (-> request? config? (or/c boolean? 'null))]
          [participant-choice-cookie (-> request? config? boolean? header?)]
          [legacy-participant-headers (-> request? (listof header?))]))

(define user-cookie-name "orquelo_user")
(define participant-cookie-name "orquelo_participant")
(define remembered-cookie-name "orquelo_remember_participant")
(define legacy-cookie-name "orquelo_pid")
(define remember-path "/api/s")
(define remember-max-age (* 365 24 60 60))
(define user-max-age 43200)

;; Cookie -> Header
(define (set-cookie-header c) (make-header #"Set-Cookie" (cookie->set-cookie-header c)))

;; Config String String #:max-age Natural [#:path String] -> Header
;; Set-Cookie for an HMAC-signed, HttpOnly, SameSite=Lax cookie (Secure on https)
(define (signed-cookie-header cfg name value #:path [path "/"] #:max-age max-age)
  (set-cookie-header
   (make-id-cookie name value #:key (config-session-secret cfg) #:path path #:max-age max-age
                   #:http-only? #t #:secure? (config-secure? cfg) #:extension "SameSite=Lax")))

;; Config String Request [#:shelf-life Real] -> (or String #f)
;; the verified value of the signed cookie, or #f when absent, forged or older than shelf-life seconds
(define (read-signed-cookie cfg name req #:shelf-life [shelf +inf.0])
  (request-id-cookie name (config-session-secret cfg) req #:shelf-life shelf))

;; String [#:path String] -> Header
;; Set-Cookie that expires the cookie
(define (clear-cookie-header* name #:path [path "/"])
  (make-header #"Set-Cookie" (clear-cookie-header name #:path path)))

;; ------------------------------------------------------------------ user
;; A LoginToken is a (login-token Id Natural)
;; interp. the user and the session epoch the cookie was issued under
(struct login-token (user-id epoch) #:transparent)

;; Request Config -> (or LoginToken #f)
;; the token in the signed user cookie ("<id>.<epoch>"); it only says who logged in and when, not that
;; the user still exists or the epoch is current (db/accounts.rkt get-session-user checks that)
(define (request-login-token req cfg)
  (define v (read-signed-cookie cfg user-cookie-name req #:shelf-life user-max-age))
  (match (and v (regexp-match #px"^(\\d+)\\.(\\d+)$" v))
    [(list _ id epoch) (login-token (string->number id) (string->number epoch))]
    [_ #f]))

;; Id Natural Config -> Header
(define (user-cookie id epoch cfg)
  (signed-cookie-header cfg user-cookie-name (format "~a.~a" id epoch) #:max-age user-max-age))

;; -> Header
(define (clear-user-cookie) (clear-cookie-header* user-cookie-name))

;; ------------------------------------------------------------------ participant
;; Request String -> (or String #f)
;; finds the value of a named browser cookie
(define (cookie-value req name)
  (define c (findf (λ (c) (equal? (client-cookie-name c) name)) (request-cookies req)))
  (and c (client-cookie-value c)))

;; Request String -> (or String #f)
;; returns the participant ID only in the session for which the cookie was issued
(define (request-participant req code)
  (define value (cookie-value req participant-cookie-name))
  (match (and value (string-split value "."))
    [(list scope id) (and (equal? scope code) (valid-uuid? id) id)]
    [_ #f]))

;; String Id String Config -> Header
;; scopes the participant cookie to this live session's API
(define (participant-cookie id pid code cfg)
  (set-cookie-header
   (make-cookie participant-cookie-name (string-append code "." id)
                #:path (format "/api/s/~a/~a" pid code)
                #:http-only? #t #:secure? (config-secure? cfg) #:extension "SameSite=Lax")))

;; Request Config -> (or String #f)
;; only a signed opt-in can supply an identifier for a new session
(define (remembered-participant req cfg)
  (define value (read-signed-cookie cfg remembered-cookie-name req #:shelf-life remember-max-age))
  (and (valid-uuid? value) value))

;; Request Config -> (or Boolean 'null)
;; reports opt-in, refusal or no choice to the audience settings
(define (participant-cookie-choice req cfg)
  (cond [(remembered-participant req cfg) #t]
        [(equal? (cookie-value req remembered-cookie-name) "off") #f]
        [else 'null]))

;; Request Config Boolean -> Header
;; replaces the persistent identifier with a shared, non-identifying value on refusal
(define (participant-choice-cookie req cfg remember?)
  (if remember?
      (signed-cookie-header cfg remembered-cookie-name (or (remembered-participant req cfg) (random-uuid-v4))
                            #:path remember-path #:max-age remember-max-age)
      (set-cookie-header
       (make-cookie remembered-cookie-name "off" #:path remember-path #:max-age remember-max-age
                    #:http-only? #t #:secure? (config-secure? cfg) #:extension "SameSite=Lax"))))

;; Request -> [Listof Header]
;; retires the pre-consent root cookie without reusing its identifier
(define (legacy-participant-headers req)
  (if (cookie-value req legacy-cookie-name) (list (clear-cookie-header* legacy-cookie-name)) '()))

(module+ test
  (require rackunit)
  (define (cfg #:base [base "http://localhost:8080"])
    (load-config (hash-set minimal-env "PUBLIC_BASE_URL" base)))
  (define (hdr-value h) (bytes->string/utf-8 (header-value h)))
  (define (req-with-cookie name-value)
    (make-request #"GET" (string->url "/") (list (make-header #"Cookie" (string->bytes/utf-8 name-value)))
                  (delay '()) #f "127.0.0.1" 80 "127.0.0.1"))
  (require net/url racket/promise)

  (test-case "user cookie round trip"
    (define h (hdr-value (user-cookie 42 7 (cfg))))
    (check-regexp-match #rx"Max-Age=43200" h)
    (check-regexp-match #rx"HttpOnly" h)
    (check-regexp-match #rx"SameSite=Lax" h)
    (check-false (regexp-match? #rx"Secure" h))
    (define pair (car (string-split h "; ")))
    (check-equal? (request-login-token (req-with-cookie pair) (cfg)) (login-token 42 7)))
  (test-case "tampered, unsigned, legacy, malformed and foreign-key cookies are rejected"
    (define pair (car (string-split (hdr-value (user-cookie 42 0 (cfg))) "; ")))
    (define (token-of cookie) (request-login-token (req-with-cookie cookie) (cfg)))
    (check-false (token-of (string-append pair "x")))
    (check-false (token-of "orquelo_user=42.0"))
    (check-false (token-of "other=1"))
    (define (signed v) (car (string-split (hdr-value (signed-cookie-header (cfg) "orquelo_user" v #:max-age 60)) "; ")))
    (check-equal? (token-of (signed "42.0")) (login-token 42 0))
    (for ([bad '("42" "a@b.c" "-3.1" "3.-1" "3." ".3" "3.1.2" "3.x")])
      (check-false (token-of (signed bad)) bad)))
  (test-case "Secure only on https"
    (define c (struct-copy config (cfg) [public-base-url "https://x.cz"]))
    (check-regexp-match #rx"Secure" (hdr-value (user-cookie 1 0 c)))
    (check-regexp-match #rx"Secure" (hdr-value (participant-cookie (random-uuid-v4) 1 "abcdefghij" c))))
  (test-case "participant cookie is scoped in the browser and checked by the server"
    (define id (random-uuid-v4))
    (define h (hdr-value (participant-cookie id 1 "abcdefghij" (cfg))))
    (check-regexp-match #rx"Path=/api/s/1/abcdefghij" h)
    (check-false (regexp-match? #rx"Max-Age" h))
    (define req (req-with-cookie (car (string-split h "; "))))
    (check-equal? (request-participant req "abcdefghij") id)
    (check-false (request-participant req "klmnopqrst"))
    (check-false (request-participant (req-with-cookie (format "orquelo_pid=~a" id)) "abcdefghij")))
  (test-case "only explicit opt-in allows a persistent identifier"
    (define c (cfg))
    (define unknown (req-with-cookie (format "orquelo_pid=~a" (random-uuid-v4))))
    (define (updated req remember?)
      (req-with-cookie (car (string-split (hdr-value (participant-choice-cookie req c remember?)) "; "))))
    (check-equal? (participant-cookie-choice unknown c) 'null)
    (define opted-in (updated unknown #t))
    (define id (remembered-participant opted-in c))
    (check-true (valid-uuid? id))
    (check-true (participant-cookie-choice opted-in c))
    (check-equal? (remembered-participant (updated opted-in #t) c) id)
    (define opted-out (updated opted-in #f))
    (check-false (participant-cookie-choice opted-out c))
    (check-false (remembered-participant opted-out c))))
