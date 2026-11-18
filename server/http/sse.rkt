#lang racket/base
;; Server-Sent Events response driven by a hub subscription.
(require racket/contract/base racket/match json web-server/http "../live/hub.rkt" "../live/mailbox.rkt" "json.rkt")
(provide (contract-out
          [sse-response (->* ((-> (or/c sub? #f)) (-> sub? any/c))
                             (#:heartbeat real? #:headers (listof header?) #:on-delivery (-> real? any)) response?)]
          [stream-events! (->* (output-port? (-> (or/c sub? #f)) (-> sub? any/c) real?) (#:on-delivery (-> real? any)) void?)]))

;; The stream carries "snapshot" events (Snapshot structs encoded by snapshot->jsexpr) and a final "ended".

(define sse-headers
  (list (make-header #"Cache-Control" #"no-cache") (make-header #"X-Accel-Buffering" #"no")))

;; [-> (or Sub #f)] [Sub -> Any] [#:on-delivery [Real -> Any]] -> Response
;; subscribes when the response is written and always unsubscribes when the stream ends;
;; on-delivery gets the seconds each message waited between the hub queueing it and being written
(define (sse-response subscribe! unsubscribe! #:heartbeat [hb 15] #:headers [extra '()] #:on-delivery [on-delivery void])
  (response/output #:mime-type #"text/event-stream" #:headers (append sse-headers extra)
                   (λ (out) (stream-events! out subscribe! unsubscribe! hb #:on-delivery on-delivery))))

;; OutputPort (or String Bytes) ... -> Void
(define (emit! out . strs)
  (for ([s strs]) (write-bytes (if (bytes? s) s (string->bytes/utf-8 s)) out))
  (flush-output out))

;; [Real -> Any] Real -> Void
;; reports the seconds since the monotonic time `at` (ms)
(define (delivered! on-delivery at)
  (on-delivery (/ (- (current-inexact-monotonic-milliseconds) at) 1000.0))
  (void))

;; Exn -> Void
;; logs a failure of the stream that is not the client going away
(define (log-stream-failure e) (log-error "event stream failed: ~a" (exn-message e)))

;; OutputPort [Listof Queued] [Real -> Any] -> Boolean
;; writes the pending messages; #f once the session has ended, so the stream is over
(define (deliver! out pending on-delivery)
  (for/and ([q pending])
    (match q
      [(queued 'ended at) (emit! out "event: ended\ndata: {}\n\n") (delivered! on-delivery at) #f]
      [(queued snap at)
       (emit! out "event: snapshot\ndata: " (jsexpr->bytes (snapshot->jsexpr snap)) "\n\n")
       (delivered! on-delivery at)
       #t])))

;; OutputPort [-> (or Sub #f)] [Sub -> Any] Real [#:on-delivery [Real -> Any]] -> Void
;; writes events until the session ends or the client goes away (a write failure)
(define (stream-events! out subscribe! unsubscribe! hb #:on-delivery [on-delivery void])
  (define sb (subscribe!))
  (when sb
    (dynamic-wind
     void
     (λ ()
       (with-handlers ([exn:fail:network? void] ; write failure = client gone
                       [exn:fail? log-stream-failure])
         (emit! out "retry: 3000\n\n")
         (let loop ()
           (match (sync/timeout hb (sub-mailbox sb))
             [#f (emit! out ": hb\n\n") (loop)]
             [pending (when (deliver! out pending on-delivery) (loop))]))))
     (λ () (unsubscribe! sb)))))

(module+ test
  (require "../qa.rkt" rackunit "../domain.rkt" "../live/snapshot.rkt" "../live/mailbox.rkt" (submod "../live/hub.rkt" testing))
  (define (snap n) (audience-snapshot (session-brief "c" "l") (deck-brief n "t") #f #f (qa-state #f #f #f #f '() #f)))
  (define (run-stream mb #:hb [hb 15] #:out [out (open-output-bytes)])
    (define unsubbed '())
    (define sb (sub 'audience "p" mb (current-thread) #f))
    (stream-events! out (λ () sb) (λ (s) (set! unsubbed (cons s unsubbed))) hb)
    (values out unsubbed sb))

  (test-case "retry, snapshot, then ended closes the stream"
    (define mb (make-mailbox))
    (mailbox-put! mb (queued (snap 1) 0))
    (mailbox-put! mb (queued 'ended 0))
    (define-values (out unsubbed sb) (run-stream mb))
    (check-equal? (get-output-bytes out)
                  (bytes-append #"retry: 3000\n\nevent: snapshot\ndata: " (jsexpr->bytes (snapshot->jsexpr (snap 1)))
                                #"\n\nevent: ended\ndata: {}\n\n"))
    (check-equal? unsubbed (list sb)))

  (test-case "on-delivery gets the delay of each queued message"
    (define mb (make-mailbox))
    (define delays '())
    (mailbox-put! mb (queued (snap 1) (current-inexact-monotonic-milliseconds)))
    (mailbox-put! mb (queued 'ended (current-inexact-monotonic-milliseconds)))
    (define sb (sub 'audience "p" mb (current-thread) #f))
    (stream-events! (open-output-bytes) (λ () sb) void 15 #:on-delivery (λ (s) (set! delays (cons s delays))))
    (check-equal? (length delays) 2)
    (check-true (andmap (λ (d) (<= 0 d 1)) delays)))

  (test-case "heartbeat while idle"
    (define mb (make-mailbox))
    (thread (λ () (sleep 0.25) (mailbox-put! mb (queued 'ended 0))))
    (define-values (out unsubbed sb) (run-stream mb #:hb 0.05))
    (check-regexp-match #rx#": hb\n\n" (get-output-bytes out)))

  (test-case "unsubscribes when the port fails"
    (define mb (make-mailbox))
    (define bad (make-output-port 'bad always-evt (λ (bs s e nb? eb?) (raise (exn:fail:network "closed" (current-continuation-marks)))) void))
    (define-values (out unsubbed sb) (run-stream mb #:out bad))
    (check-equal? unsubbed (list sb)))

  (test-case "unsubscribes after a failed write mid-stream"
    (define mb (make-mailbox))
    (define n 0)
    (define flaky (make-output-port 'flaky always-evt
                                    (λ (bs s e nb? eb?) (set! n (add1 n)) (if (> n 2) (raise (exn:fail:network "closed" (current-continuation-marks))) (- e s)))
                                    void))
    (thread (λ () (for ([i 5]) (mailbox-put! mb (queued (snap i) 0)) (sleep 0.02))))
    (define-values (out unsubbed sb) (run-stream mb #:out flaky))
    (check-equal? unsubbed (list sb)))

  (test-case "unsubscribes when the stream fails for another reason, which is not swallowed silently"
    (define mb (make-mailbox))
    (mailbox-put! mb (queued (snap 1) 0))
    (define bad (make-output-port 'bad always-evt (λ (bs s e nb? eb?) (error "bug")) void))
    (define-values (out unsubbed sb) (run-stream mb #:out bad))
    (check-equal? unsubbed (list sb)))

  (test-case "no subscription, nothing written"
    (define out (open-output-bytes))
    (stream-events! out (λ () #f) void 1)
    (check-equal? (get-output-bytes out) #"")))
