#lang racket/base
;; define-query: one SQL statement as a function of a connection and named arguments.
;;
;;   (define-query (get-poll c id) #:maybe-row row->poll "SELECT ... WHERE id=$1")
;;   (define-query (next-position c pid [slide #:nullable]) #:value "SELECT ... $2::int")
;;
;; The result keyword picks the db function and an optional row converter:
;;   #:exec  #:count (affected rows)  #:value  #:maybe-value  #:list
;;   #:row conv  #:maybe-row conv  #:rows conv      (conv : vector -> X)
;; A [x #:nullable] argument is sent as SQL NULL when #f. SQL strings are appended as written.
(require (for-syntax racket/base syntax/parse) db)
(provide define-query)

;; (Vector -> X) -> (Connection String Any ... -> X)
;; runs a query expected to return exactly one row and converts it
(define ((row-runner conv) c sql . args) (conv (apply query-row c sql args)))

;; (Vector -> X) -> (Connection String Any ... -> (or/c X #f))
;; runs a query returning zero or one row; #f when there is none
(define ((maybe-row-runner conv) c sql . args)
  (define r (apply query-maybe-row c sql args))
  (and r (conv r)))
;; (Vector -> X) -> (Connection String Any ... -> [Listof X])
;; runs a query and converts every returned row
(define ((rows-runner conv) c sql . args) (map conv (apply query-rows c sql args)))

;; Connection String Any ... -> Natural
(define (count-runner c sql . args)
  (define r (apply query c sql args))
  (define m (and (simple-result? r) (assq 'affected-rows (simple-result-info r))))
  (if m (cdr m) 0))

;; (or A #f) -> (or A sql-null)
(define (nullable v) (or v sql-null))

(begin-for-syntax
  (define-syntax-class param
    #:description "argument (id or [id #:nullable])"
    #:attributes (name arg)
    (pattern name:id #:with arg #'name)
    (pattern [name:id #:nullable] #:with arg #'(nullable name)))

  (define-splicing-syntax-class result
    #:description "result kind (#:exec, #:count, #:value, #:maybe-value, #:list, #:row, #:maybe-row or #:rows)"
    #:attributes (runner)
    (pattern (~seq #:exec) #:with runner #'query-exec)
    (pattern (~seq #:count) #:with runner #'count-runner)
    (pattern (~seq #:value) #:with runner #'query-value)
    (pattern (~seq #:maybe-value) #:with runner #'query-maybe-value)
    (pattern (~seq #:list) #:with runner #'query-list)
    (pattern (~seq #:row conv:expr) #:with runner #'(row-runner conv))
    (pattern (~seq #:maybe-row conv:expr) #:with runner #'(maybe-row-runner conv))
    (pattern (~seq #:rows conv:expr) #:with runner #'(rows-runner conv))))

(define-syntax (define-query stx)
  (syntax-parse stx
    [(_ (name:id c:id p:param ...) r:result sql:expr ...+)
     #:fail-when (check-duplicate-identifier (syntax->list #'(c p.name ...))) "duplicate parameter name"
     #'(define (name c p.name ...) (r.runner c (string-append sql ...) p.arg ...))]))

(module+ test
  (require rackunit syntax/macro-testing)
  (define-syntax-rule (compile-error expr) (convert-compile-time-error expr))
  (test-case "malformed queries are compile-time errors"
    (check-exn #rx"result kind" (λ () (compile-error (let () (define-query (f c) #:bogus "SELECT 1") 1))))
    (check-exn #rx"duplicate parameter" (λ () (compile-error (let () (define-query (f c c) #:exec "SELECT 1") 1))))
    (check-exn #rx"expected more terms|expected" (λ () (compile-error (let () (define-query (f c) #:exec) 1)))))
  (test-case "arguments and the nullable marker"
    (define-query (f c a [b #:nullable]) #:exec "SELECT 1")
    (check-equal? (nullable #f) sql-null)
    (check-equal? (nullable 3) 3)
    (check-equal? (procedure-arity f) 3)))
