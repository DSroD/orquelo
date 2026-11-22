#lang racket/base
;; CSV rendering (RFC 4180).
(require racket/contract/base racket/string racket/match "domain.rkt")
(provide (contract-out
          [votes->csv (-> (listof exported-vote?) string?)]
          [csv-field (-> any/c string?)]
          [csv-line (-> list? string?)]
          [render-csv (-> list? (listof list?) string?)]))

(define export-header
  '("session_code" "session_label" "presentation_title" "run_id" "run_opened_at" "poll_id" "slide" "question"
    "kind" "option_idx" "option_label" "participant_id" "voted_at"))

;; [Listof ExportedVote] -> String
;; renders one selected answer per line in the public CSV column order
(define (votes->csv votes)
  (render-csv export-header
              (for/list ([v (in-list votes)])
                (match-define (exported-vote code label title rid opened pid slide question kind idx answer participant voted) v)
                (list code label title rid opened pid slide question kind idx answer participant voted))))

;; Any -> String
;; a cell as text: absent values are empty
(define (cell->string v)
  (cond [(or (not v) (eq? v 'null)) ""]
        [(string? v) v]
        [else (format "~a" v)]))

;; Any -> String
;; the cell, quoted when it holds a comma, quote or newline
(define (csv-field v)
  (define s (cell->string v))
  (if (regexp-match? #rx"[\",\r\n]" s)
      (string-append "\"" (string-replace s "\"" "\"\"") "\"")
      s))

;; [Listof Any] -> String
(define (csv-line row) (string-append (string-join (map csv-field row) ",") "\r\n"))

;; [Listof String] [Listof [Listof Any]] -> String
;; header and rows as CRLF-terminated CSV lines
(define (render-csv header rows) (apply string-append (csv-line header) (map csv-line rows)))

(module+ test
  (require rackunit)
  (check-equal? (csv-field "plain") "plain")
  (check-equal? (csv-field "a,b") "\"a,b\"")
  (check-equal? (csv-field "say \"hi\"") "\"say \"\"hi\"\"\"")
  (check-equal? (csv-field "two\nlines") "\"two\nlines\"")
  (check-equal? (csv-field #f) "")
  (check-equal? (csv-field 42) "42")
  (check-equal? (render-csv '("a" "b") '((1 "x,y") (2 #f))) "a,b\r\n1,\"x,y\"\r\n2,\r\n"))
