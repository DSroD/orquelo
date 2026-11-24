#lang racket/base
;; Shared rackcheck configuration for the property tests (test-only: never required from main.rkt).
;; PROP_SEED=<n> replays a run, PROP_SCALE=<x> multiplies case counts and deadlines.
(require racket/contract racket/math rackcheck)

(provide
 (contract-out
  [prop-config (->* (exact-positive-integer?) (#:deadline-ms exact-positive-integer?) config?)]))

(define max-seed (sub1 (expt 2 31)))
(define default-deadline-ms 8000)

;; String (-> String Real) -> Real
;; reads a positive number from the environment variable, else the default
(define (env-number name default)
  (define n (let ([s (getenv name)]) (and s (string->number s))))
  (if (and (real? n) (positive? n)) n default))

;; -> Natural
;; PROP_SEED when set, else a fresh random seed in 0..2^31-1
(define (current-seed)
  (define n (let ([s (getenv "PROP_SEED")]) (and s (string->number s))))
  (cond [(exact-integer? n) (modulo n (add1 max-seed))]
        [else (random (add1 max-seed))]))

;; Natural -> config
;; `tests` cases (times PROP_SCALE) within the deadline (default 8 s, times PROP_SCALE).
;; The seed is printed so a failing run can be replayed with PROP_SEED=<seed>.
(define (prop-config tests #:deadline-ms [deadline-ms default-deadline-ms])
  (define scale (env-number "PROP_SCALE" 1))
  (define seed (current-seed))
  (eprintf "  property seed: PROP_SEED=~a\n" seed)
  (make-config #:seed seed
               #:tests (max 1 (exact-round (* tests scale)))
               #:deadline (+ (current-inexact-milliseconds) (* scale deadline-ms))))

(module+ test
  (require rackunit)
  (check-true (config? (prop-config 10))))
