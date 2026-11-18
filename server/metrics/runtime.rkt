#lang racket/base
;; Racket runtime metrics: memory, GC, CPU, threads and build info, plus a GC pause listener.
(require racket/contract/base racket/match "registry.rkt")
(provide (contract-out
          [runtime-families (-> custodian? custodian? (listof family?))]
          [start-gc-listener! (-> histogram? thread?)]))

;; Seconds: wall-clock time when this module was instantiated, i.e. the process start
(define started (/ (current-inexact-milliseconds) 1000))

;; The runtime's GC log payload (see `racket --help` -W debug@GC); mode is 'minor, 'major or 'incremental
;; and times are in real milliseconds.
(struct gc-info (mode pre-amount pre-admin-amount code-amount post-amount post-admin-amount
                 start-process-time end-process-time start-time end-time)
  #:prefab)

;; Custodian Custodian -> Natural
;; live threads managed by `c` and its sub-custodians, up to the ancestor `super`.
;; vector-set-performance-stats! only counts runnable threads, so we walk the custodian tree.
(define (count-threads c super)
  (for/sum ([x (in-list (custodian-managed-list c super))])
    (cond [(thread? x) (if (thread-dead? x) 0 1)]
          [(custodian? x) (count-threads x super)]
          [else 0])))

;; -> Natural
;; thread context switches since start (slot 4 of the global performance stats)
(define (context-switches)
  (define v (make-vector 5 0))
  (vector-set-performance-stats! v)
  (vector-ref v 4))

;; String String Symbol Real -> Family
;; a family with a single unlabeled sample
(define (single name help type v) (family name help type (list (sample "" '() v))))

;; Custodian Custodian -> [Listof Family]
;; the runtime families; threads are counted under `server-cust` (a descendant of `root`)
(define (runtime-families server-cust root)
  (list (single "racket_memory_bytes" "Bytes currently in use" 'gauge (current-memory-use))
        (single "racket_memory_allocated_bytes_total" "Bytes allocated since start" 'counter (current-memory-use 'cumulative))
        (single "racket_gc_seconds_total" "Time spent in garbage collection" 'counter (/ (current-gc-milliseconds) 1000))
        (single "racket_cpu_seconds_total" "Process CPU time" 'counter (/ (current-process-milliseconds) 1000))
        (single "racket_threads" "Live Racket threads of the server" 'gauge (count-threads server-cust root))
        (single "racket_thread_switches_total" "Thread context switches" 'counter (context-switches))
        (single "process_start_time_seconds" "Start time of the process since the Unix epoch" 'gauge started)
        (family "orquelo_build_info" "Build information" 'gauge
                (list (sample "" (list (cons "racket_version" (version))) 1)))))

;; Histogram -> Thread
;; observes every garbage collection's pause in the histogram (labeled "minor" or "major"),
;; reading the runtime's GC log forever
(define (start-gc-listener! h)
  (define receiver (make-log-receiver (current-logger) 'debug 'GC))
  (thread
   (λ ()
     (let loop ()
       (match (sync receiver)
         [(vector _ _ (? gc-info? i) _)
          (observe! h (list (if (eq? (gc-info-mode i) 'minor) "minor" "major"))
                    (/ (- (gc-info-end-time i) (gc-info-start-time i)) 1000.0))]
         [_ (void)])
       (loop)))))

(module+ test
  (require rackunit racket/list)
  (define (named fs n) (findf (λ (f) (equal? (family-name f) n)) fs))

  (test-case "runtime families are all present"
    (define root (current-custodian))
    (define fs (runtime-families (make-custodian root) root))
    (for ([n '("racket_memory_bytes" "racket_memory_allocated_bytes_total" "racket_gc_seconds_total"
               "racket_cpu_seconds_total" "racket_threads" "racket_thread_switches_total" "process_start_time_seconds" "orquelo_build_info")])
      (check-not-false (named fs n) n))
    (check-equal? (sample-value (car (family-samples (named fs "racket_threads")))) 0))

  (test-case "context switches are counted"
    (define before (context-switches))
    (for ([_ 10]) (thread-wait (thread void)))
    (check-true (> (context-switches) before)))

  (test-case "threads are counted per custodian"
    (define root (current-custodian))
    (define c (make-custodian root))
    (define ts (parameterize ([current-custodian c]) (for/list ([_ 3]) (thread (λ () (sync never-evt))))))
    (check-equal? (count-threads c root) 3)
    (kill-thread (car ts))
    (check-equal? (count-threads c root) 2)
    (custodian-shutdown-all c))

  (test-case "a major collection is observed"
    (define r (make-registry))
    (define h (make-histogram r "gc" "gc" '(0.001 1) #:labels '("kind")))
    (start-gc-listener! h)
    (collect-garbage 'major)
    (sleep 0.3)
    (check-regexp-match #rx"gc_count{kind=\"major\"} [1-9]" (render r))))
