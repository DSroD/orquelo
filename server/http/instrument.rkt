#lang racket/base
;; Request instrumentation: counts and times every request by method, route template and status.
(require racket/contract/base web-server/http "../metrics/app.rkt")
(provide (contract-out
          [set-route! (-> string? void?)]
          [instrumented (-> app-metrics? (-> request? response?) (-> request? response?))]))

;; (Parameter (or (Box String) #f)): where the running request's route template goes
(define current-route (make-parameter #f))

;; String -> Void
;; names the matched route template (e.g. "/api/s/:pid/:code/vote") for the current request's metrics
(define (set-route! route)
  (define b (current-route))
  (when b (set-box! b route)))

;; Bytes -> String
;; the upper-cased method when standard, else "OTHER": clients control the method, so it must not mint labels
(define (method-label m)
  (define up (string-upcase (bytes->string/utf-8 m #\?)))
  (if (member up '("GET" "HEAD" "POST" "PUT" "PATCH" "DELETE" "OPTIONS")) up "OTHER"))

;; AppMetrics Handler -> Handler
;; records the request after the handler returns its response; a streaming response is timed until
;; it is returned, not until the stream ends
(define (instrumented m handler)
  (λ (req)
    (define route (box "unknown"))
    (define t0 (current-inexact-monotonic-milliseconds))
    (define resp (parameterize ([current-route route]) (handler req)))
    (observe-request! m (method-label (request-method req)) (unbox route) (response-code resp)
                      (/ (- (current-inexact-monotonic-milliseconds) t0) 1000.0))
    resp))

(module+ test
  (require rackunit net/url racket/promise "../metrics/registry.rkt")
  (define (req method) (make-request method (string->url "/x") '() (delay '()) #f "127.0.0.1" 80 "127.0.0.1"))
  (define (ok-response) (response/full 204 #"No Content" (current-seconds) #f '() '()))

  (test-case "records method, route and status; route defaults to unknown"
    (define m (make-app-metrics))
    (define h (instrumented m (λ (r) (if (equal? (request-method r) #"POST") (begin (set-route! "/a/:id") (ok-response)) (ok-response)))))
    (h (req #"POST"))
    (h (req #"BREW"))
    (define out (render (app-metrics-registry m)))
    (check-regexp-match #rx"requests_total{method=\"POST\",route=\"/a/:id\",status=\"204\"} 1" out)
    (check-regexp-match #rx"requests_total{method=\"OTHER\",route=\"unknown\",status=\"204\"} 1" out)
    (check-regexp-match #rx"duration_seconds_count{method=\"POST\",route=\"/a/:id\"} 1" out))

  (test-case "set-route! outside a request is a no-op"
    (check-not-exn (λ () (set-route! "/x")))))
