#lang racket/base
;; Token-bucket rate limiting per key (a user id, an ip, ...). In memory, one process.
;; The clock is a keyword argument so tests need no sleeping.
(require (except-in racket/contract/base ->) (prefix-in c: (only-in racket/contract/base ->)))
(provide (contract-out
          [make-bucket (->* (exact-positive-integer? (and/c real? positive?)) (#:clock (c:-> real?)) bucket?)]
          [bucket-take! (c:-> bucket? any/c (or/c #f (and/c real? positive?)))])
         bucket?)

;; Natural: keys above which a sweep is considered, and the least seconds between sweeps
(define sweep-above 10000)
(define sweep-interval 60)

;; A Level is a (level Real Real)
;; interpretation: the tokens a key held, and the clock time that count was taken
(struct level (tokens at))

;; A Bucket is a (bucket Natural Real (MutableHash Key Level) Semaphore (-> Real) (Boxof Real))
;; where a Key is any equal?-comparable value;
;; interpretation: the capacity, the tokens refilled per second, the level per key, the lock guarding
;; every access, the clock in seconds, and the time of the last sweep
(struct bucket (capacity rate levels lock clock swept))

;; -> Real
;; seconds on a clock that never goes backwards
(define (monotonic-seconds) (/ (current-inexact-monotonic-milliseconds) 1000))

;; Natural Real [#:clock (-> Real)] -> Bucket
(define (make-bucket capacity rate #:clock [clock monotonic-seconds])
  (bucket capacity rate (make-hash) (make-semaphore 1) clock (box (clock))))

;; Bucket Level Real -> Real
;; the tokens `lvl` holds at time `now`
(define (tokens-at b lvl now)
  (min (bucket-capacity b) (+ (level-tokens lvl) (* (bucket-rate b) (- now (level-at lvl))))))

;; Bucket Key -> (or #f PositiveReal)
;; takes one token for `key`: #f when allowed, else the seconds until a token is available
(define (bucket-take! b key)
  (call-with-semaphore
   (bucket-lock b)
   (λ ()
     (define now ((bucket-clock b)))
     (define lvl (hash-ref (bucket-levels b) key (level (bucket-capacity b) now)))
     (define tokens (tokens-at b lvl now))
     (cond
       [(>= tokens 1)
        (hash-set! (bucket-levels b) key (level (- tokens 1) now))
        (maybe-sweep! b now)
        #f]
       [else
        (hash-set! (bucket-levels b) key (level tokens now))
        (/ (- 1 tokens) (bucket-rate b))]))))

;; Bucket Real -> Void
;; sweeps when the table is large and the last sweep is old enough
(define (maybe-sweep! b now)
  (when (and (> (hash-count (bucket-levels b)) sweep-above)
             (>= (- now (unbox (bucket-swept b))) sweep-interval))
    (set-box! (bucket-swept b) now)
    (sweep! b now)))

;; Bucket Real -> Void
;; removes the keys that have refilled completely: forgetting them changes nothing
(define (sweep! b now)
  (define full
    (for/list ([(k lvl) (in-hash (bucket-levels b))]
               #:when (>= (tokens-at b lvl now) (bucket-capacity b)))
      k))
  (for ([k (in-list full)]) (hash-remove! (bucket-levels b) k)))

(module+ test
  (require rackunit)
  (define now (box 0))
  (define (fresh capacity rate) (set-box! now 0) (make-bucket capacity rate #:clock (λ () (unbox now))))

  (test-case "allows capacity, then refuses with the wait for the next token"
    (define b (fresh 3 1/2))
    (for ([_ 3]) (check-false (bucket-take! b "a")))
    (check-equal? (bucket-take! b "a") 2)
    (set-box! now 1)
    (check-equal? (bucket-take! b "a") 1))
  (test-case "refills with the clock, never above capacity"
    (define b (fresh 2 1))
    (for ([_ 2]) (bucket-take! b "a"))
    (set-box! now 1)
    (check-false (bucket-take! b "a"))
    (check-equal? (bucket-take! b "a") 1)
    (set-box! now 100)
    (for ([_ 2]) (check-false (bucket-take! b "a")))
    (check-true (and (bucket-take! b "a") #t)))
  (test-case "keys are independent"
    (define b (fresh 1 1))
    (check-false (bucket-take! b "a"))
    (check-true (and (bucket-take! b "a") #t))
    (check-false (bucket-take! b "b"))
    (check-false (bucket-take! b 7)))
  (test-case "refilled keys are swept once the table is large, at most once per interval"
    (define b (fresh 1 1))
    (for ([i 10000]) (bucket-take! b i))
    (check-equal? (hash-count (bucket-levels b)) 10000)
    (set-box! now 5)
    (bucket-take! b 'late)
    (check-equal? (hash-count (bucket-levels b)) 10001) ; refilled, but a sweep is not yet due
    (set-box! now 61)
    (bucket-take! b 'later)
    (check-equal? (hash-count (bucket-levels b)) 1)))
