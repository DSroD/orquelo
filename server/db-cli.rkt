#lang racket/base
;; `orquelo db reset --confirm`: rebuild a development database.
(require racket/contract/base racket/match db "db/conn.rkt" "db/migrate.rkt" "db/reset.rkt" (only-in "config.rkt" core-streams stream-sources) "edition.rkt" "env.rkt")
(provide (contract-out
          [call-with-migrated-db (-> env/c (listof migration-stream?) (-> connection? any) any)]
          [run-db (->* ((vectorof string?) (hash/c string? string?) output-port?) ((listof migration-stream?)) natural-number/c)]
          [make-db-command (-> (listof migration-stream?) command?)]))

(define usage "usage: orquelo db reset --confirm\nThis deletes every object in the configured database's public schema, including accounts, decks and sessions. Stop the server first.\n")

;; Env [Listof MigrationStream] (Connection -> X) -> X
;; runs `f` on a connection to DATABASE_URL, migrated first with `streams`
(define (call-with-migrated-db env streams f)
  (define c (connect-direct (env-require env "DATABASE_URL")))
  (dynamic-wind
   void
   (λ () (migrate! c (stream-sources env streams)) (f c))
   (λ () (disconnect c))))

;; String -> DbUrl
;; parses the configured target without exposing the URL or its password in validation errors
(define (checked-target url)
  (with-handlers ([exn:fail? (λ (_) (error 'db-reset "invalid DATABASE_URL"))])
    (parse-database-url url)))

;; Env [Listof MigrationStream] -> Natural
;; prints the target without credentials, then rebuilds its public schema
(define (reset-command env streams)
  (define url (env-require env "DATABASE_URL"))
  (define target (checked-target url))
  (printf "Resetting database ~s on ~s:~a as ~s.\n"
          (db-url-database target) (db-url-host target) (db-url-port target) (db-url-user target))
  (printf "Deleting the public schema, including all accounts, decks and sessions.\n")
  (flush-output)
  (define c (connect-direct url))
  (dynamic-wind
   void
   (λ ()
     (for ([version (reset-db! c (stream-sources env streams))])
       (printf "migrated ~a\n" version))
     (printf "Database reset.\n")
     0)
   (λ () (disconnect c))))

;; (Vectorof String) Env OutputPort [Listof MigrationStream] -> Natural
;; runs a confirmed database reset; all other argument combinations leave the database untouched
(define (run-db argv env out [streams core-streams])
  (parameterize ([current-output-port out])
    (with-handlers ([exn:fail? (λ (e) (eprintf "~a\n" (exn-message e)) 1)])
      (match (vector->list argv)
        [(list "reset" "--confirm") (reset-command env streams)]
        [(or (list "--help") (list "reset" "--help")) (display usage) 0]
        [_ (eprintf usage) 2]))))

;; [Listof MigrationStream] -> Command
;; the `db` subcommand, rebuilding the database from `streams`
(define (make-db-command streams)
  (command "db" "db reset --confirm" (λ (argv env in out) (run-db argv env out streams))))

(module+ test
  (require rackunit racket/port)
  (test-case "missing confirmation never needs a database connection"
    (parameterize ([current-error-port (open-output-string)])
      (check-equal? (run-db #("reset") (hash) (open-output-string)) 2)
      (check-equal? (run-db #("reset" "--confirm" "extra") (hash) (open-output-string)) 2)))
  (test-case "help works without configuration"
    (define out (open-output-string))
    (check-equal? (run-db #("--help") (hash) out) 0)
    (check-regexp-match #rx"accounts, decks and sessions" (get-output-string out)))
  (test-case "invalid database URL errors do not include credentials"
    (define err (open-output-string))
    (define code
      (parameterize ([current-error-port err])
        (run-db #("reset" "--confirm") (hash "DATABASE_URL" "postgresql://private-password") (open-output-string))))
    (check-equal? code 1)
    (check-equal? (get-output-string err) "db-reset: invalid DATABASE_URL\n")))
