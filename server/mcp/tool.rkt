#lang racket/base
;; define-tool: an MCP tool as a small declarative spec.
;;
;;   (define-tool (create-poll ctx)                       ; binds `create-poll`, a Tool named "create_poll"
;;     #:title "Create a poll"                            ; optional
;;     #:description "Adds a poll to a slide."            ; required
;;     #:scope "decks"                                    ; optional: the OAuth scope the caller needs (any
;;                                                        ;   expression yielding a string, checked when defined)
;;     #:destructive #:idempotent                         ; optional hints; #:read-only for queries
;;     #:args [in (new-poll [question (string 1 500)]     ; optional: arguments -> struct; no #:args = no arguments
;;                          [kind (one-of "single" "multi")]
;;                          [options (array (object new-option [label (string 1 200)]) 2 30)])]
;;     (hasheq 'id 1))                                    ; body: a JSON object, or a tool-result
;;
;; Options come in any order, before or after #:args, and the body is last. `ctx` is whatever the app
;; passes to the server on each call. A field `show-results` reads the key "show_results"; two fields
;; whose keys collide (a-b, a_b) are an error. An optional field may be left out or null; `(optional T)` then reads
;; as #f, the others as their default, which must lie within the bounds (checked when defined). Types: (string lo hi) (optional-string lo hi d)
;; (integer lo hi) (optional-integer lo hi d) (optional T) (boolean) (optional-boolean d) (one-of s ...) (array T lo hi) (nullable T)
;; (object ctor [field T] ...). The input schema is generated from the same spec that parses the
;; arguments. A malformed spec is a compile-time error. Tool names are 1-128 characters of A-Za-z0-9_-.
;; (the identifier's `-` becomes `_`). A body that returns something else than a JSON object or a
;; tool-result raises, like any failing tool.
(require (for-syntax racket/base racket/string syntax/parse)
         racket/contract/base json "schema.rkt")
(provide define-tool
         (contract-out
          [struct annotations ([read-only? boolean?] [destructive? boolean?] [idempotent? boolean?])]
          [struct tool ([name string?] [title (or/c string? #f)] [description string?] [input-schema jsexpr?]
                        [scope (or/c string? #f)] [annotations annotations?]
                        [handler (-> any/c jsexpr? tool-result?)])]
          [struct tool-result ([content (and/c jsexpr? hash?)] [error? boolean?])]
          [tool-error (-> (and/c jsexpr? hash?) tool-result?)]
          [tool->jsexpr (-> tool? jsexpr?)]
          [as-tool-result (-> string? any/c tool-result?)]
          [check-scope (-> any/c (or/c string? #f))]))

;; An Annotations is an (annotations Boolean Boolean Boolean): read-only, destructive, idempotent hints
;; A Ctx is whatever the app hands to the server per call (typically the authenticated user)
;; A Tool is a (tool String (or String #f) String JSObject (or String #f) Annotations (Ctx JSObject -> ToolResult))
;;   name, title, description, input schema, required scope, hints and the handler
;; A ToolResult is a (tool-result JSObject Boolean): the structured content, and whether the call failed
(struct annotations (read-only? destructive? idempotent?))
(struct tool (name title description input-schema scope annotations handler))
(struct tool-result (content error?))

;; JSObject -> ToolResult
;; a failed call: the model sees the content and can retry
(define (tool-error content) (tool-result content #t))

;; String Any -> ToolResult
;; what a tool body returned, as a ToolResult; anything but a JSON object or a ToolResult raises,
;; naming the tool
(define (as-tool-result name v)
  (cond [(tool-result? v) v]
        [(and (hash? v) (jsexpr? v)) (tool-result v #f)]
        [else (error (format "tool ~a: returned ~e, expected a JSON object or a tool-result" name v))]))

;; Any -> (or String #f)
;; the scope of a tool, checked when the tool is defined
(define (check-scope s)
  (if (or (not s) (string? s)) s (raise-argument-error 'define-tool "(or/c string? #f)" s)))

;; Annotations -> JSObject
;; destructiveHint is only meaningful (and only sent) for tools that write
(define (annotations->jsexpr a)
  (define h (hasheq))
  (let* ([h (if (annotations-read-only? a) (hash-set h 'readOnlyHint #t) h)]
         [h (if (annotations-read-only? a) h (hash-set h 'destructiveHint (annotations-destructive? a)))]
         [h (if (annotations-idempotent? a) (hash-set h 'idempotentHint #t) h)])
    h))

;; Tool -> JSObject
;; the tool definition of tools/list
(define (tool->jsexpr t)
  (define base (hasheq 'name (tool-name t) 'description (tool-description t)
                       'inputSchema (tool-input-schema t) 'annotations (annotations->jsexpr (tool-annotations t))))
  (if (tool-title t) (hash-set base 'title (tool-title t)) base))

(begin-for-syntax
  ;; Identifier -> String
  ;; the wire name of an identifier: create-poll is "create_poll"
  (define (tool-name-of id) (string-replace (symbol->string (syntax-e id)) "-" "_"))

  ;; String -> Boolean
  (define (valid-tool-name? s) (regexp-match? #px"^[A-Za-z0-9_.-]{1,128}$" s))

  ;; (listof Identifier) -> (or Identifier #f)
  ;; the first identifier whose wire name an earlier one already took
  (define (duplicate-wire-name ids)
    (define seen (make-hash))
    (for/first ([id (in-list ids)]
                #:when (let ([k (tool-name-of id)]) (begin0 (hash-ref seen k #f) (hash-set! seen k #t))))
      id))

  ;; Syntax -> Boolean
  ;; is the field spec a boolean or one with a default (optional-string, optional-integer, optional-boolean, optional)?
  (define (defaulted-spec? stx)
    (syntax-parse stx
      [((~or (~datum boolean) (~datum optional-boolean) (~datum optional-string) (~datum optional-integer) (~datum optional)) . _) #t]
      [_ #f]))

  ;; Syntax Syntax Syntax (Any -> (or Real #f)) -> (or Syntax #f)
  ;; the default when its measure (a number, or #f when it is not literal) is outside literal bounds
  (define (default-outside lo hi d measure)
    (define l (syntax-e lo))
    (define h (syntax-e hi))
    (define m (measure (syntax-e d)))
    (and (real? l) (real? h) m (not (<= l m h)) d))

  ;; Syntax Syntax -> (or Syntax #f)
  ;; lo when both bounds are literal numbers and lo exceeds hi
  (define (reversed-range lo hi)
    (define l (syntax-e lo))
    (define h (syntax-e hi))
    (and (real? l) (real? h) (> l h) lo))

  (define-syntax-class field-spec
    #:description "field type (string, optional-string, integer, optional-integer, optional, boolean, optional-boolean, one-of, array, nullable or object)"
    #:attributes (expr)
    (pattern ((~datum string) lo:expr hi:expr)
             #:fail-when (reversed-range #'lo #'hi) "lower bound exceeds upper bound"
             #:with expr #'(string-type lo hi))
    (pattern ((~datum optional-string) lo:expr hi:expr d:expr)
             #:fail-when (reversed-range #'lo #'hi) "lower bound exceeds upper bound"
             #:fail-when (default-outside #'lo #'hi #'d (λ (v) (and (string? v) (string-length v)))) "default outside the bounds"
             #:with expr #'(optional-string-type lo hi d))
    (pattern ((~datum integer) lo:expr hi:expr)
             #:fail-when (reversed-range #'lo #'hi) "lower bound exceeds upper bound"
             #:with expr #'(integer-type lo hi))
    (pattern ((~datum optional-integer) lo:expr hi:expr d:expr)
             #:fail-when (reversed-range #'lo #'hi) "lower bound exceeds upper bound"
             #:fail-when (default-outside #'lo #'hi #'d (λ (v) (and (real? v) v))) "default outside the bounds"
             #:with expr #'(optional-integer-type lo hi d))
    (pattern ((~datum optional) t:field-spec)
             #:fail-when (and (defaulted-spec? #'t) #'t)
             "optional wraps a type without a default: a boolean or optional-* type already reads as its default"
             #:with expr #'(optional-type t.expr))
    (pattern ((~datum boolean)) #:with expr #'(boolean-type))
    (pattern ((~datum optional-boolean) d:expr) #:with expr #'(optional-boolean-type d))
    (pattern ((~datum one-of) s:str ...+) #:with expr #'(one-of-type s ...))
    (pattern ((~datum array) t:field-spec lo:expr hi:expr)
             #:fail-when (reversed-range #'lo #'hi) "lower bound exceeds upper bound"
             #:with expr #'(array-type t.expr lo hi))
    (pattern ((~datum nullable) t:field-spec) #:with expr #'(nullable-type t.expr))
    (pattern ((~datum object) ctor:expr f:named-field ...)
             #:fail-when (duplicate-wire-name (syntax->list #'(f.name ...))) "duplicate field"
             #:with expr #'(object-type ctor (list f.entry ...))))

  (define-syntax-class named-field
    #:description "field spec [name type]"
    #:attributes (name entry)
    (pattern [name:id t:field-spec] #:with entry #'(list 'name t.expr)))

  ;; the arguments spec: `in` is bound to the parsed struct in the body
  (define-syntax-class args-spec
    #:description "arguments spec [name (ctor [field type] ...)]"
    #:attributes (in type)
    (pattern [in:id (ctor:id f:named-field ...)]
             #:fail-when (duplicate-wire-name (syntax->list #'(f.name ...))) "duplicate field"
             #:with type #'(object-type ctor (list f.entry ...)))))

(define-syntax (define-tool stx)
  (syntax-parse stx
    [(_ (name:id ctx:id)
        (~alt (~optional (~seq #:title title:str) #:name "#:title option")
              (~once (~seq #:description description:str) #:name "#:description option")
              (~optional (~seq #:scope scope:expr) #:name "#:scope option")
              (~optional (~and #:read-only read-only) #:name "#:read-only option")
              (~optional (~and #:destructive destructive) #:name "#:destructive option")
              (~optional (~and #:idempotent idempotent) #:name "#:idempotent option")
              (~optional (~seq #:args spec:args-spec) #:name "#:args option")) ...
        body:expr ...+)
     #:fail-when (and (attribute read-only) (attribute destructive) #'name) "a read-only tool cannot be #:destructive"
     #:fail-unless (valid-tool-name? (tool-name-of #'name)) "tool name must be 1-128 characters of A-Za-z0-9_-."
     #:with wire-name (datum->syntax #'name (tool-name-of #'name))
     #:with title-e (or (attribute title) #'#f)
     #:with scope-e (or (attribute scope) #'#f)
     #:with read-only-e (if (attribute read-only) #'#t #'#f)
     #:with destructive-e (if (attribute destructive) #'#t #'#f)
     #:with idempotent-e (if (attribute idempotent) #'#t #'#f)
     #:with in (if (attribute spec) #'spec.in (car (generate-temporaries '(in))))
     #:with in-type (if (attribute spec) #'spec.type #'(object-type void '()))
     #'(define name
         (let ([type in-type])
           (tool wire-name title-e description (field-type-schema type) (check-scope scope-e)
                 (annotations read-only-e destructive-e idempotent-e)
                 (λ (ctx args)
                   (let ([in (parse-arguments type args)])
                     (as-tool-result wire-name (let () body ...)))))))]))

(module+ test
  (require rackunit syntax/macro-testing)
  (struct new-option (label) #:transparent)
  (struct new-poll (question kind options) #:transparent)
  (struct c (a b) #:transparent)

  (define-tool (create-poll ctx)
    #:title "Create a poll"
    #:description "Adds a poll."
    #:scope "decks"
    #:idempotent
    #:args [in (new-poll [question (string 1 20)]
                         [kind (one-of "single" "multi")]
                         [options (array (object new-option [label (string 1 5)]) 1 3)])]
    (hasheq 'ctx (format "~a" ctx) 'poll (format "~a" in)))
  (define-tool (list-decks ctx)
    #:description "Lists decks."
    #:read-only
    (hasheq 'n 0))
  (define-tool (fail-tool ctx) #:description "x" (tool-error (hasheq 'error "nope")))
  (define-tool (bad-return ctx) #:description "x" 'not-json)
  (define-tool (late-options ctx)
    #:args [in (list [a-b (boolean)])]
    #:description "options after #:args"
    #:scope (string-append "de" "cks")
    (hasheq 'a (car in)))

  (test-case "the tool takes its name, scope and hints from the spec"
    (check-equal? (tool-name create-poll) "create_poll")
    (check-equal? (tool-scope create-poll) "decks")
    (check-false (tool-scope list-decks))
    (check-equal? (tool-title create-poll) "Create a poll")
    (check-equal? (annotations->jsexpr (tool-annotations create-poll))
                  (hasheq 'destructiveHint #f 'idempotentHint #t))
    (check-equal? (annotations->jsexpr (tool-annotations list-decks)) (hasheq 'readOnlyHint #t)))
  (test-case "the schema comes from the arguments spec; no #:args means no properties"
    (define s (tool-input-schema create-poll))
    (check-equal? (hash-ref s 'required) '("question" "kind" "options"))
    (check-equal? (tool-input-schema list-decks) (hasheq 'type "object" 'additionalProperties #f))
    (check-true (jsexpr? (tool->jsexpr create-poll)))
    (check-false (hash-has-key? (tool->jsexpr list-decks) 'title)))
  (test-case "the handler parses the arguments and wraps the body's value"
    (define r ((tool-handler create-poll) 'me (hasheq 'question "Q" 'kind "single" 'options (list (hasheq 'label "a")))))
    (check-false (tool-result-error? r))
    (check-equal? (hash-ref (tool-result-content r) 'poll) "#(struct:new-poll Q single (#(struct:new-option a)))")
    (check-exn exn:mcp:invalid-argument? (λ () ((tool-handler create-poll) 'me (hasheq))))
    (check-equal? (tool-result-content ((tool-handler list-decks) 'me (hasheq))) (hasheq 'n 0))
    (check-true (tool-result-error? ((tool-handler fail-tool) 'me (hasheq)))))
  (test-case "a body returning something else than a JSON object raises, naming the tool"
    (check-exn #rx"tool bad_return: returned 'not-json" (λ () ((tool-handler bad-return) 'me (hasheq))))
    (check-exn exn:fail? (λ () (as-tool-result "t" (hasheq 'a (λ () 1))))))
  (test-case "options may follow #:args, and #:scope is any expression yielding a string"
    (check-equal? (tool-scope late-options) "decks")
    (check-equal? (hash-ref (tool-input-schema late-options) 'required) '("a_b"))
    (check-equal? (tool-result-content ((tool-handler late-options) 'me (hasheq 'a_b #t))) (hasheq 'a #t))
    (check-exn #rx"string" (λ () (check-scope 3))))

  (define-syntax-rule (expansion-error rx form)
    (check-exn rx (λ () (convert-compile-time-error (let () form (void))))))
  (test-case "malformed specs are compile-time errors"
    (expansion-error #rx"field type"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (bogus)])] in))
    (expansion-error #rx"field spec"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a])] in))
    (expansion-error #rx"duplicate field"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (boolean)] [a (boolean)])] in))
    (expansion-error #rx"duplicate field"
                     (define-tool (t ctx) #:description "d"
                       #:args [in (c [a (object d [x (boolean)] [x (boolean)])])] in))
    (expansion-error #rx"expected one of these literals"
                     (define-tool (t ctx) #:description "d" #:read-onyl (hasheq)))
    (expansion-error #rx"duplicate field"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a-b (boolean)] [a_b (boolean)])] in))
    (expansion-error #rx"duplicate field"
                     (define-tool (t ctx) #:description "d"
                       #:args [in (c [a (object d [x-y (boolean)] [x_y (boolean)])])] in))
    (expansion-error #rx"default outside"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (optional-integer 1 5 9)])] in))
    (expansion-error #rx"default outside"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (optional-string 1 2 "")])] in))
    (expansion-error #rx"field type"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (optional (bogus))])] in))
    (expansion-error #rx"optional wraps"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (optional (boolean))])] in))
    (expansion-error #rx"optional wraps"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (optional (optional-boolean #f))])] in))
    (expansion-error #rx"optional wraps"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (optional (optional-integer 1 5 2))])] in))
    (expansion-error #rx"optional wraps"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (optional (optional-string 1 2 "a"))])] in))
    (expansion-error #rx"optional wraps"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (optional (optional (integer 1 5)))])] in))
    (expansion-error #rx"lower bound exceeds"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (string 5 1)])] in))
    (expansion-error #rx"lower bound exceeds"
                     (define-tool (t ctx) #:description "d" #:args [in (c [a (array (boolean) 3 2)])] in))
    (expansion-error #rx"too many|duplicate|#:read-only"
                     (define-tool (t ctx) #:description "d" #:read-only #:read-only (hasheq)))
    (expansion-error #rx"too many|#:description"
                     (define-tool (t ctx) #:description "d" #:args [in (c)] #:description "e" in))
    (expansion-error #rx"#:description"
                     (define-tool (t ctx) #:title "T" (hasheq)))
    (expansion-error #rx"cannot be #:destructive"
                     (define-tool (t ctx) #:description "d" #:read-only #:destructive (hasheq)))
    (expansion-error #rx"tool name"
                     (define-tool (bad? ctx) #:description "d" (hasheq)))
    (expansion-error #rx"tool name"
                     (define-tool (a/b ctx) #:description "d" (hasheq)))
    (expansion-error #rx"tool name"
                     (define-tool (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ctx)
                       #:description "d" (hasheq)))
    (expansion-error #rx"expected"
                     (define-tool (t ctx) #:description "d")))
  (test-case "optional fields: null reads as absent; (optional T) reads #f"
    (define-tool (opt ctx) #:description "d"
      #:args [in (c [a (optional (integer 1 5))] [b (optional-integer 1 5 2)])] (hasheq 'v (format "~a" in)))
    (check-equal? (hash-ref (tool-result-content ((tool-handler opt) 'me (hasheq 'a 'null 'b 'null))) 'v) "#(struct:c #f 2)")
    (check-equal? (hash-ref (hash-ref (tool-input-schema opt) 'properties) 'a)
                  (hasheq 'anyOf (list (hasheq 'type "integer" 'minimum 1 'maximum 5) (hasheq 'type "null"))))
    (check-equal? (hash-ref (tool-input-schema opt) 'additionalProperties) #f))
  (test-case "dots and digits are valid in tool names"
    (check-equal? (tool-name (let () (define-tool (get-deck.v2 ctx) #:description "d" (hasheq)) get-deck.v2))
                  "get_deck.v2")))
