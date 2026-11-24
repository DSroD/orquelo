#lang racket/base
;; DATABASE_URL parsing and connection construction.
(require racket/contract/base racket/match racket/string racket/list net/url net/uri-codec db)
(provide (contract-out
          [struct db-url ([user string?] [password (or/c string? #f)] [host string?] [port exact-positive-integer?]
                          [database string?])]
          [parse-database-url (-> string? db-url?)]
          [connect-direct (-> string? connection?)]
          [make-pool (->* (string?) (#:max-connections exact-positive-integer?
                                     #:wait (and/c real? (>=/c 0))
                                     #:observe-wait (-> real? any)
                                     #:on-timeout (-> any))
                          connection?)]
          [exn:fail:pool-timeout? (-> any/c boolean?)]))

;; An exn:fail:pool-timeout is raised when no pooled connection became free within the wait.
(struct exn:fail:pool-timeout exn:fail ())

;; tests of other modules build the exception to exercise their handling of it
(module+ for-test (provide (struct-out exn:fail:pool-timeout)))

;; A DbUrl is a (db-url String (or String #f) String Natural String)
;; interp. the user, password (#f when absent), host, port and database name of a database URL.
(struct db-url (user password host port database) #:transparent)

;; String -> DbUrl
;; parses postgresql://user:pass@host:port/db; the port defaults to 5432
(define (parse-database-url s)
  (define u (string->url s))
  (unless (member (url-scheme u) '("postgresql" "postgres"))
    (error 'database-url "expected a postgresql:// URL"))
  (define-values (user pass)
    (let* ([ui (or (url-user u) "")]
           [parts (string-split ui ":" #:trim? #f)])
      (values (uri-decode (if (pair? parts) (car parts) ""))
              (and (> (length parts) 1) (uri-decode (string-join (cdr parts) ":"))))))
  (define path (url-path u))
  (define dbname (if (null? path) "" (path/param-path (car path))))
  (when (or (not (url-host u)) (string=? dbname ""))
    (error 'database-url "host and database name are required"))
  (db-url user pass (url-host u) (or (url-port u) 5432) (uri-decode dbname)))

;; String -> Connection
;; a dedicated connection
(define (connect-direct url)
  (match-define (db-url user password host port database) (parse-database-url url))
  (postgresql-connect #:user user #:database database #:server host #:port port #:password password #:ssl 'optional))

;; Exn -> Boolean
;; did a lease fail because every pooled connection is in use? (db raises a plain exn:fail)
(define (pool-full? e)
  (and (exn:fail? e) (regexp-match? #rx"pool limit reached" (exn-message e))))

;; ConnectionPool Real [Real -> Any] [-> Any] -> Connection
;; leases a connection, retrying with a growing pause (2–50 ms) for up to `wait` seconds while the
;; pool is full. The pool cannot notify a waiter, hence the polling; waiters are not served in order.
;; observe-wait gets the seconds the lease took, whether it succeeded or gave up; on-timeout is called
;; when it gave up.
(define (lease/wait pool wait observe-wait on-timeout)
  (define t0 (current-inexact-monotonic-milliseconds))
  (define (waited) (/ (- (current-inexact-monotonic-milliseconds) t0) 1000.0))
  (let retry ([pause 0.002])
    (with-handlers ([pool-full?
                     (λ (_)
                       (when (> (waited) wait)
                         (observe-wait (waited))
                         (on-timeout)
                         (raise (exn:fail:pool-timeout "database busy: no pooled connection became free"
                                                       (current-continuation-marks))))
                       (sleep pause)
                       (retry (min 0.05 (* 2 pause))))])
      (begin0 (connection-pool-lease pool)
              (observe-wait (waited))))))

;; String [#:max-connections Natural] [#:wait Real] [#:observe-wait [Real -> Any]] [#:on-timeout [-> Any]] -> Connection
;; a virtual connection backed by a pool (20 connections by default, all kept when idle); a thread
;; that finds the pool full waits up to `wait` seconds (default 5) instead of failing. The callbacks
;; report each lease's wait and each give-up (the caller owns the metrics registry, not this module).
;; A virtual connection leases a real connection to each thread that uses it until the thread
;; dies or calls `disconnect` on it. Request threads are long-lived (keep-alive) and stream SSE
;; after their queries, so the route table calls `disconnect` when each request's handler
;; returns, i.e. before any streaming starts. No thread then holds a connection while idle.
(define (make-pool url #:max-connections [n 20] #:wait [wait 5] #:observe-wait [observe-wait void] #:on-timeout [on-timeout void])
  (define pool (connection-pool (λ () (connect-direct url)) #:max-connections n #:max-idle-connections n))
  (virtual-connection (λ () (lease/wait pool wait observe-wait on-timeout))))

(module+ test
  (require rackunit)
  (test-case "full url"
    (check-equal? (parse-database-url "postgresql://us:p%40ss:w@db.example:6432/main")
                  (db-url "us" "p@ss:w" "db.example" 6432 "main")))
  (test-case "defaults"
    (check-equal? (db-url-port (parse-database-url "postgres://u:p@h/d")) 5432))
  (test-case "no password"
    (check-false (db-url-password (parse-database-url "postgresql://u@h/d"))))
  (test-case "rejects bad urls"
    (check-exn exn:fail? (λ () (parse-database-url "mysql://u:p@h/d")))
    (check-exn exn:fail? (λ () (parse-database-url "postgresql://u:p@h")))))
