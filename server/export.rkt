#lang racket/base
;; CSV rendering (RFC 4180).
(require racket/contract/base racket/string racket/list db/base)
(provide (contract-out
          [csv-field (-> any/c string?)]
          [csv-line (-> list? string?)]
          [render-csv (-> list? (listof list?) string?)]))

;; Any -> String
;; a cell as text: SQL NULL and #f are empty
(define (cell->string v)
  (cond [(or (sql-null? v) (not v) (eq? v 'null)) ""]
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
  (check-equal? (csv-field sql-null) "")
  (check-equal? (csv-field 42) "42")
  (check-equal? (render-csv '("a" "b") '((1 "x,y") (2 #f))) "a,b\r\n1,\"x,y\"\r\n2,\r\n"))
