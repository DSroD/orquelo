#lang racket/base
;; Pure derivations over session results: participation and the aggregated results CSV.
(require racket/contract/base racket/list "domain.rkt")
(provide (contract-out
          [run-participation (-> run-result? (or/c real? #f))]
          [average-participation (-> (listof run-result?) (or/c real? #f))]
          [results-csv-header (listof string?)]
          [results-csv-rows (-> session-results? (listof list?))]))

;; RunResult -> (or Rational #f)
;; the exact share of the audience that voted, capped at 1; #f when the peak audience is unknown or zero
(define (exact-participation r)
  (define peak (run-result-peak-audience r))
  (and peak (> peak 0) (min 1 (/ (run-result-total-voters r) peak))))

;; RunResult -> (or Real #f)
;; the participation as a float, so 27 of 30 is exactly 0.9
(define (run-participation r)
  (define p (exact-participation r))
  (and p (exact->inexact p)))

;; [Listof RunResult] -> (or Real #f)
;; the mean participation over the runs that have one; #f when none does
(define (average-participation runs)
  (define ps (filter values (map exact-participation runs)))
  (and (pair? ps) (exact->inexact (/ (apply + ps) (length ps)))))

(define results-csv-header
  '("session_code" "session_label" "presentation_title" "run_id" "opened_at" "closed_at" "poll_id" "slide"
    "question" "kind" "option_idx" "option_label" "count" "percent" "total_voters" "peak_audience"
    "participation" "median_seconds_to_vote"))

;; Natural Natural -> (or String #f)
;; the count as a percentage of the voters with one decimal; #f without voters
(define (percent count total)
  (and (> total 0) (real->decimal-string (* 100 (/ count total)) 1)))

;; Real -> String
(define (fraction->string p) (real->decimal-string p 3))

;; SessionResults -> [Listof [Listof Any]]
;; one row per run and option, zero counts included, runs oldest first
(define (results-csv-rows sr)
  (define s (session-results-session sr))
  (define title (presentation-title (session-results-presentation sr)))
  (for*/list ([r (session-results-runs sr)] [o (run-result-options r)])
    (define p (run-participation r))
    (list (session-code s) (session-label s) title (run-result-run-id r) (run-result-opened-at r)
          (run-result-closed-at r) (run-result-poll-id r) (run-result-slide r) (run-result-question r)
          (run-result-kind r) (option-count-idx o) (option-count-label o) (option-count-count o)
          (percent (option-count-count o) (run-result-total-voters r)) (run-result-total-voters r)
          (run-result-peak-audience r) (and p (fraction->string p)) (run-result-median-seconds r))))

(module+ test
  (require rackunit)
  (define (a-run #:voters [voters 27] #:peak [peak 30] #:options [options '()])
    (run-result 12 3 5 "Q?" "multi" "t0" "t1" voters peak 14.5 3 options))
  (define opts (list (option-count 101 0 "sq" 21) (option-count 102 1 "rnd" 0)))
  (define sess (session 4 7 "abcde23456" "vwxyz76543" "Class A" 1 "t" #f))
  (define pres (presentation 7 "Deck" 3 "t" #f))
  (define (results runs) (session-results sess pres (results-totals 0 #f #f #f #f) runs))

  (test-case "participation is voters over peak"
    (check-equal? (run-participation (a-run)) 0.9))
  (test-case "participation is capped at 1"
    (check-equal? (run-participation (a-run #:voters 35)) 1.0))
  (test-case "participation is unknown without a peak"
    (check-false (run-participation (a-run #:peak #f)))
    (check-false (run-participation (a-run #:peak 0))))
  (test-case "average participation skips runs without a peak"
    (check-equal? (average-participation (list (a-run) (a-run #:voters 24))) 0.85)
    (check-equal? (average-participation (list (a-run) (a-run #:peak #f))) 0.9)
    (check-false (average-participation (list (a-run #:peak #f))))
    (check-false (average-participation '())))
  (test-case "csv rows: one per option including zero counts"
    (define rows (results-csv-rows (results (list (a-run #:options opts)))))
    (check-equal? (length rows) 2)
    (check-equal? (length (car rows)) (length results-csv-header))
    (check-equal? (list-tail (car rows) 10)
                  '(0 "sq" 21 "77.8" 27 30 "0.900" 14.5))
    (check-equal? (list-ref (cadr rows) 12) 0)
    (check-equal? (list-ref (cadr rows) 13) "0.0"))
  (test-case "csv rows: unknown peak and no voters give empty cells"
    (define row (car (results-csv-rows (results (list (a-run #:voters 0 #:peak #f #:options opts))))))
    (check-false (list-ref row 13))
    (check-false (list-ref row 15))
    (check-false (list-ref row 16)))
  (test-case "csv rows: no runs, no rows"
    (check-equal? (results-csv-rows (results '())) '())))
