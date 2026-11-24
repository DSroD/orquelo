#lang racket/base
;; PKCE (RFC 7636), S256 only: `plain` offers nothing against an intercepted authorization request.
(require racket/contract/base "base64url.rkt")
(provide (contract-out
          [s256-challenge? (-> any/c boolean?)]
          [s256-matches? (-> string? string? boolean?)]))

;; Any -> Boolean
;; is `v` shaped like an S256 challenge: the 43 base64url characters of a SHA-256 digest
(define (s256-challenge? v)
  (and (string? v) (regexp-match? #px"^[A-Za-z0-9_-]{43}$" v)))

;; String -> Boolean
;; 43 to 128 unreserved characters (RFC 7636 section 4.1)
(define (verifier? v)
  (regexp-match? #px"^[A-Za-z0-9._~-]{43,128}$" v))

;; String String -> Boolean
;; does BASE64URL(SHA256(verifier)) equal the challenge, for a well-formed verifier
(define (s256-matches? verifier challenge)
  (and (verifier? verifier)
       (equal? (base64url-encode (sha256-bytes (string->bytes/utf-8 verifier))) challenge)))

(module+ test
  (require rackunit)
  ;; RFC 7636 appendix B
  (define verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  (define challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  (check-true (s256-matches? verifier challenge))
  (check-false (s256-matches? (string-append "x" (substring verifier 1)) challenge))
  (check-false (s256-matches? "short" challenge))
  (check-false (s256-matches? (make-string 129 #\a) challenge))
  (check-false (s256-matches? (string-append verifier "!") challenge))
  (check-true (s256-challenge? challenge))
  (check-false (s256-challenge? "abc"))
  (check-false (s256-challenge? #f)))
