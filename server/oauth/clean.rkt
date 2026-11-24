#lang racket/base
;; Cleaning of the text a client supplies about itself before we show it to a user. Everything
;; here is self-asserted by the client: names and URLs are display text, not identity.
(require racket/contract/base racket/string)
(provide (contract-out
          [clean-name (-> any/c string? string?)]
          [https-uri-or-false (-> any/c (or/c string? #f))]
          [same-origin-uri-or-false (-> any/c string? (or/c string? #f))]))

(define max-name-length 100)
;; control, format (RLO, zero width, ...) and line/paragraph separator characters
(define invisible-rx #px"\\p{Cc}|\\p{Cf}|\\p{Zl}|\\p{Zp}")

;; Any String -> String
;; the name with invisible characters removed, trimmed, cut to 100 characters and trimmed again
;; (the cut may end in whitespace); `fallback` when nothing is left
(define (clean-name v fallback)
  (define s (if (string? v) (string-trim (regexp-replace* invisible-rx v "")) ""))
  (define cut (string-trim (substring s 0 (min max-name-length (string-length s)))))
  (if (string=? cut "") fallback cut))

;; Any -> (or String #f)
;; the URI when it is a plain https URI of reasonable length
(define (https-uri-or-false v)
  (and (string? v) (<= (string-length v) 2048) (regexp-match? #px"^https://[!-~]+$" v) v))

;; Any String -> (or String #f)
;; the URI when it is https on exactly the host of `host` (so it says nothing the client_id does not)
(define (same-origin-uri-or-false v host)
  (define u (https-uri-or-false v))
  (and u (regexp-match? (pregexp (string-append "^https://" (regexp-quote host) "([/?]|$)")) u) u))

(module+ test
  (require rackunit)
  (check-equal? (clean-name " My\u0007 App " "x") "My App")
  (check-equal? (clean-name "Cla‮ude​\u0085 " "x") "Claude")
  (check-equal? (clean-name "​ " "fallback") "fallback")
  (check-equal? (clean-name 5 "fallback") "fallback")
  (check-equal? (string-length (clean-name (make-string 300 #\a) "x")) 100)
  (check-equal? (clean-name (string-append (make-string 99 #\a) " b") "x") (make-string 99 #\a))
  (check-equal? (https-uri-or-false "https://a.example/x") "https://a.example/x")
  (check-false (https-uri-or-false "http://a.example"))
  (check-equal? (same-origin-uri-or-false "https://a.example" "a.example") "https://a.example")
  (check-equal? (same-origin-uri-or-false "https://a.example/logo.png" "a.example") "https://a.example/logo.png")
  (check-false (same-origin-uri-or-false "https://a.example.evil.com/" "a.example"))
  (check-false (same-origin-uri-or-false "https://a.example@evil.com/" "a.example"))
  (check-false (same-origin-uri-or-false "https://claude.ai" "a.example")))
