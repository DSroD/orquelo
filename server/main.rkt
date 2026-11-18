#lang racket/base
;; Entry point: config -> migrate -> serve. `racket server/main.rkt` runs the `main` submodule.
(require racket/contract/base racket/file racket/list racket/match racket/string racket/async-channel web-server/web-server web-server/servlet-dispatch web-server/safety-limits
         "config.rkt" "db/accounts.rkt" "db/conn.rkt" "db/migrate.rkt" "live/hub.rkt" "live/load.rkt"
         "edition.rkt" "http/deps.rkt" "http/metrics.rkt" "http/routes.rkt"
         "metrics/app.rkt" "metrics/live.rkt" "metrics/registry.rkt" "metrics/runtime.rkt" db/base)
(provide (contract-out
          [start-server (->* (config? #:plugin plugin?) (#:port (integer-in 0 65535) #:pool-size exact-positive-integer? #:on-hub (-> hub? any)) (-> any))]
          [safety-limits-for (-> natural-number/c safety-limits?)]
          [env->hash (-> env/c)]
          [run-command (-> edition? (vectorof string?) env/c input-port? output-port? (or/c exact-integer? #f))]
          [run-main (-> edition? any)]))

;; -> Env
;; the process environment as a hash of String -> String
(define (env->hash)
  (define env (current-environment-variables))
  (for/hash ([n (environment-variables-names env)])
    (values (bytes->string/utf-8 n #\?) (bytes->string/utf-8 (environment-variables-ref env n) #\?))))

;; Headroom above MAX_UPLOAD_BYTES: a PDF a little over the limit still reaches the deck route and
;; gets a 413 too_large, while web-server drops a file over its own cap without any response.
(define upload-headroom (* 10 1024 1024))

;; Natural -> SafetyLimits
;; the request caps for uploads of up to `max-upload` bytes: the file cap and the body cap (the rest of
;; the form) leave `upload-headroom` each.
;; Browsers send every cookie for the host in one header line; the 8 KiB default is too small.
;; The default cap of 10000 concurrent connections counts idle keep-alive ones too, so it would
;; refuse SSE streams long before the hub is the bottleneck.
(define (safety-limits-for max-upload)
  (make-safety-limits #:max-concurrent 50000
                      #:max-request-header-length (* 64 1024)
                      #:max-request-body-length (+ max-upload (* 2 upload-headroom))
                      #:max-form-data-file-length (+ max-upload upload-headroom)
                      #:form-data-file-memory-threshold (* 8 1024 1024)))

;; (Request -> Response) Natural [SafetyLimits] -> (-> Void)
;; listens on all interfaces; the thunk stops it. Raises when the port cannot be bound.
(define (listen handler port [safety-limits (make-safety-limits)])
  (define ready (make-async-channel))
  (define stop (serve #:dispatch (dispatch/servlet handler #:regexp #rx"")
                      #:port port #:listen-ip #f #:safety-limits safety-limits #:confirmation-channel ready))
  (define status (async-channel-get ready))
  (when (exn? status) (raise status))
  stop)

;; AppMetrics Hub Custodian Custodian -> Void
;; registers the runtime, GC and hub metrics with the application's registry
(define (add-process-metrics! m hub server-cust root)
  (define r (app-metrics-registry m))
  (add-collector! r (λ () (runtime-families server-cust root)))
  (add-collector! r (λ () (hub-families (hub-stats-of hub))))
  (start-gc-listener! (make-histogram r "racket_gc_pause_seconds" "Garbage collection pauses"
                                      '(0.0005 0.001 0.0025 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 2.5) #:labels '("kind"))))

;; Config #:plugin Plugin [#:port Natural] [#:pool-size Natural] [#:on-hub (Hub -> Any)] -> (-> Void)
;; migrates, starts listening (and serves /metrics on the metrics port, if configured); the thunk stops it all.
;; `on-hub` sees the running hub, for tooling such as a profiler of the hub thread.
;; The hub, the GC listener and the listeners' threads live under one custodian, so they can be counted
;; (racket_threads) and shut down together.
(define (start-server cfg #:plugin plugin #:port [port (config-port cfg)] #:pool-size [pool-size (config-pool-size cfg)]
                      #:on-hub [on-hub void])
  (define admin-conn (connect-direct (config-database-url cfg)))
  (for ([v (migrate! admin-conn (config-migrations cfg))]) (eprintf "migrated ~a\n" v))
  (disconnect admin-conn)
  (make-directory* (config-upload-dir cfg))
  (define root (current-custodian))
  (define server-cust (make-custodian root))
  (define metrics (make-app-metrics))
  (define pool (make-pool (config-database-url cfg) #:max-connections pool-size
                          #:observe-wait (λ (secs) (observe-pool-wait! metrics secs))
                          #:on-timeout (λ () (count-pool-timeout! metrics))))
  (define stop
    (with-handlers ([exn:fail? (λ (e) (custodian-shutdown-all server-cust) (disconnect pool) (raise e))])
      (parameterize ([current-custodian server-cust])
        (define hub (make-hub (make-loader pool cfg) #:metrics metrics #:record-peaks (make-peak-recorder pool)))
        (on-hub hub)
        (add-process-metrics! metrics hub server-cust root)
        (define stop-app (listen (make-handler (deps cfg pool hub metrics (config->store cfg) (plugin-limits plugin)) plugin) port
                                      (safety-limits-for (config-max-upload-bytes cfg))))
        (define stop-metrics
          (with-handlers ([exn:fail? (λ (e) (stop-app) (raise e))])
            (define mp (config-metrics-port cfg))
            (if mp (listen (make-metrics-handler (app-metrics-registry metrics)) mp) void)))
        (λ () (stop-app) (stop-metrics)))))
  (λ () (stop) (custodian-shutdown-all server-cust) (disconnect pool)))

;; Edition (Vectorof String) Env InputPort OutputPort -> (or Natural #f)
;; runs the edition's subcommand named by the first argument and returns its exit code; 2 plus the usage
;; line for an unknown one, #f when there are no arguments (meaning: serve)
(define (run-command ed argv env in out)
  (match (vector->list argv)
    [(list) #f]
    [(list name rest ...)
     (match (findf (λ (c) (equal? (command-name c) name)) (edition-commands ed))
       [(? command? c) ((command-run c) (list->vector rest) env in out)]
       [_ (eprintf "usage: orquelo [~a]\n" (string-join (map command-usage (edition-commands ed)) " | ")) 2])]))

;; Edition -> Void
;; serves until interrupted when there are no arguments, otherwise exits with the subcommand's code
(define (run-main ed)
  (define env (env->hash))
  (match (run-command ed (current-command-line-arguments) env (current-input-port) (current-output-port))
    [#f (serve-forever ed env)]
    [code (exit code)]))

;; Edition Env -> Void
;; loads the configuration from the environment and serves until interrupted
(define (serve-forever ed env)
  (define-values (cfg plug)
    (with-handlers ([exn:fail? (λ (e) (eprintf "~a\n" (exn-message e)) (exit 2))])
      (define cfg (load-config env (edition-streams ed)))
      (values cfg ((edition-configure ed) env cfg))))
  (define stop (start-server cfg #:plugin plug))
  (eprintf "listening on :~a\n" (config-port cfg))
  (when (config-metrics-port cfg) (eprintf "metrics on :~a\n" (config-metrics-port cfg)))
  (with-handlers ([exn:break? (λ (_) (stop))])
    (sync never-evt)))

(module+ main
  (require "editions/core.rkt")
  (run-main core-edition))

(module+ test
  (require rackunit)
  (define ed (edition "t" core-streams
                      (list (command "x" "x ..." (λ (argv env in out) (vector-length argv))))
                      (λ (env cfg) (error "unused"))))
  (define (run . argv) (run-command ed (list->vector argv) (hash) (open-input-string "") (open-output-string)))
  (test-case "run-command dispatch"
    (check-false (run))
    (check-equal? (run "x" "a" "b") 2)
    (parameterize ([current-error-port (open-output-string)])
      (check-equal? (run "bogus") 2)))
  (test-case "safety limits are built for any allowed upload size"
    (check-true (safety-limits? (safety-limits-for 1)))
    (check-true (safety-limits? (safety-limits-for 104857600))))
  (test-case "unknown subcommand prints the usage of the edition's commands"
    (define err (open-output-string))
    (parameterize ([current-error-port err]) (run "bogus"))
    (check-equal? (get-output-string err) "usage: orquelo [x ...]\n")))
