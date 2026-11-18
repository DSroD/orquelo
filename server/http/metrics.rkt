#lang racket/base
;; The Prometheus scrape endpoint, served on its own port.
(require racket/contract/base net/url web-server/http "../metrics/registry.rkt")
(provide (contract-out [make-metrics-handler (-> registry? (-> request? response?))]))

;; Request -> Boolean
;; is it GET /metrics?
(define (scrape? req)
  (and (equal? (request-method req) #"GET")
       (equal? (map path/param-path (url-path (request-uri req))) '("metrics"))))

;; Registry -> Handler
;; GET /metrics renders the registry; everything else is a 404
(define (make-metrics-handler r)
  (λ (req)
    (if (scrape? req)
        (response/full 200 #"OK" (current-seconds) #"text/plain; version=0.0.4; charset=utf-8" '()
                       (list (string->bytes/utf-8 (render r))))
        (response/full 404 #"Not Found" (current-seconds) #"text/plain; charset=utf-8" '() (list #"not found\n")))))

(module+ test
  (require rackunit racket/promise)
  (define (req method path) (make-request method (string->url path) '() (delay '()) #f "127.0.0.1" 80 "127.0.0.1"))
  (define r (make-registry))
  (void (make-counter r "a_total" "a"))
  (define handle (make-metrics-handler r))

  (test-case "GET /metrics renders the registry"
    (define resp (handle (req #"GET" "/metrics")))
    (check-equal? (response-code resp) 200)
    (check-equal? (response-mime resp) #"text/plain; version=0.0.4; charset=utf-8"))
  (test-case "anything else is 404"
    (check-equal? (response-code (handle (req #"GET" "/"))) 404)
    (check-equal? (response-code (handle (req #"POST" "/metrics"))) 404)))
