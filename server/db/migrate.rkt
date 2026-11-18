#lang racket/base
;; Minimal forward-only SQL migration runner. Files are `YYYYMMDDHHMMSS_name.sql` (UTC) in one
;; directory per stream; a version is "<stream>/<file>". Streams run in the given order, files by name.
;; `conn` must be a dedicated connection (the advisory lock is session-level).
(require racket/contract/base racket/file racket/list racket/string db)
(provide (contract-out
          [struct migration-stream ([name string?] [env-var string?] [default-dir string?])]
          [struct migration-source ([name string?] [dir path-string?])]
          [migrate! (-> connection? (listof migration-source?) (listof string?))]
          [migration-files (-> path-string? (listof string?))]
          [plan-migrations (-> (listof (cons/c string? (listof string?))) (listof string?)
                               (values (listof string?) (listof string?)))]
          [split-statements (-> string? (listof string?))]))

(define lock-id 7303)

;; A MigrationStream is a (migration-stream String String String)
;; interpretation: a stream name, the environment variable naming its directory, and the default directory
(struct migration-stream (name env-var default-dir) #:transparent)

;; A MigrationSource is a (migration-source String Path-String)
;; interpretation: a stream resolved to its directory
(struct migration-source (name dir) #:transparent)

;; String -> [Listof String]
;; The extended protocol runs one statement per query: split on ";" at end of line.
(define (split-statements sql)
  (filter (λ (s) (not (string=? s "")))
          (map string-trim (regexp-split #px";[ \t]*(?:\r?\n|$)" sql))))

(define migration-name-rx #px"^\\d{14}_[a-z0-9_]+\\.sql$")

;; Path-String -> [Listof String]
;; the migration file names in name order; raises on any other *.sql (such as a leftover 001_x.sql)
(define (migration-files dir)
  (define sql (for/list ([p (directory-list dir)]
                         #:when (regexp-match? #rx"[.]sql$" (path->string p)))
                (path->string p)))
  (for ([f sql] #:unless (regexp-match? migration-name-rx f))
    (error 'migrate "bad migration file name ~a in ~a (want YYYYMMDDHHMMSS_name.sql)" f dir))
  (sort sql string<?))

;; String String -> String
(define (version stream file) (string-append stream "/" file))

;; String [Listof String] [Listof String] -> [Listof String]
;; the pending versions of one stream (named `stream`, with files `files`); raises when one is older
;; than the newest applied version of that stream, since it would run out of order
(define (pending-in-stream stream files applied)
  (define prefix (string-append stream "/"))
  (define newest
    (for/fold ([m #f]) ([v applied] #:when (and (string-prefix? v prefix) (or (not m) (string>? v m))))
      v))
  (define pending
    (for/list ([f files] #:unless (member (version stream f) applied)) (version stream f)))
  (define stale (if newest (filter (λ (v) (string<? v newest)) pending) '()))
  (unless (null? stale)
    (error 'migrate "migration ~a is older than applied ~a; add a new migration with a later timestamp"
           (string-join stale ", ") newest))
  pending)

;; [Listof (cons String [Listof String])] [Listof String] -> (values [Listof String] [Listof String])
;; Takes the files per stream (in stream order) and the applied versions. Returns the pending versions
;; (stream order, then name order) and the applied versions this binary does not know.
(define (plan-migrations streams applied)
  (define known (for*/list ([s streams] [f (cdr s)]) (version (car s) f)))
  (values (append* (for/list ([s streams]) (pending-in-stream (car s) (cdr s) applied)))
          (filter (λ (v) (not (member v known))) applied)))

;; Connection -> [Listof String]
(define (applied conn)
  (for/list ([v (query-list conn "SELECT version FROM schema_migrations")]) v))

;; Connection Path-String String -> Void
;; runs one migration file and records it under `version`, atomically
(define (apply-migration! conn path version)
  (define stmts (split-statements (file->string path)))
  (call-with-transaction
   conn
   (λ ()
     (for ([s stmts]) (query-exec conn s))
     (query-exec conn "INSERT INTO schema_migrations (version) VALUES ($1)" version))))

;; Connection [Listof MigrationSource] -> [Listof String]
;; applies the pending migrations under an advisory lock; the newly applied versions.
;; Refuses (before applying anything) a pending file older than an applied one of its stream.
(define (migrate! conn sources)
  (query-exec conn "SELECT pg_advisory_lock($1)" lock-id)
  (dynamic-wind
   void
   (λ ()
     (query-exec conn "CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())")
     (define files
       (for/list ([s sources]) (cons (migration-source-name s) (migration-files (migration-source-dir s)))))
     (define-values (pending unknown) (plan-migrations files (applied conn)))
     (for ([v unknown]) (log-warning "migrate: applied migration ~a is unknown to this binary" v))
     (define dirs (for/hash ([s sources]) (values (migration-source-name s) (migration-source-dir s))))
     (for/list ([v pending])
       (define-values (stream file) (apply values (string-split v "/")))
       (apply-migration! conn (build-path (hash-ref dirs stream) file) v)
       v))
   (λ () (query-exec conn "SELECT pg_advisory_unlock($1)" lock-id))))

(module+ test
  (require rackunit)
  (test-case "splits on semicolon at end of line"
    (check-equal? (split-statements "CREATE TABLE a (x int);\nCREATE TABLE b (y int);\n")
                  '("CREATE TABLE a (x int)" "CREATE TABLE b (y int)")))
  (test-case "keeps semicolons inside a line and dollar-quoted one-liners"
    (check-equal? (split-statements "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;\nSELECT 2")
                  '("CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql" "SELECT 2")))
  (test-case "ignores blank fragments"
    (check-equal? (split-statements "\n;\n  \nSELECT 1;  \n\n") '("SELECT 1")))
  (test-case "migration-files accepts only timestamped names, in order"
    (define dir (make-temporary-file "orquelo-mig~a" 'directory))
    (dynamic-wind
     void
     (λ ()
       (for ([f '("20260102000000_b.sql" "20260101000000_a.sql" "notes.txt")])
         (display-to-file "" (build-path dir f)))
       (check-equal? (migration-files dir) '("20260101000000_a.sql" "20260102000000_b.sql"))
       (display-to-file "" (build-path dir "001_init.sql"))
       (check-exn #rx"bad migration file name 001_init.sql" (λ () (migration-files dir))))
     (λ () (delete-directory/files dir))))
  (test-case "plan: stream order, then name order; applied are skipped"
    (define-values (pending unknown)
      (plan-migrations '(("core" "20260101000000_a.sql" "20260103000000_c.sql") ("extra" "20260102000000_x.sql"))
                       '("core/20260101000000_a.sql")))
    (check-equal? pending '("core/20260103000000_c.sql" "extra/20260102000000_x.sql"))
    (check-equal? unknown '()))
  (test-case "plan: timestamps are only compared within a stream"
    (define-values (pending _u)
      (plan-migrations '(("core" "20260101000000_a.sql" "20260102000000_b.sql") ("extra" "20260103000000_y.sql"))
                       '("extra/20260103000000_y.sql" "core/20260101000000_a.sql")))
    (check-equal? pending '("core/20260102000000_b.sql")))
  (test-case "plan: a pending file older than an applied one of its stream is refused"
    (check-exn #rx"core/20260102000000_b.sql is older than applied core/20260103000000_c.sql"
               (λ () (plan-migrations '(("core" "20260101000000_a.sql" "20260102000000_b.sql" "20260103000000_c.sql"))
                                      '("core/20260101000000_a.sql" "core/20260103000000_c.sql")))))
  (test-case "plan: a pending file newer than the applied ones is fine"
    (define-values (pending _u)
      (plan-migrations '(("core" "20260101000000_a.sql" "20260102000000_b.sql")) '("core/20260101000000_a.sql")))
    (check-equal? pending '("core/20260102000000_b.sql")))
  (test-case "plan: applied versions missing from the binary are reported"
    (define-values (_p unknown)
      (plan-migrations '(("core" "20260101000000_a.sql")) '("core/20260101000000_a.sql" "core/20260109000000_z.sql" "extra/x.sql")))
    (check-equal? unknown '("core/20260109000000_z.sql" "extra/x.sql"))))
