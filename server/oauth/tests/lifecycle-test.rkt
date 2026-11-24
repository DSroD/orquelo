#lang racket/base
;; The grant lifecycle on the memory store: fixed command lists for the edges the random lists
;; rarely reach, then the model-based property (see lifecycle-check.rkt).
(require rackunit "../store.rkt" "lifecycle-check.rkt")

(for ([script (in-list scripts)])
  (test-case (car script) (run-commands make-memory-store (cdr script))))

(test-case "random command lists behave as the model says, and every token stays within its grant"
  (lifecycle-property make-memory-store 300 #:deadline-ms 8000))
