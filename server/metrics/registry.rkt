#lang racket/base
;; Prometheus metrics registry: counters, histograms and collectors, rendered in the text
;; exposition format (0.0.4). Gauges are collectors: functions computing families at scrape time.
(require racket/contract/base racket/list racket/string racket/math racket/vector)
(provide (contract-out
          [struct family ([name string?] [help string?] [type (or/c 'counter 'gauge 'histogram)]
                          [samples (listof sample?)])]
          [struct sample ([suffix string?] [labels (listof (cons/c string? string?))] [value real?])]
          [registry? (-> any/c boolean?)]
          [counter? (-> any/c boolean?)]
          [histogram? (-> any/c boolean?)]
          [make-registry (-> registry?)]
          [make-counter (->* (registry? name/c string?) (#:labels (listof string?)) counter?)]
          [make-histogram (->* (registry? name/c string? (listof (and/c real? positive?))) (#:labels (listof string?)) histogram?)]
          [inc! (->* (counter? (listof string?)) ((>=/c 0)) void?)]
          [observe! (-> histogram? (listof string?) real? void?)]
          [add-collector! (-> registry? (-> (listof family?)) void?)]
          [render (-> registry? string?)]
          [render-families (-> (listof family?) string?)]))

;; A Name is a string matching the Prometheus metric name syntax.
(define name/c (and/c string? #px"^[a-zA-Z_:][a-zA-Z0-9_:]*$"))

;; A Family is a (family String String (or 'counter 'gauge 'histogram) [Listof Sample])
;; interp. one metric with its help text and current samples.
(struct family (name help type samples) #:transparent)
;; A Sample is a (sample String [Listof (Pair String String)] Real)
;; interp. one line: the name suffix ("_bucket", "_sum", ... or ""), its label pairs and its value.
(struct sample (suffix labels value) #:transparent)

;; All mutable state is an immutable value in a box, replaced by compare-and-swap (box-update!).
;; Unlike a semaphore, a thread killed mid-update (a dropped connection) cannot block the others.
;; A Registry is a (registry (Box [Listof (-> [Listof Family])]) (Box [Listof String]))
;; interp. the collectors in registration order (newest first) and the metric names taken.
(struct registry (collectors names))
;; A Counter is a (counter String [Listof String] (Box (Hash [Listof String] Real)))
;; interp. monotonic counts per label-value tuple.
(struct counter (name labels cells))
;; A Histogram is a (histogram String [Listof String] [Listof Real] (Box (Hash [Listof String] Cell)))
;; interp. observations per label-value tuple, bucketed by the ascending upper bounds.
(struct histogram (name labels bounds cells))
;; A Cell is a (cell Vector Real): immutable per-bucket counts (the last slot is +Inf) and the sum of observations.
(struct cell (counts sum))

;; (Box X) (X -> X) -> Void
;; atomically replaces the box content by (f content), retrying if another thread got in between;
;; f must be pure
(define (box-update! b f)
  (define old (unbox b))
  (unless (box-cas! b old (f old)) (box-update! b f)))

;; -> Registry
(define (make-registry) (registry (box '()) (box '())))

;; Registry (-> [Listof Family]) -> Void
(define (add-collector! r collect)
  (box-update! (registry-collectors r) (λ (cs) (cons collect cs))))

;; Registry Name -> Void
;; reserves the name, raising on a duplicate
(define (reserve-name! r name)
  (box-update! (registry-names r)
               (λ (names)
                 (when (member name names) (error 'registry "duplicate metric ~a" name))
                 (cons name names))))

;; Registry Name String [Listof String] -> Counter
(define (make-counter r name help #:labels [labels '()])
  (reserve-name! r name)
  (define c (counter name labels (box (if (null? labels) (hash '() 0) (hash)))))  ; an unlabeled counter exists from the start
  (add-collector! r (λ () (list (counter->family c help))))
  c)

;; Registry Name String [Listof Real] [Listof String] -> Histogram
(define (make-histogram r name help bounds #:labels [labels '()])
  (reserve-name! r name)
  (unless (equal? bounds (sort (remove-duplicates bounds) <)) (error 'registry "buckets must be ascending: ~a" name))
  (define h (histogram name labels bounds (box (hash))))
  (add-collector! r (λ () (list (histogram->family h help))))
  h)

;; [Listof String] [Listof String] String -> Void
;; raises unless there is one label value per label name
(define (check-arity! names values what)
  (unless (= (length names) (length values))
    (error 'registry "~a takes ~a label values, got ~a" what (length names) (length values))))

;; Counter [Listof String] [Real >= 0] -> Void
(define (inc! c values [n 1])
  (check-arity! (counter-labels c) values (counter-name c))
  (box-update! (counter-cells c) (λ (cells) (hash-update cells values (λ (v) (+ v n)) 0))))

;; Histogram [Listof String] Real -> Void
(define (observe! h values x)
  (check-arity! (histogram-labels h) values (histogram-name h))
  (define bounds (histogram-bounds h))
  (define slot (or (index-where bounds (λ (b) (<= x b))) (length bounds)))
  (define empty (cell (make-vector (add1 (length bounds)) 0) 0))
  (box-update! (histogram-cells h) (λ (cells) (hash-update cells values (λ (c) (cell-add c slot x)) empty))))

;; Cell Natural Real -> Cell
;; a copy of the cell with one more observation x in bucket slot
(define (cell-add c slot x)
  (define counts (vector-copy (cell-counts c)))
  (vector-set! counts slot (add1 (vector-ref counts slot)))
  (cell counts (+ (cell-sum c) x)))

;; [Listof String] [Listof String] -> [Listof (Pair String String)]
(define (label-pairs names values) (map cons names values))

;; Counter String -> Family
;; a snapshot of the counter
(define (counter->family c help)
  (define cells (unbox (counter-cells c)))
  (family (counter-name c) help 'counter
          (for/list ([(vs n) (in-hash cells)]) (sample "" (label-pairs (counter-labels c) vs) n))))

;; Histogram String -> Family
;; a snapshot of the histogram, with cumulative buckets
(define (histogram->family h help)
  (define cells
    (for/list ([(vs c) (in-hash (unbox (histogram-cells h)))]) (list vs (vector->list (cell-counts c)) (cell-sum c))))
  (family (histogram-name h) help 'histogram
          (append*
           (for/list ([c (in-list cells)])
             (cell->samples c (histogram-labels h) (histogram-bounds h))))))

;; (List [Listof String] [Listof Natural] Real) [Listof String] [Listof Real] -> [Listof Sample]
;; the _bucket, _sum and _count samples of one label-value tuple
(define (cell->samples c names bounds)
  (define-values (vs counts sum) (apply values c))
  (define base (label-pairs names vs))
  (define cumulative (let loop ([cs counts] [acc 0]) (if (null? cs) '() (let ([n (+ acc (car cs))]) (cons n (loop (cdr cs) n))))))
  (append (for/list ([le (in-sequences bounds '(+inf.0))] [n (in-list cumulative)])
            (sample "_bucket" (append base (list (cons "le" (format-value le)))) n))
          (list (sample "_sum" base sum) (sample "_count" base (last cumulative)))))

;; ------------------------------------------------------------------ rendering
;; Real -> String
;; the sample value in exposition syntax; an exact fraction such as 354281/1000 is not one
(define (format-value v)
  (cond [(eqv? v +inf.0) "+Inf"]
        [(eqv? v -inf.0) "-Inf"]
        [(and (flonum? v) (nan? v)) "NaN"]
        [(and (rational? v) (integer? v)) (number->string (inexact->exact v))]
        [else (number->string (exact->inexact v))]))

;; String [Listof String] -> String
;; backslash-escapes the given characters (and newlines)
(define (escape s specials)
  (apply string-append
         (for/list ([c (in-string s)])
           (cond [(char=? c #\\) "\\\\"] [(char=? c #\newline) "\\n"] [(member c specials) (string #\\ c)] [else (string c)]))))

;; [Listof (Pair String String)] -> String
(define (format-labels ls)
  (if (null? ls)
      ""
      (string-append "{" (string-join (for/list ([l ls]) (format "~a=\"~a\"" (car l) (escape (cdr l) '(#\")))) ",") "}")))

;; Family -> String
(define (render-family f)
  (string-append
   (format "# HELP ~a ~a\n# TYPE ~a ~a\n" (family-name f) (escape (family-help f) '()) (family-name f) (family-type f))
   (apply string-append
          (for/list ([s (family-samples f)])
            (format "~a~a~a ~a\n" (family-name f) (sample-suffix s) (format-labels (sample-labels s)) (format-value (sample-value s)))))))

;; [Listof Family] -> String
(define (render-families fs) (apply string-append (map render-family fs)))

;; Registry -> String
;; the exposition text of every collector, oldest registration first
(define (render r)
  (define collectors (reverse (unbox (registry-collectors r))))
  (render-families (append-map (λ (collect) (collect)) collectors)))

(module+ test
  (require rackunit)

  (test-case "unlabeled counter renders from zero"
    (define r (make-registry))
    (define c (make-counter r "x_total" "things"))
    (check-equal? (render r) "# HELP x_total things\n# TYPE x_total counter\nx_total 0\n")
    (inc! c '()) (inc! c '() 2)
    (check-regexp-match #rx"\nx_total 3\n" (render r)))

  (test-case "labels are escaped, HELP keeps quotes"
    (define r (make-registry))
    (define c (make-counter r "y_total" "a \"q\" \\ b\nc" #:labels '("l")))
    (inc! c (list "a\"b\\c\nd"))
    (check-equal? (render r)
                  (string-append "# HELP y_total a \"q\" \\\\ b\\nc\n# TYPE y_total counter\n"
                                 "y_total{l=\"a\\\"b\\\\c\\nd\"} 1\n")))

  (test-case "histogram: cumulative buckets, +Inf, sum and count"
    (define r (make-registry))
    (define h (make-histogram r "d_seconds" "dur" '(0.1 1 10) #:labels '("k")))
    (for ([x '(0.05 0.5 0.5 20)]) (observe! h '("a") x))
    (check-equal? (render r)
                  (string-append "# HELP d_seconds dur\n# TYPE d_seconds histogram\n"
                                 "d_seconds_bucket{k=\"a\",le=\"0.1\"} 1\n" "d_seconds_bucket{k=\"a\",le=\"1\"} 3\n"
                                 "d_seconds_bucket{k=\"a\",le=\"10\"} 3\n" "d_seconds_bucket{k=\"a\",le=\"+Inf\"} 4\n"
                                 "d_seconds_sum{k=\"a\"} 21.05\n" "d_seconds_count{k=\"a\"} 4\n")))

  (test-case "label arity is checked, duplicate names and unsorted buckets raise"
    (define r (make-registry))
    (define c (make-counter r "z_total" "z" #:labels '("a" "b")))
    (check-exn #rx"2 label values" (λ () (inc! c '("x"))))
    (check-exn #rx"duplicate" (λ () (make-counter r "z_total" "z")))
    (check-exn #rx"ascending" (λ () (make-histogram r "h" "h" '(1 0.5)))))

  (test-case "updates survive threads killed mid-update"
    (define r (make-registry))
    (define c (make-counter r "k_total" "k"))
    (define h (make-histogram r "k_seconds" "k" '(1)))
    (for ([_ 200])
      (define t (thread (λ () (let loop () (inc! c '()) (observe! h '() 0.5) (loop)))))
      (sleep 0.001)
      (kill-thread t))
    (define done (thread (λ () (inc! c '()) (observe! h '() 0.5))))
    (check-not-false (sync/timeout 5 done))
    (check-not-false (render r)))

  (test-case "exact fractions render as decimals"
    (check-equal? (format-value 354281/1000) "354.281")
    (check-equal? (format-value 3) "3")
    (check-equal? (format-value 2.0) "2"))
  (test-case "collectors render gauges and special values"
    (define r (make-registry))
    (add-collector! r (λ () (list (family "g" "gauge" 'gauge (list (sample "" '() +inf.0) (sample "" '(("a" . "b")) 2.0))))))
    (check-equal? (render r) "# HELP g gauge\n# TYPE g gauge\ng +Inf\ng{a=\"b\"} 2\n")))
