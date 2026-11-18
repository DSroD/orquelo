#lang racket/base
;; Confirmed reset against the throwaway TEST_DATABASE_URL; never uses DATABASE_URL from the shell.
(require rackunit racket/file racket/port racket/runtime-path racket/string db "../db-cli.rkt"
         "support.rkt" "../db/conn.rkt" "../db/migrate.rkt")

;; (Vectorof String) Env -> (values Natural String String)
;; invokes the database CLI and captures both output streams
(define (db-command args env)
  (define out (open-output-string))
  (define err (open-output-string))
  (define code (parameterize ([current-error-port err]) (run-db args env out)))
  (values code (get-output-string out) (get-output-string err)))

;; Connection -> Void
;; checks that confirmation gates deletion and reset rebuilds the schema
(define (run-tests c)
  (define env (hash "DATABASE_URL" (getenv "TEST_DATABASE_URL") "MIGRATIONS_DIR" (path->string migrations-dir)))
  (test-case "reset requires explicit confirmation, rebuilds all data"
    (query-exec c "INSERT INTO users (name) VALUES ('Owner')")
    (define-values (refused _out err) (db-command #("reset") env))
    (check-equal? refused 2)
    (check-regexp-match #rx"--confirm" err)
    (check-equal? (query-value c "SELECT count(*) FROM users") 1)
    (define-values (code out _err) (db-command #("reset" "--confirm") env))
    (check-equal? code 0)
    (check-regexp-match #rx"orquelo_test" out)
    (check-regexp-match #rx"127.0.0.1" out)
    (check-false (string-contains? out "postgresql://"))
    (check-equal? (query-value c "SELECT count(*) FROM users") 0)
    (check-equal? (migrate! c test-sources) '()))
  (test-case "a failed rebuild rolls back deletion"
    (query-exec c "INSERT INTO users (name) VALUES ('Owner')")
    (define dir (make-temporary-file "orquelo-bad-migration~a" 'directory))
    (dynamic-wind
     void
     (λ ()
       (display-to-file "SELECT no_such_function();\n" (build-path dir "20260101000000_bad.sql"))
       (define-values (code _out _err)
         (db-command #("reset" "--confirm") (hash-set env "MIGRATIONS_DIR" (path->string dir))))
       (check-equal? code 1)
       (check-equal? (query-value c "SELECT count(*) FROM users") 1)
       (check-equal? (migrate! c test-sources) '()))
     (λ () (delete-directory/files dir))))
  (disconnect c))

(module+ test
  (if (getenv "TEST_DATABASE_URL")
      (let ([c (connect-direct (getenv "TEST_DATABASE_URL"))])
        (query-exec c "DROP SCHEMA public CASCADE")
        (query-exec c "CREATE SCHEMA public")
        (migrate! c test-sources)
        (run-tests c))
      (eprintf "SKIPPED reset-cli-test: TEST_DATABASE_URL not set (use scripts/with-ephemeral-pg)\n")))
