#lang racket/base
;; Reading the process environment (a hash of String -> String): values are trimmed, blank counts as unset.
(require racket/contract/base racket/string)
(provide (contract-out
          [env-ref (->* ((hash/c string? string?) string?) ((or/c string? #f)) (or/c string? #f))]
          [env-require (-> (hash/c string? string?) string? string?)]))

;; Env String [(or String #f)] -> (or String #f)
;; the trimmed variable, or the default when unset or blank
(define (env-ref env k [default #f])
  (define v (string-trim (hash-ref env k "")))
  (if (string=? v "") default v))

;; Env String -> String
(define (env-require env k)
  (or (env-ref env k) (error 'config "missing required env var ~a" k)))

(module+ test
  (require rackunit)
  (define env (hash "A" "  x " "B" "   "))
  (test-case "trimmed, blank is unset"
    (check-equal? (env-ref env "A") "x")
    (check-false (env-ref env "B"))
    (check-false (env-ref env "C"))
    (check-equal? (env-ref env "B" "d") "d"))
  (test-case "require"
    (check-equal? (env-require env "A") "x")
    (check-exn #rx"missing required env var B" (λ () (env-require env "B")))))
