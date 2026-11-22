#lang racket/base
;; Request-field validators, the vocabulary of define-endpoint's #:json and #:form clauses.
;; Failures raise 422 `invalid` naming the offending field.
;; JSON validators take (body-hash key . args); form validators take (bindings key . args).
(require racket/contract/base racket/list racket/match web-server/http "../domain.rkt" "../qa.rkt" "json.rkt")
(provide (contract-out
          [invalid! (-> symbol? string? none/c)]
          [bigint? (-> any/c boolean?)]
          [body-string (-> hash? symbol? natural-number/c natural-number/c string?)]
          [body-optional-string (-> hash? symbol? natural-number/c natural-number/c string? string?)]
          [body-int (-> hash? symbol? exact-integer?)]
          [body-id (-> hash? symbol? id/c)]
          [body-bool (-> hash? symbol? boolean?)]
          [body-one-of (->* (hash? symbol?) #:rest (listof string?) string?)]
          [body-overlay-request (-> hash? symbol? (or/c #f qr-overlay? qa-overlay? id/c))]
          [body-bool-or-default (-> hash? symbol? boolean? boolean?)]
          [body-slide (-> hash? symbol? natural-number/c natural-number/c)]
          [body-slide-or-null (-> hash? symbol? natural-number/c (or/c natural-number/c #f))]
          [body-strings (-> hash? symbol? natural-number/c natural-number/c natural-number/c natural-number/c
                            (listof string?))]
          [body-distinct-ints (-> hash? symbol? (listof id/c))]
          [body-question-text (-> hash? symbol? question-text?)]
          [form-text (-> (listof binding?) symbol? natural-number/c natural-number/c string?)]
          [form-count (-> (listof binding?) symbol? natural-number/c natural-number/c natural-number/c)]
          [form-file (-> (listof binding?) symbol? input-port?)]))

;; Symbol String -> Nothing
(define (invalid! field message) (api-error! 422 "invalid" message (symbol->string field)))

;; Any -> Boolean
;; an integer that fits a Postgres bigint
(define (bigint? v) (and (exact-integer? v) (<= (abs v) 9223372036854775807)))

;; Any Natural Natural -> Boolean
(define (string-between? v lo hi) (and (string? v) (<= lo (string-length v) hi)))

;; ------------------------------------------------------------------ JSON body fields
;; JSObject Symbol Natural Natural -> String
(define (body-string h key lo hi)
  (define v (hash-ref h key #f))
  (unless (string-between? v lo hi) (invalid! key (format "~a must be a string of ~a to ~a characters" key lo hi)))
  v)

;; JSObject Symbol -> QuestionText
;; parses a question into normalized, bounded domain text
(define (body-question-text h key) (make-question-text (hash-ref h key #f)))

;; JSObject Symbol Natural Natural String -> String
;; like body-string, but an absent key gives the default
(define (body-optional-string h key lo hi default)
  (if (hash-has-key? h key) (body-string h key lo hi) default))

;; JSObject Symbol -> Integer
(define (body-int h key)
  (define v (hash-ref h key #f))
  (unless (bigint? v) (invalid! key (format "~a must be an integer" key)))
  v)

;; JSObject Symbol -> Id
;; a non-negative integer that fits a bigint (a negative id never names a row)
(define (body-id h key)
  (define v (hash-ref h key #f))
  (unless (and (bigint? v) (>= v 0)) (invalid! key (format "~a must be a non-negative integer" key)))
  v)

;; JSObject Symbol -> Boolean
(define (body-bool h key)
  (define v (hash-ref h key 'missing))
  (unless (boolean? v) (invalid! key (format "~a must be a boolean" key)))
  v)

;; JSObject Symbol String ... -> String
(define (body-one-of h key . choices)
  (define v (hash-ref h key #f))
  (unless (member v choices) (invalid! key (format "~a must be ~a" key (string-join* choices))))
  v)

;; JSObject Symbol -> (or #f QrOverlay Id)
;; the overlay a request asks for: null = none, {"type":"qr"} = the QR, {"type":"poll","run_id":N} = the
;; poll overlay of run N (returned as its id)
(define (body-overlay-request h key)
  (match (hash-ref h key 'missing)
    ['null #f]
    [(? hash? o)
     (match (hash-ref o 'type #f)
       ["qr" (qr-overlay)]
       ["poll" (body-id o 'run_id)]
       ["qa" (qa-overlay (if (eq? (hash-ref o 'question_id 'null) 'null) #f (body-id o 'question_id)))]
       [_ (invalid! key "overlay type must be poll, qr or qa")])]
    [_ (invalid! key "overlay must be null or an object")]))

;; JSObject Symbol Boolean -> Boolean
;; like body-bool, but an absent key gives the default
(define (body-bool-or-default h key default)
  (if (hash-has-key? h key) (body-bool h key) default))

;; [Listof String] -> String
;; "a or b", "a, b or c"
(define (string-join* xs)
  (match xs
    [(list a) a]
    [(list a ... b) (string-append (apply string-append (add-between a ", ")) " or " b)]))

;; JSObject Symbol Natural -> Natural
;; a slide number within 1..page-count; null or absent is rejected
(define (body-slide h key page-count)
  (match (body-slide-or-null h key page-count)
    [#f (invalid! key (format "~a must be an integer" key))]
    [n n]))

;; JSObject Symbol Natural -> (or Natural #f)
;; a slide number within 1..page-count; null or absent is #f
(define (body-slide-or-null h key page-count)
  (match (hash-ref h key 'null)
    ['null #f]
    [(? exact-integer? n) #:when (<= 1 n page-count) n]
    [_ (invalid! key (format "~a must be null or between 1 and ~a" key page-count))]))

;; JSObject Symbol Natural Natural Natural Natural -> [Listof String]
;; between lo and hi strings, each of item-lo to item-hi characters
(define (body-strings h key lo hi item-lo item-hi)
  (define v (hash-ref h key #f))
  (unless (and (list? v) (<= lo (length v) hi)) (invalid! key (format "~a must have ~a to ~a items" key lo hi)))
  (unless (andmap (λ (s) (string-between? s item-lo item-hi)) v)
    (invalid! key (format "each ~a item must be ~a to ~a characters" key item-lo item-hi)))
  v)

;; JSObject Symbol -> [Listof Id]
;; a non-empty list of distinct non-negative integers
(define (body-distinct-ints h key)
  (define v (hash-ref h key #f))
  (unless (and (pair? v) (andmap (λ (x) (and (bigint? x) (>= x 0))) v))
    (invalid! key (format "~a must be a non-empty list of non-negative integers" key)))
  (unless (= (length v) (length (remove-duplicates v))) (invalid! key (format "~a must not repeat" key)))
  v)

;; ------------------------------------------------------------------ multipart form fields
;; Bindings Symbol -> (or String #f)
(define (form-string bindings key)
  (define b (bindings-assq (string->bytes/utf-8 (symbol->string key)) bindings))
  (and b (binding:form? b) (bytes->string/utf-8 (binding:form-value b) #\?)))

;; Bindings Symbol Natural Natural -> String
(define (form-text bindings key lo hi)
  (define v (form-string bindings key))
  (unless (string-between? v lo hi) (invalid! key (format "~a must be ~a to ~a characters" key lo hi)))
  v)

;; Bindings Symbol Natural Natural -> Natural
(define (form-count bindings key lo hi)
  (define n (let ([s (form-string bindings key)]) (and s (string->number s))))
  (unless (and (exact-integer? n) (<= lo n hi)) (invalid! key (format "~a must be an integer from ~a to ~a" key lo hi)))
  n)

;; Bindings Symbol -> InputPort
;; the uploaded file's content
(define (form-file bindings key)
  (define b (bindings-assq (string->bytes/utf-8 (symbol->string key)) bindings))
  (cond [(not (and b (binding:file? b))) (invalid! key (format "~a file is required" key))]
        [(binding:file/port? b) (binding:file/port-in b)]
        [else (open-input-bytes (binding:file-content b))]))

(module+ test
  (require rackunit)
  (define (field-of thunk) (with-handlers ([exn:api? exn:api-field]) (thunk) #f))
  (define (bad? thunk key) (check-equal? (field-of thunk) key))

  (test-case "strings"
    (check-equal? (body-string (hasheq 'q "Q") 'q 1 5) "Q")
    (bad? (λ () (body-string (hasheq 'q "") 'q 1 5)) "q")
    (bad? (λ () (body-string (hasheq 'q "toolong") 'q 1 5)) "q")
    (bad? (λ () (body-string (hasheq) 'q 1 5)) "q")
    (check-equal? (body-optional-string (hasheq) 'l 0 100 "") "")
    (check-equal? (body-optional-string (hasheq 'l "") 'l 0 100 "") "")
    (bad? (λ () (body-optional-string (hasheq 'l 3) 'l 0 100 "")) "l"))
  (test-case "scalars"
    (bad? (λ () (body-bool (hasheq) 'visible)) "visible")
    (bad? (λ () (body-int (hasheq 'n "1") 'n)) "n")
    (bad? (λ () (body-int (hasheq 'n (expt 10 30)) 'n)) "n"))
  (test-case "ids reject negatives and non-integers"
    (check-equal? (body-id (hasheq 'n 0) 'n) 0)
    (bad? (λ () (body-id (hasheq 'n -1) 'n)) "n")
    (bad? (λ () (body-id (hasheq 'n "1") 'n)) "n")
    (bad? (λ () (body-id (hasheq 'n (expt 10 30)) 'n)) "n")
    (bad? (λ () (body-distinct-ints (hasheq 'n '(1 -2)) 'n)) "n"))
  (test-case "one-of"
    (check-equal? (body-one-of (hasheq 'k "multi") 'k "single" "multi") "multi")
    (bad? (λ () (body-one-of (hasheq 'k "x") 'k "single" "multi")) "k"))
  (test-case "overlay request and bool-or-default"
    (check-false (body-overlay-request (hasheq 'o 'null) 'o))
    (check-equal? (body-overlay-request (hasheq 'o (hasheq 'type "qr")) 'o) (qr-overlay))
    (check-equal? (body-overlay-request (hasheq 'o (hasheq 'type "poll" 'run_id 4)) 'o) 4)
    (bad? (λ () (body-overlay-request (hasheq) 'o)) "o")
    (bad? (λ () (body-overlay-request (hasheq 'o "qr") 'o)) "o")
    (bad? (λ () (body-overlay-request (hasheq 'o (hasheq 'type "x")) 'o)) "o")
    (bad? (λ () (body-overlay-request (hasheq 'o (hasheq 'type "poll")) 'o)) "run_id")
    (bad? (λ () (body-overlay-request (hasheq 'o (hasheq 'type "poll" 'run_id -1)) 'o)) "run_id")
    (check-false (body-bool-or-default (hasheq) 's #f))
    (check-true (body-bool-or-default (hasheq 's #t) 's #f))
    (bad? (λ () (body-bool-or-default (hasheq 's "y") 's #f)) "s"))
  (test-case "slides"
    (check-equal? (body-slide-or-null (hasheq 'slide 3) 'slide 10) 3)
    (check-false (body-slide-or-null (hasheq 'slide 'null) 'slide 10))
    (check-false (body-slide-or-null (hasheq) 'slide 10))
    (bad? (λ () (body-slide-or-null (hasheq 'slide 11) 'slide 10)) "slide")
    (bad? (λ () (body-slide-or-null (hasheq 'slide 0) 'slide 10)) "slide")
    (check-equal? (body-slide (hasheq 'slide 10) 'slide 10) 10)
    (bad? (λ () (body-slide (hasheq 'slide 'null) 'slide 10)) "slide")
    (bad? (λ () (body-slide (hasheq) 'slide 10)) "slide"))
  (test-case "string lists"
    (check-equal? (body-strings (hasheq 'o '("a" "b")) 'o 2 30 1 200) '("a" "b"))
    (check-equal? (length (body-strings (hasheq 'o (for/list ([i 30]) "a")) 'o 2 30 1 200)) 30)
    (bad? (λ () (body-strings (hasheq 'o '("a")) 'o 2 30 1 200)) "o")
    (bad? (λ () (body-strings (hasheq 'o (for/list ([i 31]) "a")) 'o 2 30 1 200)) "o")
    (bad? (λ () (body-strings (hasheq 'o '("a" "")) 'o 2 30 1 200)) "o")
    (bad? (λ () (body-strings (hasheq 'o (list "a" (make-string 201 #\a))) 'o 2 30 1 200)) "o"))
  (test-case "distinct ints"
    (check-equal? (body-distinct-ints (hasheq 'ids '(1 2)) 'ids) '(1 2))
    (bad? (λ () (body-distinct-ints (hasheq 'ids '()) 'ids)) "ids")
    (bad? (λ () (body-distinct-ints (hasheq 'ids '(1 1)) 'ids)) "ids")
    (bad? (λ () (body-distinct-ints (hasheq 'ids '(1 "2")) 'ids)) "ids")))
