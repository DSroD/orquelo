#lang racket/base
;; The caller's address, and the 429 response for a caller that must back off.
(require racket/contract/base racket/list racket/string web-server/http "json.rkt")
(provide (contract-out
          [client-ip (-> request? boolean? string?)]
          [throttled! (-> real? none/c)]
          [too-many-requests (-> exact-nonnegative-integer? response?)]
          [exn:throttled-seconds (-> exn:throttled? exact-nonnegative-integer?)])
         exn:throttled?)

;; Request Boolean -> String
;; the address the throttle counts failures against: the rightmost X-Forwarded-For entry (the one our
;; own ingress appended; earlier ones are client-controlled) when behind a trusted proxy, else the peer
(define (client-ip req trust-proxy?)
  (define xff (and trust-proxy? (headers-assq* #"X-Forwarded-For" (request-headers/raw req))))
  (define last-entry
    (and xff (let ([es (string-split (bytes->string/utf-8 (header-value xff) #\?) ",")])
               (and (pair? es) (string-trim (last es))))))
  (if (and last-entry (non-empty-string? last-entry)) last-entry (request-client-ip req)))

;; An exn:throttled is a (exn:throttled String Marks Natural)
;; interpretation: a refusal, with the whole seconds the caller should wait
(struct exn:throttled exn:fail (seconds))

;; Real -> Nothing
;; 429 with Retry-After (whole seconds, rounded up)
(define (throttled! wait)
  (raise (exn:throttled "too many attempts, try again later" (current-continuation-marks) (inexact->exact (ceiling wait)))))

;; Natural -> Response
(define (too-many-requests seconds)
  (define r (error-response 429 "throttled" "too many attempts, try again later"))
  (struct-copy response r [headers (cons (header #"Retry-After" (string->bytes/utf-8 (number->string seconds))) (response-headers r))]))

(module+ test
  (require rackunit racket/promise net/url)
  (define (req . headers)
    (make-request #"POST" (string->url "/auth/password") (for/list ([h headers]) (make-header (car h) (cdr h)))
                  (delay '()) #f "10.0.0.9" 80 "10.0.0.9"))
  (test-case "client-ip: the peer, or the rightmost X-Forwarded-For entry behind a trusted proxy"
    (check-equal? (client-ip (req) #f) "10.0.0.9")
    (check-equal? (client-ip (req (cons #"X-Forwarded-For" #"1.1.1.1, 2.2.2.2")) #f) "10.0.0.9")
    (check-equal? (client-ip (req (cons #"X-Forwarded-For" #"6.6.6.6, 2.2.2.2")) #t) "2.2.2.2")
    (check-equal? (client-ip (req (cons #"X-Forwarded-For" #"3.3.3.3")) #t) "3.3.3.3")
    (check-equal? (client-ip (req) #t) "10.0.0.9"))
  (test-case "throttled! rounds the wait up; too-many-requests carries Retry-After"
    (check-equal? (with-handlers ([exn:throttled? exn:throttled-seconds]) (throttled! 0.2)) 1)
    (define r (too-many-requests 7))
    (check-equal? (response-code r) 429)
    (check-equal? (header-value (headers-assq* #"Retry-After" (response-headers r))) #"7")))
