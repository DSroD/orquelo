#lang racket/base
;; User session cookie, participant cookie, signed-cookie helpers and the safe return_to.
(require racket/contract/base racket/list racket/match racket/string net/cookies/server (except-in web-server/http make-cookie) web-server/http/id-cookie
         "../config.rkt" "../domain.rkt" "../live/codes.rkt")
(provide user-cookie-name participant-cookie-name
         (contract-out
          [struct login-token ([user-id id/c] [epoch natural-number/c])]
          [signed-cookie-header (->* (config? string? string? #:max-age exact-nonnegative-integer?) (#:path string?) header?)]
          [read-signed-cookie (->* (config? string? request?) (#:shelf-life real?) (or/c string? #f))]
          [clear-cookie-header* (->* (string?) (#:path string?) header?)]
          [request-login-token (-> request? config? (or/c login-token? #f))]
          [user-cookie (-> id/c natural-number/c config? header?)]
          [clear-user-cookie (-> header?)]
          [request-participant (-> request? (or/c string? #f))]
          [participant-cookie (-> string? config? header?)]
          [safe-return-to (-> any/c string?)]))

(define user-cookie-name "orquelo_user")
(define participant-cookie-name "orquelo_pid")
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
;; Request -> (or String #f)
;; the participant UUID from the cookie, if well-formed
(define (request-participant req)
  (define c (findf (λ (c) (equal? (client-cookie-name c) participant-cookie-name)) (request-cookies req)))
  (define v (and c (client-cookie-value c)))
  (and (valid-uuid? v) v))

;; String Config -> Header
(define (participant-cookie id cfg)
  (set-cookie-header
   (make-cookie participant-cookie-name id #:path "/" #:max-age 31536000 #:http-only? #t
                #:secure? (config-secure? cfg) #:extension "SameSite=Lax")))

;; ------------------------------------------------------------------ login helpers
;; Any -> String
;; a same-site path to return to after login, else /decks
(define (safe-return-to s)
  ;; a whitelist: browsers strip tabs and newlines and read backslashes as slashes, so "/\t/evil.com"
  ;; or "/\\evil.com" would become protocol-relative. "//" alone matches the pattern, so it is excluded.
  (if (and (string? s) (regexp-match? #px"^/[A-Za-z0-9/_-]*$" s) (not (string-prefix? s "//")))
      s
      "/decks"))

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
    (check-regexp-match #rx"Secure" (hdr-value (participant-cookie (random-uuid-v4) c))))
  (test-case "participant cookie"
    (define id (random-uuid-v4))
    (define h (hdr-value (participant-cookie id (cfg))))
    (check-regexp-match #rx"Max-Age=31536000" h)
    (check-equal? (request-participant (req-with-cookie (format "orquelo_pid=~a" id))) id)
    (check-false (request-participant (req-with-cookie "orquelo_pid=nope")))
    (check-false (request-participant (req-with-cookie "x=1"))))
  (test-case "return_to sanitising"
    (check-equal? (safe-return-to "/decks/3") "/decks/3")
    (check-equal? (safe-return-to "//evil.com") "/decks")
    (check-equal? (safe-return-to "https://evil.com") "/decks")
    (check-equal? (safe-return-to "/\\evil") "/decks")
    (check-equal? (safe-return-to #f) "/decks")
    (for ([bad '("/\t/evil.com" "/\r/evil.com" "/\n/evil.com" "/evil\n" "/\\evil.com" "//" "//evil.com"
                 "/%09/evil.com" "%2F%2Fevil.com" "/%2F%2Fevil.com" "/a.b" "")])
      (check-equal? (safe-return-to bad) "/decks" bad))))
