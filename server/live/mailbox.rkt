#lang racket/base
;; A subscriber's pending messages. Every snapshot is the subscriber's whole view, so a newer
;; snapshot replaces an unread one; the end of the session is kept and nothing follows it.
;; A mailbox is an event: syncing on it waits for messages and returns all pending ones.
(require racket/contract/base racket/match "snapshot.rkt")
(provide (contract-out
          [struct queued ([message (or/c snapshot? 'ended)] [at real?])]
          [make-mailbox (-> mailbox?)]
          [mailbox? (-> any/c boolean?)]
          [mailbox-put! (-> mailbox? queued? void?)]))

;; A Queued is a (queued (or Snapshot 'ended) Real)
;; interp. a message for a subscriber and the monotonic time (ms) the hub queued it, to measure delivery delay.
(struct queued (message at))

;; A Mailbox is a (mailbox (Box [Listof Queued]) Semaphore)
;; interp. a subscriber's pending messages, oldest first, and a semaphore posted whenever the box goes
;; from empty to non-empty. The pending list is one of (), (snap), ('ended) or (snap 'ended).
(struct mailbox (pending ready)
  #:constructor-name mailbox*
  #:property prop:evt (λ (mb) (handle-evt (mailbox-ready mb) (λ (_) (take-pending! mb)))))

;; -> Mailbox
(define (make-mailbox) (mailbox* (box '()) (make-semaphore)))

;; Queued -> Boolean
(define (ended? q) (eq? (queued-message q) 'ended))

;; [Listof Queued] Queued -> [Listof Queued]
;; the pending messages after a new one arrives
(define (merge pending new)
  (cond [(ormap ended? pending) pending]
        [(ended? new) (append pending (list new))]
        [else (list new)]))

;; Mailbox Queued -> Void
;; adds a message; the reader is woken only when the mailbox was empty. The compare-and-set keeps
;; this correct when writers run in parallel threads.
(define (mailbox-put! mb new)
  (define pending (mailbox-pending mb))
  (let retry ()
    (define old (unbox pending))
    (cond [(not (box-cas! pending old (merge old new))) (retry)]
          [(null? old) (semaphore-post (mailbox-ready mb))])))

;; Mailbox -> [Listof Queued]
;; takes every pending message, leaving the mailbox empty
(define (take-pending! mb)
  (define pending (mailbox-pending mb))
  (let retry ()
    (define old (unbox pending))
    (if (box-cas! pending old '()) old (retry))))

(module+ test
  (require "../qa.rkt" rackunit "../domain.rkt")
  (define (snap n) (audience-snapshot (session-brief "c" "l") (deck-brief n "t") #f #f (qa-state #f #f #f #f '() #f)))
  (define (messages qs) (map queued-message qs))
  (define (put! mb m) (mailbox-put! mb (queued m 0)))

  (test-case "the latest snapshot wins"
    (define mb (make-mailbox))
    (for ([n 3]) (put! mb (snap n)))
    (check-equal? (messages (sync mb)) (list (snap 2))))

  (test-case "'ended is kept after a pending snapshot, and nothing follows it"
    (define mb (make-mailbox))
    (put! mb (snap 1))
    (put! mb 'ended)
    (put! mb (snap 2))
    (check-equal? (messages (sync mb)) (list (snap 1) 'ended)))

  (test-case "no lost wake-up: a put after a take wakes the reader again"
    (define mb (make-mailbox))
    (put! mb (snap 1))
    (check-equal? (messages (sync mb)) (list (snap 1)))
    (put! mb (snap 2))
    (check-equal? (messages (sync/timeout 1 mb)) (list (snap 2))))

  (test-case "the reader blocks while empty"
    (define mb (make-mailbox))
    (check-false (sync/timeout 0.05 mb))
    (put! mb 'ended)
    (check-equal? (messages (sync mb)) '(ended))
    (check-false (sync/timeout 0.05 mb))))
