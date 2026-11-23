#lang racket/base
;; Tool input types: each pairs a JSON Schema fragment with the parser that enforces it, so the
;; schema a client reads and the checks the server runs cannot drift apart.
(require racket/contract/base racket/list racket/string json)
(provide (struct-out exn:mcp:invalid-argument)
         (contract-out
          [struct field-type ([schema jsexpr?] [parse (-> any/c (or/c string? #f) any/c)] [required? boolean?])]
          [string-type (-> exact-nonnegative-integer? exact-nonnegative-integer? field-type?)]
          [optional-string-type (-> exact-nonnegative-integer? exact-nonnegative-integer? string? field-type?)]
          [integer-type (-> exact-integer? exact-integer? field-type?)]
          [boolean-type (-> field-type?)]
          [optional-boolean-type (-> boolean? field-type?)]
          [one-of-type (->* () #:rest (non-empty-listof string?) field-type?)]
          [array-type (-> field-type? exact-nonnegative-integer? exact-nonnegative-integer? field-type?)]
          [nullable-type (-> field-type? field-type?)]
          [object-type (-> procedure? (listof (list/c symbol? field-type?)) field-type?)]
          [parse-arguments (-> field-type? jsexpr? any/c)]))

;; A FieldType is a (field-type JSExpr (Any (or String #f) -> X) Boolean)
;;   a JSON Schema fragment; a parser from a JSON value (or `absent`) and the path of the value
;;   (#f at the root, "options[1].label" below it) to its Racket value; whether a value is required.
;; An exn:mcp:invalid-argument is an exn:fail whose `field` is the path of the offending value.
(struct field-type (schema parse required?))
(struct exn:mcp:invalid-argument exn:fail (field))

;; the value handed to a parser when the key is missing
(define absent (string->uninterned-symbol "absent"))

;; (or String #f) String -> Nothing
(define (invalid! path message)
  (raise (exn:mcp:invalid-argument message (current-continuation-marks) (or path ""))))

;; (or String #f) String -> String
(define (path-key path key) (if path (string-append path "." key) key))
;; (or String #f) Natural -> String
(define (path-index path i) (format "~a[~a]" (or path "") i))

;; Symbol -> Symbol
;; the wire key of a field: run-id is "run_id"
(define (wire-key sym) (string->symbol (string-replace (symbol->string sym) "-" "_")))

;; Natural Natural -> String
(define (range-text lo hi) (if (= lo hi) (format "~a" lo) (format "~a to ~a" lo hi)))

;; (Any -> Boolean) String (Any -> X) -> (Any (or String #f) -> X)
;; a required parser: a missing value is an error, a wrong one too, else convert
(define (required-parser ok? expected convert)
  (λ (v path)
    (cond [(eq? v absent) (invalid! path "is required")]
          [(ok? v) (convert v)]
          [else (invalid! path (string-append "must be " expected))])))

;; (Any (or String #f) -> X) X -> (Any (or String #f) -> X)
(define (defaulting parse default)
  (λ (v path) (if (eq? v absent) default (parse v path))))

;; Natural Natural -> FieldType
(define (string-type lo hi)
  (field-type (hasheq 'type "string" 'minLength lo 'maxLength hi)
              (required-parser (λ (v) (and (string? v) (<= lo (string-length v) hi)))
                               (format "a string of ~a characters" (range-text lo hi))
                               values)
              #t))

;; Natural Natural String -> FieldType
(define (optional-string-type lo hi default)
  (define t (string-type lo hi))
  (field-type (hash-set (field-type-schema t) 'default default)
              (defaulting (field-type-parse t) default)
              #f))

;; Integer Integer -> FieldType
(define (integer-type lo hi)
  (field-type (hasheq 'type "integer" 'minimum lo 'maximum hi)
              (required-parser (λ (v) (and (exact-integer? v) (<= lo v hi)))
                               (format "an integer from ~a to ~a" lo hi)
                               values)
              #t))

;; -> FieldType
(define (boolean-type)
  (field-type (hasheq 'type "boolean") (required-parser boolean? "a boolean" values) #t))

;; Boolean -> FieldType
(define (optional-boolean-type default)
  (field-type (hasheq 'type "boolean" 'default default)
              (defaulting (field-type-parse (boolean-type)) default)
              #f))

;; String ... -> FieldType
(define (one-of-type . choices)
  (field-type (hasheq 'type "string" 'enum choices)
              (required-parser (λ (v) (member v choices))
                               (format "one of ~a" (string-join (map (λ (c) (format "~s" c)) choices) ", "))
                               values)
              #t))

;; FieldType Natural Natural -> FieldType
(define (array-type item lo hi)
  (define parse-item (field-type-parse item))
  (define parse-list
    (required-parser (λ (v) (and (list? v) (<= lo (length v) hi)))
                     (format "an array of ~a items" (range-text lo hi))
                     values))
  (field-type (hasheq 'type "array" 'items (field-type-schema item) 'minItems lo 'maxItems hi)
              (λ (v path)
                (for/list ([x (in-list (parse-list v path))] [i (in-naturals)])
                  (parse-item x (path-index path i))))
              #t))

;; FieldType -> FieldType
;; accepts JSON null (as #f) besides the wrapped type
(define (nullable-type t)
  (field-type (hasheq 'anyOf (list (field-type-schema t) (hasheq 'type "null")))
              (λ (v path)
                (cond [(eq? v absent) (invalid! path "is required")]
                      [(eq? v 'null) #f]
                      [else ((field-type-parse t) v path)]))
              #t))

;; (X ... -> Y) (listof (list Symbol FieldType)) -> FieldType
;; a JSON object with exactly the named fields, converted by ctor in field order
(define (object-type ctor fields)
  (define keys (map (λ (f) (wire-key (first f))) fields))
  (define required (for/list ([f (in-list fields)] [k (in-list keys)] #:when (field-type-required? (second f)))
                     (symbol->string k)))
  (define properties (for/hasheq ([f (in-list fields)] [k (in-list keys)]) (values k (field-type-schema (second f)))))
  (define base (hasheq 'type "object" 'additionalProperties #f))
  (define schema
    (cond [(null? fields) base]
          [(null? required) (hash-set base 'properties properties)]
          [else (hash-set* base 'properties properties 'required required)]))
  (define (parse v path)
    (cond [(eq? v absent) (invalid! path "is required")]
          [(not (hash? v)) (invalid! path "must be an object")]
          [else
           (for ([k (in-hash-keys v)] #:unless (memq k keys))
             (invalid! (path-key path (symbol->string k)) "is not a known field"))
           (apply ctor (for/list ([f (in-list fields)] [k (in-list keys)])
                         ((field-type-parse (second f)) (hash-ref v k absent) (path-key path (symbol->string k)))))]))
  (field-type schema parse #t))

;; FieldType JSExpr -> X
;; parses the `arguments` of a tool call; raises exn:mcp:invalid-argument
(define (parse-arguments t args)
  ((field-type-parse t) args #f))

(module+ test
  (require rackunit)
  (struct choice (question kind options show?) #:transparent)
  (struct option (label) #:transparent)
  (define poll
    (object-type choice (list (list 'question (string-type 1 10))
                              (list 'kind (one-of-type "single" "multi"))
                              (list 'options (array-type (object-type option (list (list 'label (string-type 1 5)))) 1 3))
                              (list 'show-results (optional-boolean-type #f)))))
  (define (field-of v)
    (with-handlers ([exn:mcp:invalid-argument? exn:mcp:invalid-argument-field]) (parse-arguments poll v) #f))
  (define ok (hasheq 'question "Q" 'kind "multi" 'options (list (hasheq 'label "a"))))

  (test-case "the schema lists required fields, limits, enums and defaults"
    (define s (field-type-schema poll))
    (define props (hash-ref s 'properties))
    (check-equal? (hash-ref s 'required) '("question" "kind" "options"))
    (check-false (hash-ref s 'additionalProperties))
    (check-equal? (hash-ref props 'show_results) (hasheq 'type "boolean" 'default #f))
    (check-equal? (hash-ref props 'kind) (hasheq 'type "string" 'enum '("single" "multi")))
    (check-equal? (hash-ref props 'question) (hasheq 'type "string" 'minLength 1 'maxLength 10))
    (check-equal? (hash-ref (hash-ref props 'options) 'maxItems) 3)
    (check-true (jsexpr? s)))
  (test-case "an object without fields is the empty schema"
    (check-equal? (field-type-schema (object-type void '())) (hasheq 'type "object" 'additionalProperties #f)))
  (test-case "arguments become a struct, defaults fill in"
    (check-equal? (parse-arguments poll ok) (choice "Q" "multi" (list (option "a")) #f))
    (check-equal? (choice-show? (parse-arguments poll (hash-set ok 'show_results #t))) #t))
  (test-case "failures name the field path"
    (check-equal? (field-of (hasheq)) "question")
    (check-equal? (field-of (hash-set ok 'question "")) "question")
    (check-equal? (field-of (hash-set ok 'question "way too long text")) "question")
    (check-equal? (field-of (hash-set ok 'kind "x")) "kind")
    (check-equal? (field-of (hash-set ok 'options '())) "options")
    (check-equal? (field-of (hash-set ok 'options (list (hasheq 'label "a") (hasheq 'label "")))) "options[1].label")
    (check-equal? (field-of (hash-set ok 'options (list 3))) "options[0]")
    (check-equal? (field-of (hash-set ok 'show_results "yes")) "show_results")
    (check-equal? (field-of (hash-set ok 'extra 1)) "extra")
    (check-equal? (field-of "text") ""))
  (test-case "integers, nullable and optional strings"
    (define t (object-type list (list (list 'n (integer-type 1 5)) (list 'note (nullable-type (string-type 1 3)))
                                      (list 'tag (optional-string-type 0 3 "x")))))
    (check-equal? (parse-arguments t (hasheq 'n 2 'note 'null)) '(2 #f "x"))
    (check-equal? (parse-arguments t (hasheq 'n 2 'note "ab" 'tag "t")) '(2 "ab" "t"))
    (check-exn #rx"integer" (λ () (parse-arguments t (hasheq 'n 6 'note 'null))))
    (check-exn #rx"integer" (λ () (parse-arguments t (hasheq 'n 1.5 'note 'null))))
    (check-exn #rx"required" (λ () (parse-arguments t (hasheq 'n 1))))
    (check-equal? (hash-ref (field-type-schema t) 'required) '("n" "note"))))
