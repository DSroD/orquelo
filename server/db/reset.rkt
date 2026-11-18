#lang racket/base
;; Destructive development setup. The caller must obtain explicit confirmation first.
(require racket/contract/base db "migrate.rkt")
(provide (contract-out
          [reset-db! (-> connection? (listof migration-source?) (listof string?))]))

;; Connection [Listof MigrationSource] -> [Listof String]
;; rebuilds the public schema and migration history atomically, under the migration lock
(define (reset-db! c sources)
  (query-exec c "SELECT pg_advisory_lock(7303)")
  (dynamic-wind
   void
   (λ ()
     (call-with-transaction
      c
      (λ ()
        (query-exec c "DROP SCHEMA public CASCADE")
        (query-exec c "CREATE SCHEMA public")
        (migrate! c sources))))
   (λ () (query-exec c "SELECT pg_advisory_unlock(7303)"))))
