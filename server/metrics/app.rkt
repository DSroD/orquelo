#lang racket/base
;; The application's own metrics (HTTP, votes, hub, SSE) and the helpers that record them.
(require racket/contract/base "registry.rkt")
(provide (contract-out
          [struct app-metrics ([registry registry?] [http-requests counter?] [http-duration histogram?] [votes counter?]
                               [hub-call histogram?] [hub-push histogram?] [sse-messages counter?] [sse-delivery histogram?]
                               [pool-wait histogram?] [pool-timeouts counter?])]
          [make-app-metrics (-> app-metrics?)]
          [observe-request! (-> app-metrics? string? string? natural-number/c real? void?)]
          [count-vote! (-> app-metrics? (or/c 'ok 'not-open 'invalid) void?)]
          [observe-hub-call! (-> app-metrics? real? void?)]
          [observe-push! (-> app-metrics? real? void?)]
          [count-messages! (-> app-metrics? symbol? natural-number/c natural-number/c void?)]
          [observe-delivery! (-> app-metrics? symbol? real? void?)]
          [observe-pool-wait! (-> app-metrics? real? void?)]
          [count-pool-timeout! (-> app-metrics? void?)]))

;; An AppMetrics is an (app-metrics Registry Counter Histogram Counter Histogram Histogram Counter Histogram
;;                                 Histogram Counter)
;; interp. the registry with the application's metrics, in this order: HTTP requests by method, route and
;; status; HTTP duration; votes by result; hub round trips (queue wait included); hub pushes (projection
;; of all subscribers); SSE messages sent or suppressed by role; SSE delivery delay by role; the wait for a
;; pooled database connection; leases that gave up waiting.
(struct app-metrics (registry http-requests http-duration votes hub-call hub-push sse-messages sse-delivery
                              pool-wait pool-timeouts))

;; [Listof Real]: bucket bounds in seconds for request-scale and for in-process timings
(define http-buckets '(0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 2.5 5 10 30))
(define fast-buckets '(0.0001 0.00025 0.0005 0.001 0.0025 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 2.5 5))
(define hub-call-buckets (append fast-buckets '(10 30)))
(define pool-wait-buckets (append fast-buckets '(10)))

;; -> AppMetrics
(define (make-app-metrics)
  (define r (make-registry))
  (app-metrics
   r
   (make-counter r "orquelo_http_requests_total" "HTTP requests handled" #:labels '("method" "route" "status"))
   (make-histogram r "orquelo_http_request_duration_seconds" "HTTP handler time until the response is returned"
                   http-buckets #:labels '("method" "route"))
   (make-counter r "orquelo_votes_total" "Vote attempts by result" #:labels '("result"))
   (make-histogram r "orquelo_hub_call_seconds" "Hub round trip, queue wait included" hub-call-buckets)
   (make-histogram r "orquelo_hub_push_seconds" "Time the hub spends projecting and sending to a session's subscribers" fast-buckets)
   (make-counter r "orquelo_sse_messages_total" "Snapshots sent to subscribers, or suppressed because nothing changed for them"
                 #:labels '("role" "kind"))
   (make-histogram r "orquelo_sse_delivery_seconds" "Delay from the hub queueing a message to the stream writing it"
                   fast-buckets #:labels '("role"))
   (make-histogram r "orquelo_db_pool_wait_seconds" "Wait for a pooled database connection" pool-wait-buckets)
   (make-counter r "orquelo_db_pool_timeouts_total" "Connection leases that gave up waiting for the pool")))

;; AppMetrics String String Natural Real -> Void
(define (observe-request! m method route status secs)
  (inc! (app-metrics-http-requests m) (list method route (number->string status)))
  (observe! (app-metrics-http-duration m) (list method route) secs))

;; AppMetrics (or 'ok 'not-open 'invalid) -> Void
(define (count-vote! m result)
  (inc! (app-metrics-votes m) (list (case result [(not-open) "not_open"] [else (symbol->string result)]))))

;; AppMetrics Real -> Void
(define (observe-hub-call! m secs) (observe! (app-metrics-hub-call m) '() secs))

;; AppMetrics Real -> Void
(define (observe-push! m secs) (observe! (app-metrics-hub-push m) '() secs))

;; AppMetrics Role Natural Natural -> Void
;; counts the messages one push sent and suppressed for the role
(define (count-messages! m role sent suppressed)
  (define name (symbol->string role))
  (when (> sent 0) (inc! (app-metrics-sse-messages m) (list name "sent") sent))
  (when (> suppressed 0) (inc! (app-metrics-sse-messages m) (list name "suppressed") suppressed)))

;; AppMetrics Real -> Void
(define (observe-pool-wait! m secs) (observe! (app-metrics-pool-wait m) '() secs))

;; AppMetrics -> Void
(define (count-pool-timeout! m) (inc! (app-metrics-pool-timeouts m) '()))

;; AppMetrics Role Real -> Void
(define (observe-delivery! m role secs) (observe! (app-metrics-sse-delivery m) (list (symbol->string role)) secs))

(module+ test
  (require rackunit)
  (test-case "helpers record into the registry"
    (define m (make-app-metrics))
    (observe-request! m "GET" "/healthz" 200 0.001)
    (count-vote! m 'not-open)
    (count-messages! m 'audience 2 0)
    (observe-delivery! m 'moderator 0.002)
    (observe-pool-wait! m 0.003)
    (count-pool-timeout! m)
    (define out (render (app-metrics-registry m)))
    (for ([rx '(#rx"orquelo_http_requests_total{method=\"GET\",route=\"/healthz\",status=\"200\"} 1"
                #rx"orquelo_votes_total{result=\"not_open\"} 1"
                #rx"orquelo_sse_messages_total{role=\"audience\",kind=\"sent\"} 2"
                #rx"orquelo_sse_delivery_seconds_count{role=\"moderator\"} 1"
                #rx"orquelo_db_pool_wait_seconds_count 1"
                #rx"orquelo_db_pool_timeouts_total 1")])
      (check-regexp-match rx out))
    (check-false (regexp-match? #rx"kind=\"suppressed\"" out))))
