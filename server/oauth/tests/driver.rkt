#lang racket/base
;; A stage for driving the OAuth server through its public API: a settable clock, subjects whose
;; epoch can move on, two registered clients and request builders (test-only: never required from
;; main.rkt). The lifecycle property and the handler fuzz tests are built on it.
(require racket/contract/base racket/list racket/promise racket/string json net/uri-codec net/url
         web-server/http
         "../data.rkt" "../store.rkt" "../server.rkt" "../token-format.rkt")
(provide
 (contract-out
  [struct stage ([clock (box/c exact-integer?)] [epochs (hash/c any/c exact-nonnegative-integer?)]
                 [server oauth-server?] [store oauth-store?])]
  [make-stage (->* () (oauth-store? #:max-unused-clients exact-nonnegative-integer?) stage?)]
  [stage-now (-> stage? exact-integer?)]
  [stage-advance! (-> stage? exact-nonnegative-integer? void?)]
  [stage-epoch (-> stage? any/c exact-nonnegative-integer?)]
  [stage-bump-epoch! (-> stage? any/c void?)]
  [stage-put-client! (-> stage? string? boolean? exact-integer? void?)]
  [make-req (->* (bytes? string?) (bytes? (listof (cons/c string? string?))) request?)]
  [post-form (->* (oauth-server? (listof (cons/c symbol? string?)))
                  (#:handler (-> oauth-server? request? response?) #:type string?) response?)]
  [authorize-request (-> (listof (cons/c symbol? string?)) request?)]
  [bearer-request (-> string? request?)]
  [body-of (-> response? bytes?)]
  [json-of (-> response? jsexpr?)]
  [header-of (-> response? string? (or/c string? #f))]
  [query-of (-> string? (hash/c string? (or/c string? #f)))]
  [connect! (-> stage? string? any/c (listof string?) (listof string?) (or/c string? #f))]
  [exchange-code (->* (stage? string?)
                      (#:client string? #:verifier string? #:redirect (or/c string? #f)) response?)]
  [refresh-with (->* (stage? string?) (#:client string?) response?)]
  [authenticate-with (-> stage? string? (or/c principal? response?))])
 app-resource issuer redirect verifier challenge client-ids app-scope-names oauth-app-of)

(define t0 1000000)
(define issuer "https://orq.example")
(define app-resource "https://orq.example/mcp")
(define redirect "https://app.example/cb")
(define verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
(define challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
;; (listof String)
;; the stage's registered clients: the first may hold refresh tokens, the second may not
(define client-ids '("client-a" "client-b"))
(define app-scope-names '("decks" "results"))

;; A Stage is a (stage (Boxof Integer) (Hash Subject Natural) OAuthServer OAuthStore)
;; the clock in seconds, each subject's current epoch (0 when absent), the server and its store

(struct stage (clock epochs server store))

;; Stage -> OAuthApp
(define (oauth-app-of st)
  (oauth-app issuer app-resource '(("decks" . "Manage decks") ("results" . "Read results"))
             (λ (id) (string-append "/connect/" id))
             (λ (subject epoch) (= epoch (stage-epoch st subject)))
             (λ (url) (fetched 404 #f #f #""))
             (λ () (stage-now st))))

;; [OAuthStore] [#:max-unused-clients Natural] -> Stage
;; a server over the store (a fresh memory store by default) with the two clients registered now
(define (make-stage [store (make-memory-store)] #:max-unused-clients [max-unused 1000])
  (define clock (box t0))
  (define epochs (make-hash))
  (define placeholder (stage clock epochs #f store))
  (define server (make-oauth-server (oauth-app-of placeholder) store opaque-format
                                    #:max-unused-clients max-unused))
  (define st (stage clock epochs server store))
  (for ([id (in-list client-ids)] [refresh? (in-list '(#t #f))]) (stage-put-client! st id refresh? t0))
  st)

;; Stage -> Integer
(define (stage-now st) (unbox (stage-clock st)))
;; Stage Natural -> Void
(define (stage-advance! st dt) (set-box! (stage-clock st) (+ (stage-now st) dt)))
;; Stage Subject -> Natural
(define (stage-epoch st subject) (hash-ref (stage-epochs st) subject 0))
;; Stage Subject -> Void
;; the subject's earlier grants stop working
(define (stage-bump-epoch! st subject) (hash-update! (stage-epochs st) subject add1 0))

;; Stage String Boolean Integer -> Void
;; stores a registered client created at `created` (replacing the one with its id)
(define (stage-put-client! st id refresh? created)
  (store-client-put! (stage-store st) (client id 'registered (string-append "App " id) #f #f (list redirect)
                                              refresh? created #f)))

;; ---------------------------------------------------------------------------------------------
;; Requests and responses

;; Bytes String [Bytes] [(listof (cons String String))] -> Request
(define (make-req method url [body #""] [headers '()])
  (make-request method (string->url url)
                (for/list ([h (in-list headers)]) (make-header (string->bytes/utf-8 (car h)) (string->bytes/utf-8 (cdr h))))
                (delay '()) body "127.0.0.1" 80 "127.0.0.1"))

;; (listof (cons Symbol String)) -> Bytes
(define (form alist) (string->bytes/utf-8 (alist->form-urlencoded alist)))

;; OAuthServer (listof (cons Symbol String)) [#:handler Handler] [#:type String] -> Response
(define (post-form srv alist #:handler [handler handle-token] #:type [type "application/x-www-form-urlencoded"])
  (handler srv (make-req #"POST" "/oauth/token" (form alist) (list (cons "Content-Type" type)))))

;; (listof (cons Symbol String)) -> Request
(define (authorize-request alist)
  (make-req #"GET" (string-append "/oauth/authorize?" (alist->form-urlencoded alist))))

;; String -> Request
(define (bearer-request token)
  (make-req #"POST" "/mcp" #"" (list (cons "Authorization" (string-append "Bearer " token)))))

;; Response -> Bytes
(define (body-of r) (let ([o (open-output-bytes)]) ((response-output r) o) (get-output-bytes o)))
;; Response -> JSExpr
(define (json-of r) (bytes->jsexpr (body-of r)))
;; Response String -> (or String #f)
(define (header-of r name)
  (define h (headers-assq* (string->bytes/utf-8 name) (response-headers r)))
  (and h (bytes->string/utf-8 (header-value h))))
;; String -> (Hash String (or String #f))
(define (query-of url-string)
  (for/hash ([kv (in-list (url-query (string->url url-string)))]) (values (symbol->string (car kv)) (cdr kv))))

;; ---------------------------------------------------------------------------------------------
;; Actions

;; Stage String Subject (listof String) (listof String) -> (or String #f)
;; asks for authorization as `client-id`, scopes `requested`, and has the subject approve with `chosen`
;; at its current epoch: the authorization code, or #f when the authorization request is refused
(define (connect! st client-id subject requested chosen)
  (define srv (stage-server st))
  (define r (handle-authorize srv (authorize-request
                                   (list (cons 'response_type "code") (cons 'client_id client-id)
                                         (cons 'redirect_uri redirect) (cons 'state "xyz")
                                         (cons 'code_challenge challenge) (cons 'code_challenge_method "S256")
                                         (cons 'scope (string-join requested " ")) (cons 'resource app-resource)))))
  (and (= (response-code r) 302)
       (let ([url (approve! srv (last (string-split (header-of r "Location") "/")) subject
                            (stage-epoch st subject) chosen)])
         (and url (hash-ref (query-of url) "code")))))

;; Stage String [#:client String] [#:verifier String] [#:redirect (or String #f)] -> Response
(define (exchange-code st code #:client [client (car client-ids)] #:verifier [v verifier] #:redirect [r redirect])
  (post-form (stage-server st)
             (append (list (cons 'grant_type "authorization_code") (cons 'code code) (cons 'code_verifier v)
                           (cons 'client_id client))
                     (if r (list (cons 'redirect_uri r)) '()))))

;; Stage String [#:client String] -> Response
(define (refresh-with st token #:client [client (car client-ids)])
  (post-form (stage-server st)
             (list (cons 'grant_type "refresh_token") (cons 'refresh_token token) (cons 'client_id client))))

;; Stage String -> (or Principal Response)
(define (authenticate-with st token) (authenticate (stage-server st) (bearer-request token)))

(module+ test
  (require rackunit)

  (test-case "the stage runs the whole flow"
    (define st (make-stage))
    (define code (connect! st "client-a" 7 '("decks" "results") '("decks")))
    (check-pred string? code)
    (define j (json-of (exchange-code st code)))
    (check-equal? (hash-ref j 'scope) "decks")
    (check-equal? (hash-ref j 'expires_in) 3600)
    (check-pred principal? (authenticate-with st (hash-ref j 'access_token)))
    (stage-bump-epoch! st 7)
    (check-equal? (response-code (authenticate-with st (hash-ref j 'access_token))) 401))

  (test-case "a replayed code revokes, an unknown client is refused"
    (define st (make-stage))
    (define code (connect! st "client-b" 7 '("decks") '("decks")))
    (define j (json-of (exchange-code st code #:client "client-b")))
    (check-false (hash-has-key? j 'refresh_token) "client-b may not hold refresh tokens")
    (check-equal? (response-code (exchange-code st code #:client "client-b")) 400)
    (check-equal? (response-code (authenticate-with st (hash-ref j 'access_token))) 401)
    (check-false (connect! st "nobody" 7 '("decks") '("decks")))))
