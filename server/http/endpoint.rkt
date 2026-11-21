#lang racket/base
;; define-endpoint: a request handler as a small declarative spec.
;;
;;   (define-endpoint (create-poll d req me pid)             ; handler (deps request me path-arg ...)
;;     #:need [dk (deck me pid #:can edit)]                   ; lookups: 404/403/410 on failure
;;     #:json [draft (test-poll [slide (slide-or-null (presentation-page-count (deck-presentation dk)))]
;;                               [question (string 1 500)]    ; JSON body -> struct, 422 naming the field
;;                               [kind (one-of "single" "multi")]
;;                               [options (strings 2 30 1 200)])]
;;     (json-response ...))
;;
;; Clauses run in order, each binding names for the ones after and the body. A field `page-count`
;; reads the key "page_count". `me` is the logged-in user (public handlers take no `me`).
;; Lookups for the public handlers: (presentation id) (poll id) (public-session pid code)
;; (screen-session pid screen-code) (live code) (presentation-of session-or-poll).
;; Lookups for the moderator handlers take `me` and the capability needed: (deck me id #:can edit)
;; (poll me id #:can edit) (session me code #:can moderate [#:mutation]). A capability is one of view, edit,
;; moderate, copy, results, owner; a deck the user cannot see is a 404, one they can see without the
;; capability a 403, and #:mutation adds a 410 once the session has ended.
;; JSON types: (string lo hi) (optional-string lo hi default) (integer) (id) (boolean) (optional-boolean default) (one-of s ...)
;; (overlay-request) (slide pages) (slide-or-null pages) (strings lo hi item-lo item-hi) (distinct-integers).
;; #:form [in (ctor [field type] ...)] reads multipart: (text lo hi) (count lo hi) (file).
;; A malformed spec is a compile-time error.
(require (for-syntax racket/base racket/string syntax/parse "../auth/access.rkt")
         web-server/http "json.rkt" "lookup.rkt" "validate.rkt")
(provide define-endpoint)

(begin-for-syntax
  ;; Identifier -> Syntax
  ;; the quoted request key of a field: run-id reads "run_id"
  (define (key-of id)
    (define key (string->symbol (string-replace (symbol->string (syntax-e id)) "-" "_")))
    #`(quote #,(datum->syntax id key)))

  (define-syntax-class capability
    #:description "capability (view, edit, moderate, copy, results or owner)"
    #:attributes (sym)
    (pattern c:id #:when (memq (syntax-e #'c) capabilities) #:with sym #''c))

  (define-syntax-class lookup
    #:description "lookup, e.g. (presentation id) or (session me code #:can moderate #:mutation)"
    #:attributes (fn (arg 1))
    (pattern ((~datum presentation) a:expr) #:with fn #'need-presentation #:with (arg ...) #'(a))
    (pattern ((~datum poll) a:expr) #:with fn #'need-poll #:with (arg ...) #'(a))
    (pattern ((~datum deck) me:expr id:expr #:can c:capability) #:with fn #'need-deck #:with (arg ...) #'(me id c.sym))
    (pattern ((~datum poll) me:expr id:expr #:can c:capability) #:with fn #'need-user-poll #:with (arg ...) #'(me id c.sym))
    (pattern ((~datum session) me:expr code:expr #:can c:capability #:mutation)
             #:with fn #'need-user-mutable-session #:with (arg ...) #'(me code c.sym))
    (pattern ((~datum session) me:expr code:expr #:can c:capability)
             #:with fn #'need-user-session #:with (arg ...) #'(me code c.sym))
    (pattern ((~datum public-session) p:expr c:expr) #:with fn #'need-public-session #:with (arg ...) #'(p c))
    (pattern ((~datum screen-session) p:expr c:expr) #:with fn #'need-screen-session #:with (arg ...) #'(p c))
    (pattern ((~datum live) a:expr) #:with fn #'need-live #:with (arg ...) #'(a))
    (pattern ((~datum presentation-of) a:expr) #:with fn #'need-presentation-of #:with (arg ...) #'(a)))

  (define-syntax-class json-type
    #:description "JSON field type (string, optional-string, integer, id, boolean, optional-boolean, one-of, overlay-request, slide, slide-or-null, strings or distinct-integers)"
    #:attributes (fn (arg 1))
    (pattern ((~datum string) lo:expr hi:expr) #:with fn #'body-string #:with (arg ...) #'(lo hi))
    (pattern ((~datum optional-string) lo:expr hi:expr d:expr) #:with fn #'body-optional-string #:with (arg ...) #'(lo hi d))
    (pattern ((~datum integer)) #:with fn #'body-int #:with (arg ...) #'())
    (pattern ((~datum id)) #:with fn #'body-id #:with (arg ...) #'())
    (pattern ((~datum boolean)) #:with fn #'body-bool #:with (arg ...) #'())
    (pattern ((~datum optional-boolean) d:expr) #:with fn #'body-bool-or-default #:with (arg ...) #'(d))
    (pattern ((~datum one-of) s:str ...+) #:with fn #'body-one-of #:with (arg ...) #'(s ...))
    (pattern ((~datum overlay-request)) #:with fn #'body-overlay-request #:with (arg ...) #'())
    (pattern ((~datum slide) pages:expr) #:with fn #'body-slide #:with (arg ...) #'(pages))
    (pattern ((~datum slide-or-null) pages:expr) #:with fn #'body-slide-or-null #:with (arg ...) #'(pages))
    (pattern ((~datum strings) lo:expr hi:expr ilo:expr ihi:expr) #:with fn #'body-strings #:with (arg ...) #'(lo hi ilo ihi))
    (pattern ((~datum distinct-integers)) #:with fn #'body-distinct-ints #:with (arg ...) #'()))

  (define-syntax-class form-type
    #:description "form field type (text, count or file)"
    #:attributes (fn (arg 1))
    (pattern ((~datum text) lo:expr hi:expr) #:with fn #'form-text #:with (arg ...) #'(lo hi))
    (pattern ((~datum count) lo:expr hi:expr) #:with fn #'form-count #:with (arg ...) #'(lo hi))
    (pattern ((~datum file)) #:with fn #'form-file #:with (arg ...) #'()))

  (define-syntax-class json-field
    #:description "field spec [name type]"
    #:attributes (name key fn (arg 1))
    (pattern [name:id t:json-type]
             #:with key (key-of #'name) #:with fn #'t.fn #:with (arg ...) #'(t.arg ...)))

  (define-syntax-class form-field
    #:description "field spec [name type]"
    #:attributes (name key fn (arg 1))
    (pattern [name:id t:form-type]
             #:with key (key-of #'name) #:with fn #'t.fn #:with (arg ...) #'(t.arg ...)))

  ;; d, req: the handler's own parameter identifiers
  (define-splicing-syntax-class (clause d req)
    #:description "clause (#:need, #:json or #:form)"
    #:attributes ((def 1))
    (pattern (~seq #:need [x:id l:lookup] ...+)
             #:with (def ...) #`((define x (l.fn #,d l.arg ...)) ...))
    (pattern (~seq #:json [in:id (ctor:id f:json-field ...)])
             #:fail-when (check-duplicate-identifier (syntax->list #'(f.name ...))) "duplicate field"
             #:with (def ...) #`((define in (let ([h (request-json #,req)]) (ctor (f.fn h f.key f.arg ...) ...)))))
    (pattern (~seq #:form [in:id (ctor:id f:form-field ...)])
             #:fail-when (check-duplicate-identifier (syntax->list #'(f.name ...))) "duplicate field"
             #:with (def ...) #`((define in (let ([h (request-bindings/raw #,req)]) (ctor (f.fn h f.key f.arg ...) ...)))))))

(define-syntax (define-endpoint stx)
  (syntax-parse stx
    [(_ (name:id d:id req:id arg:id ...) (~var c (clause #'d #'req)) ... body:expr ...+)
     #'(define (name d req arg ...) c.def ... ... body ...)]))

(module+ test
  (require rackunit syntax/macro-testing net/url racket/promise "../domain.rkt" "inputs.rkt")
  (define (request-with body)
    (make-request #"POST" (string->url "/x") '() (delay '()) body "127.0.0.1" 80 "127.0.0.1"))
  (define (field-of thunk) (with-handlers ([exn:api? exn:api-field]) (thunk) #f))

  (struct test-poll (slide question kind options show-results?) #:transparent)
  (define-endpoint (parse-poll d req pages)
    #:json [draft (test-poll [slide (slide-or-null pages)] [question (string 1 500)]
                              [kind (one-of "single" "multi")] [options (strings 2 30 1 200)]
                              [show-results (boolean)])]
    draft)
  (define-endpoint (parse-vote d req)
    #:json [in (vote-input [run-id (id)] [option-ids (distinct-integers)])]
    in)
  (define ok #"{\"slide\":3,\"question\":\"Q\",\"kind\":\"single\",\"options\":[\"a\",\"b\"],\"show_results\":true}")

  (test-case "a JSON body becomes a struct; keys use underscores"
    (check-equal? (parse-poll #f (request-with ok) 10) (test-poll 3 "Q" "single" '("a" "b") #t))
    (define v (parse-vote #f (request-with #"{\"run_id\":12,\"option_ids\":[1,2]}")))
    (check-equal? (list (vote-input-run-id v) (vote-input-option-ids v)) '(12 (1 2))))
  (test-case "fields are validated in spec order, naming the culprit"
    (check-equal? (field-of (λ () (parse-poll #f (request-with ok) 2))) "slide")
    (check-equal? (field-of (λ () (parse-poll #f (request-with #"{\"question\":\"\",\"kind\":\"x\"}") 10))) "question")
    (check-equal? (field-of (λ () (parse-vote #f (request-with #"{\"run_id\":1}")))) "option_ids"))
  (test-case "a body that is not an object is 400"
    (check-exn exn:api? (λ () (parse-poll #f (request-with #"[1]") 10))))

  (define-syntax-rule (expansion-error rx form)
    (check-exn rx (λ () (convert-compile-time-error (let () form (void))))))
  (test-case "malformed specs are compile-time errors"
    (expansion-error #rx"JSON field type"
                     (define-endpoint (e d req) #:json [in (poll-draft [slide (bogus)])] in))
    (expansion-error #rx"field spec"
                     (define-endpoint (e d req) #:json [in (poll-draft [slide])] in))
    (expansion-error #rx"duplicate field"
                     (define-endpoint (e d req) #:json [in (poll-draft [slide (integer)] [slide (integer)])] in))
    (expansion-error #rx"lookup"
                     (define-endpoint (e d req id) #:need [x (bogus id)] x))
    (expansion-error #rx"capability"
                     (define-endpoint (e d req me id) #:need [x (deck me id #:can write)] x))
    (expansion-error #rx"lookup"
                     (define-endpoint (e d req me id) #:need [x (deck me id)] x))
    (expansion-error #rx"lookup"
                     (define-endpoint (e d req me id) #:need [x (deck me id #:can edit #:mutation)] x))
    (expansion-error #rx"lookup"
                     (define-endpoint (e d req me id) #:need [x (poll me id #:can edit #:mutation)] x))
    (expansion-error #rx"form field type"
                     (define-endpoint (e d req) #:form [in (upload-input [title (bogus)])] in))
    (expansion-error #rx"clause|expected"
                     (define-endpoint (e d req) #:json)))
  (test-case "well-formed specs compile"
    (check-not-exn
     (λ () (convert-compile-time-error
            (let ()
              (define-endpoint (e d req me id code)
                #:need [s (session me code #:can moderate #:mutation)] [p (presentation-of s)] [q (poll id)]
                       [k (deck me id #:can owner)] [r (poll me id #:can edit)] [t (session me code #:can results)]
                #:form [up (upload-input [title (text 1 200)] [page-count (count 1 9)] [pdf (file)])]
                (list s p q k r t up))
              (void)))))))
