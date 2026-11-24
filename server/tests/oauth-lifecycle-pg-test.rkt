#lang racket/base
;; The grant lifecycle property of oauth/tests/lifecycle-check.rkt on the Postgres store.
(require rackunit "support.rkt" "../db/conn.rkt" "../db/oauth-store.rkt"
         "../oauth/tests/lifecycle-check.rkt")

(module+ test
  (cond
    [(test-db-url)
     (define c (fresh-db!))
     (define pool (make-pool (test-db-url)))
     (define (make-store) (reset-oauth-users! c) (make-pg-oauth-store pool))
     (for ([script (in-list scripts)])
       (test-case (car script) (run-commands make-store (cdr script))))
     (test-case "random command lists behave as the model says, and every token stays within its grant"
       (lifecycle-property make-store 50 #:deadline-ms 20000))]
    [else (eprintf "SKIPPED oauth-lifecycle-pg-test: TEST_DATABASE_URL not set (use scripts/with-ephemeral-pg)\n")]))
