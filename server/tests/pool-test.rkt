#lang racket/base
;; Open SSE streams must not pin pooled database connections: with more streams than the pool
;; holds, ordinary requests still succeed (TEST_DATABASE_URL, see scripts/with-ephemeral-pg).
(require rackunit racket/file racket/port racket/promise net/http-client net/url web-server/http db/base json
         "support.rkt" "../config.rkt" "../main.rkt" "../edition.rkt" "../editions/core.rkt" "../db/accounts.rkt" "../db/repo.rkt" "../db/conn.rkt" "../domain.rkt"
         "../live/hub.rkt" "../live/load.rkt" "../metrics/app.rkt" "../metrics/registry.rkt"
         "../http/deps.rkt" "../http/routes.rkt" "../http/endpoint.rkt" "../http/public.rkt" "../http/json.rkt" "../storage/local.rkt")

;; (or Natural #f) [Listof Path] -> (values Natural (-> Any))
;; starts a server with a pool of the given size (#f: the default) on a free port; the thunk stops it
;; (or Id #f) String Kind [Listof String] Boolean -> PollDraft
;; constructs an ordinary fixed-answer poll for the integration scenarios
(define (simple-draft slide question kind labels show-results?)
  (poll-draft slide question kind (map (λ (label) (option-draft label #f)) labels) show-results? #f))

(define (start! pool-size dirs)
  (let try ([n 3])
    (define port (+ 20000 (random 30000)))
    (define env (hash-set* minimal-env "DATABASE_URL" (test-db-url) "PUBLIC_BASE_URL" (format "http://127.0.0.1:~a" port)
                                   "STATIC_DIR" (path->string (car dirs)) "UPLOAD_DIR" (path->string (cadr dirs))
                                   "MIGRATIONS_DIR" (path->string migrations-dir)
                                   "SESSION_SECRET" (make-string 40 #\s) "PORT" (number->string port)))
    (define cfg (load-config env))
    (define plugin ((edition-configure core-edition) env cfg))
    (define stop (with-handlers ([exn:fail? (λ (e) (if (zero? n) (raise e) #f))])
                   (if pool-size (start-server cfg #:plugin plugin #:pool-size pool-size) (start-server cfg #:plugin plugin))))
    (if stop (values port stop) (try (sub1 n)))))

;; Natural String -> Natural
;; the status code of a GET
(define (get-status port path)
  (define-values (status hdrs in) (http-sendrecv "127.0.0.1" path #:port port))
  (close-input-port in)
  (string->number (cadr (regexp-match #rx" ([0-9]+) " (bytes->string/utf-8 status)))))

;; (or Natural #f) Natural -> Void
;; opens `streams` public SSE streams, then makes plain requests that each need the database
(define (check-streams pool-size streams)
  (define c (fresh-db!))
  (define pid (new-deck! c (new-owner! c) "T" 3))
  (define code (session-code (insert-session! c pid "A" "abcde23456" "vwxyz76543")))
  (disconnect c)
  (define dirs (list (make-temporary-file "orquelo-pool-static~a" 'directory)
                     (make-temporary-file "orquelo-pool-up~a" 'directory)))
  (define-values (port stop) (start! pool-size dirs))
  (dynamic-wind
   void
   (λ ()
     (define ins
       (for/list ([i streams])
         (define-values (status hdrs in)
           (http-sendrecv "127.0.0.1" (format "/api/s/~a/~a/stream?role=audience" pid code) #:port port))
         (check-regexp-match #rx#" 200 " status)
         (check-equal? (read-line in) "retry: 3000")
         in))
     (for ([i 10])
       (check-equal? (get-status port (format "/api/s/~a/~a" pid code)) 200))
     (for-each close-input-port ins))
   (λ () (stop) (for-each delete-directory/files dirs))))

;; Natural Natural -> Void
;; fires `n` requests that each need the database at once; with the pool smaller than `n`
;; they wait for a connection instead of failing
(define (check-concurrent pool-size n)
  (define c (fresh-db!))
  (define pid (new-deck! c (new-owner! c) "T" 3))
  (define code (session-code (insert-session! c pid "A" "abcde23456" "vwxyz76543")))
  (disconnect c)
  (define dirs (list (make-temporary-file "orquelo-pool-static~a" 'directory)
                     (make-temporary-file "orquelo-pool-up~a" 'directory)))
  (define-values (port stop) (start! pool-size dirs))
  (dynamic-wind
   void
   (λ ()
     (define results (for/list ([i n]) (make-channel)))
     (for ([ch results])
       (thread (λ () (channel-put ch (get-status port (format "/api/s/~a/~a" pid code))))))
     (check-equal? (map channel-get results) (for/list ([i n]) 200)))
   (λ () (stop) (for-each delete-directory/files dirs))))

;; -> (values Deps Id String)
;; deps over a pool of 2 whose hub takes a second to load the session, with an open poll in the database
(define (slow-hub-deps)
  (define c (fresh-db!))
  (define pid (new-deck! c (new-owner! c) "T" 3))
  (define code (session-code (insert-session! c pid "A" "abcde23456" "vwxyz76543")))
  (define poll (create-poll! c pid (simple-draft #f "Q" "single" '("x" "y") #f)))
  (open-run! c (session-id (get-session c code)) (poll-id poll))
  (define cfg (load-config (hash-set* minimal-env "DATABASE_URL" (test-db-url) "PUBLIC_BASE_URL" "http://127.0.0.1:1"
                                 "STATIC_DIR" "." "UPLOAD_DIR" "." "MIGRATIONS_DIR" (path->string migrations-dir)
                                 "SESSION_SECRET" (make-string 40 #\s))))
  (define loader (make-loader c cfg))
  (define metrics (make-app-metrics))
  (define pool (make-pool (test-db-url) #:max-connections 2 #:wait 0.5
                          #:observe-wait (λ (secs) (observe-pool-wait! metrics secs))
                          #:on-timeout (λ () (count-pool-timeout! metrics))))
  (values (deps cfg pool (make-hub (λ (code) (sleep 1) (loader code)) #:metrics metrics) metrics (local-store ".") (env-limits cfg)) pid code))

;; Id -> Request
;; a vote for the run with one option
(define (vote-request run-id)
  (make-request #"POST" (string->url "/x") '() (delay '())
                (jsexpr->bytes (hasheq 'run_id run-id 'option_ids (list 1))) "127.0.0.1" 80 "127.0.0.1"))

;; Natural -> Void
;; `n` concurrent votes while the hub is slow: they must not hold their connections while waiting for it
(define (check-votes-during-slow-hub n)
  (define-values (d pid code) (slow-hub-deps))
  (define run-id (query-value (deps-db d) "SELECT max(id) FROM poll_runs"))
  (disconnect (deps-db d))
  (define statuses
    (for/list ([i n])
      (define ch (make-channel))
      (thread (λ () (channel-put ch (with-handlers ([exn:fail? exn-message])
                                      (response-code (cast-vote* d (vote-request run-id) pid code))))))
      ch))
  (check-equal? (map channel-get statuses) (for/list ([i n]) 200))
  (check-regexp-match #rx"orquelo_db_pool_timeouts_total 0" (render (app-metrics-registry (deps-metrics d))))
  (check-regexp-match #rx"orquelo_db_pool_wait_seconds_count [1-9]" (render (app-metrics-registry (deps-metrics d)))))

;; -> Void
;; plugin routes are built once, run before the fallback and use the core's error mapping
(define (check-plugin-routes)
  (define-values (d pid code) (slow-hub-deps))
  (define (get path) (make-request #"GET" (string->url path) '() (delay '()) #f "127.0.0.1" 80 "127.0.0.1"))
  (define route-builds 0)
  (define (routes kit fallback)
    (set! route-builds (add1 route-builds))
    (λ (req)
      (case (url->string (request-uri req))
        [("/plugin/ok") (((route-kit-named kit) "/plugin/ok" (λ (req) (response/output void))) req)]
        [("/plugin/api-error" "/healthz") (api-error! 418 "teapot" "short and stout")]
        [("/plugin/crash") (error "boom")]
        [else (fallback req)])))
  (define handler (make-handler d (plugin (deps-limits d) routes)))
  (define (status path) (parameterize ([current-error-port (open-output-string)]) (response-code (handler (get path)))))
  (check-equal? route-builds 1)
  (check-equal? (status "/plugin/ok") 200)
  (check-equal? (status "/plugin/api-error") 418)
  (check-equal? (status "/plugin/crash") 500)
  (check-equal? (status "/api/nothing") 404)
  (check-equal? (status "/healthz") 200)
  (check-equal? route-builds 1))

(module+ test
  (cond
    [(test-db-url)
     (test-case "pool of 3, 10 streams" (check-streams 3 10))
     (test-case "default pool, 35 streams" (check-streams #f 35))
     (test-case "pool of 2, 40 concurrent requests wait instead of failing" (check-concurrent 2 40))
     (test-case "plugin routes sit behind the guard" (check-plugin-routes))
     (test-case "pool of 2, 6 votes behind a slow hub do not hold connections" (check-votes-during-slow-hub 6))]
    [else (eprintf "SKIPPED pool-test: TEST_DATABASE_URL not set (use scripts/with-ephemeral-pg)\n")]))
