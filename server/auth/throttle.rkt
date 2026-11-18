#lang racket/base
;; Login throttling: consecutive failures per (email, ip) back off exponentially, and a high
;; per-ip failure count stops one address from trying many emails. In memory, one process.
;; The clock is a parameter so tests need no sleeping.
(require (except-in racket/contract/base ->) (prefix-in c: (only-in racket/contract/base ->)))
(provide (contract-out
          [make-throttle (->* () (#:clock (c:-> real?)) throttle?)]
          [throttle-wait (c:-> throttle? string? string? (or/c #f (and/c real? positive?)))]
          [throttle-fail! (c:-> throttle? string? string? void?)]
          [throttle-clear! (c:-> throttle? string? string? void?)]
          [backoff-seconds (c:-> exact-nonnegative-integer? exact-nonnegative-integer? exact-nonnegative-integer?)])
         throttle?)

(define pair-threshold 5)
(define ip-threshold 50)
(define max-backoff 900) ; 15 minutes
(define sweep-above 10000)

;; A Strike is a (strike Natural Real)
;; interpretation: consecutive failures and the time of the last one, in seconds
(struct strike (count last))

;; A Throttle is a (throttle (MutableHash Key Strike) Semaphore (-> Real))
;; where a Key is (cons String String) for (lower-cased email, ip) or a String for an ip alone;
;; interpretation: the strikes so far, the lock guarding every access, and the clock
(struct throttle (strikes lock clock))

;; [#:clock (-> Real)] -> Throttle
(define (make-throttle #:clock [clock (λ () (/ (current-inexact-milliseconds) 1000))])
  (throttle (make-hash) (make-semaphore 1) clock))

;; Natural Natural -> Natural
;; seconds to wait after `n` consecutive failures when backing off starts at `threshold`:
;; none below it, then 1, 2, 4, … capped
(define (backoff-seconds n threshold)
  (if (< n threshold) 0 (min max-backoff (expt 2 (- n threshold)))))

;; String -> String
(define (norm email) (string-downcase email))

;; Throttle Key Natural -> Real
;; seconds still to wait for `key`, 0 when none
(define (remaining t key threshold)
  (define s (hash-ref (throttle-strikes t) key #f))
  (if s
      (max 0 (- (+ (strike-last s) (backoff-seconds (strike-count s) threshold)) ((throttle-clock t))))
      0))

;; Throttle String String -> (or #f PositiveReal)
;; seconds to wait before this (email, ip) may try again, or #f to proceed
(define (throttle-wait t email ip)
  (call-with-semaphore
   (throttle-lock t)
   (λ ()
     (define w (max (remaining t (cons (norm email) ip) pair-threshold)
                    (remaining t ip ip-threshold)))
     (and (> w 0) w))))

;; Throttle Key Natural -> Void
(define (bump! t key)
  (define s (hash-ref (throttle-strikes t) key #f))
  (hash-set! (throttle-strikes t) key (strike (add1 (if s (strike-count s) 0)) ((throttle-clock t)))))

;; Throttle String String -> Void
;; records a failed attempt, and drops expired entries when the table has grown large
(define (throttle-fail! t email ip)
  (call-with-semaphore
   (throttle-lock t)
   (λ ()
     (bump! t (cons (norm email) ip))
     (bump! t ip)
     (when (> (hash-count (throttle-strikes t)) sweep-above) (sweep! t)))))

;; Throttle String String -> Void
;; a success forgets the (email, ip) key; the ip's own count stays
(define (throttle-clear! t email ip)
  (call-with-semaphore (throttle-lock t) (λ () (hash-remove! (throttle-strikes t) (cons (norm email) ip)))))

;; Throttle -> Void
;; removes the strikes whose wait has passed and that are a full max-backoff old
(define (sweep! t)
  (define now ((throttle-clock t)))
  (for ([(k s) (in-hash (hash-copy (throttle-strikes t)))])
    (when (> (- now (strike-last s)) (* 2 max-backoff))
      (hash-remove! (throttle-strikes t) k))))

(module+ test
  (require rackunit)
  (define now 0)
  (define (fresh) (set! now 0) (make-throttle #:clock (λ () now)))

  (test-case "backoff-seconds"
    (check-equal? (map (λ (n) (backoff-seconds n 5)) '(0 1 4 5 6 7 8 14 15 16 100))
                  '(0 0 0 1 2 4 8 512 900 900 900)))
  (test-case "four failures leave no wait; the 5th gives 1 s, the 6th 2 s"
    (define t (fresh))
    (for ([_ 4]) (throttle-fail! t "a@x.org" "1.1.1.1"))
    (check-false (throttle-wait t "a@x.org" "1.1.1.1"))
    (throttle-fail! t "a@x.org" "1.1.1.1")
    (check-equal? (throttle-wait t "a@x.org" "1.1.1.1") 1)
    (set! now 1)
    (check-false (throttle-wait t "a@x.org" "1.1.1.1"))
    (throttle-fail! t "a@x.org" "1.1.1.1")
    (check-equal? (throttle-wait t "a@x.org" "1.1.1.1") 2)
    (set! now 2.5)
    (check-equal? (throttle-wait t "a@x.org" "1.1.1.1") 0.5))
  (test-case "the 15th failure is capped at 900 s"
    (define t (fresh))
    (for ([_ 15]) (throttle-fail! t "a@x.org" "1.1.1.1"))
    (check-equal? (throttle-wait t "a@x.org" "1.1.1.1") 900)
    (set! now 899)
    (check-equal? (throttle-wait t "a@x.org" "1.1.1.1") 1)
    (set! now 900)
    (check-false (throttle-wait t "a@x.org" "1.1.1.1")))
  (test-case "the email is case-insensitive; other emails and ips are unaffected"
    (define t (fresh))
    (for ([_ 5]) (throttle-fail! t "A@X.org" "1.1.1.1"))
    (check-true (and (throttle-wait t "a@x.org" "1.1.1.1") #t))
    (check-false (throttle-wait t "b@x.org" "1.1.1.1"))
    (check-false (throttle-wait t "a@x.org" "2.2.2.2")))
  (test-case "success resets the (email, ip) key"
    (define t (fresh))
    (for ([_ 6]) (throttle-fail! t "a@x.org" "1.1.1.1"))
    (throttle-clear! t "a@x.org" "1.1.1.1")
    (check-false (throttle-wait t "a@x.org" "1.1.1.1"))
    (for ([_ 4]) (throttle-fail! t "a@x.org" "1.1.1.1"))
    (check-false (throttle-wait t "a@x.org" "1.1.1.1")))
  (test-case "the per-ip cap fires across many emails"
    (define t (fresh))
    (for ([i 49]) (throttle-fail! t (format "u~a@x.org" i) "1.1.1.1"))
    (check-false (throttle-wait t "fresh@x.org" "1.1.1.1"))
    (throttle-fail! t "u49@x.org" "1.1.1.1")
    (check-equal? (throttle-wait t "fresh@x.org" "1.1.1.1") 1)
    (check-false (throttle-wait t "fresh@x.org" "2.2.2.2")))
  (test-case "stale entries are pruned once the table is large"
    (define t (fresh))
    (for ([i 5001]) (throttle-fail! t (format "u~a@x.org" i) (format "ip~a" i)))
    (check-equal? (hash-count (throttle-strikes t)) 10002) ; over the limit, nothing is old yet
    (set! now (* 3 max-backoff))
    (throttle-fail! t "late@x.org" "9.9.9.9")
    (check-equal? (hash-count (throttle-strikes t)) 2)))
