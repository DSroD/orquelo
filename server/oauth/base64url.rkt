#lang racket/base
;; Unpadded base64url (RFC 4648 section 5) and random identifiers built on it.
(require racket/contract/base racket/string racket/random net/base64)
(provide (contract-out
          [base64url-encode (-> bytes? string?)]
          [random-base64url (-> exact-positive-integer? string?)]))

;; Bytes -> String
;; the base64url text of the bytes, without padding
(define (base64url-encode bs)
  (define std (bytes->string/latin-1 (base64-encode bs #"")))
  (string-trim (string-replace (string-replace std "+" "-") "/" "_") "=" #:left? #f #:repeat? #t))

;; PositiveInteger -> String
;; `n` bytes from the system CSPRNG, as base64url
(define (random-base64url n)
  (base64url-encode (crypto-random-bytes n)))

(module+ test
  (require rackunit)
  (check-equal? (base64url-encode (bytes 251 255 190)) "-_--")
  (check-equal? (base64url-encode #"a") "YQ")
  (check-equal? (string-length (random-base64url 32)) 43))
