#lang racket/base
;; OAuth routes: the discovery documents, authorize, token and register endpoints (public, with CORS on
;; the discovery documents and the token endpoint), and the signed-in consent and connected-apps API.
;; The protocol lives in oauth/server.rkt; this module wires it to Orquelo's database, sessions and
;; throttles. Part of core: a route table that is tried after the core rules and before the plugin's.
(require racket/contract/base racket/list net/uri-codec web-server/dispatch web-server/http
         "../auth/session.rkt" "../auth/throttle.rkt" "../config.rkt" "../db/accounts.rkt" "../db/oauth-store.rkt"
         "../domain.rkt" "../edition.rkt" "../oauth/main.rkt"
         "client-ip.rkt" "deps.rkt" "endpoint.rkt" "inputs.rkt" "json.rkt" "rate-limit.rkt")
(provide (contract-out
          [oauth-base-ok? (-> string? boolean?)]
          [struct oauth-routes ([server oauth-server?] [routes routes/c])]
          [make-oauth-routes (-> deps? (-> string? fetched?) (or/c oauth-routes? #f))]))

;; (Listof (cons String String))
;; the scopes and what the consent page tells the user each one allows
(define scope-descriptions
  '(("decks" . "Read and edit your decks, polls and deck settings")
    ("results" . "Read aggregate poll results of your decks")))

;; String -> Boolean
;; can OAuth run under this PUBLIC_BASE_URL? Its issuer must be an https (or loopback http) origin
;; with no path; the library decides, so the check cannot drift from what it accepts
(define (oauth-base-ok? base)
  (with-handlers ([exn:fail:contract? (λ (e) #f)])
    (and (validate-app! (make-app base values (λ (u e) #t) (λ (u) (fetched 404 #f #f #"")))) #t)))

;; String (String Natural -> Boolean) (String -> Fetched) -> OAuthApp
;; the app the library serves: issuer = base URL, one resource at /mcp, the two scopes
(define (make-app base consent-path current? fetch)
  (oauth-app base (string-append base "/mcp") scope-descriptions consent-path current? fetch current-seconds))

;; An OAuthRoutes is an (oauth-routes OAuthServer Routes)
;; interpretation: the server the routes talk to (other protocol endpoints, such as MCP, share it) and the
;; route table, tried after the core rules and before the plugin's
(struct oauth-routes (server routes))

;; Deps (String -> Fetched) -> (or OAuthRoutes #f)
;; the OAuth routes, or #f (with a warning) when the base URL cannot be an issuer. Call it once: each
;; call builds its own server and throttles
(define (make-oauth-routes d fetch)
  (define cfg (deps-cfg d))
  (cond
    [(oauth-base-ok? (config-public-base-url cfg)) (build-routes d fetch)]
    [else
     (log-warning "OAuth disabled: PUBLIC_BASE_URL must be an https (or loopback http) origin without a path")
     #f]))

;; ------------------------------------------------------------------ pure helpers

;; Natural
;; the largest form body the token endpoint reads, the library's limit (64 KiB)
(define max-form-bytes (* 64 1024))

;; Request -> String
;; the client_id of a form-encoded body, "" when there is none, the body is not a form or it is over
;; the limit (then it is not even decoded)
(define (form-client-id req)
  (define body (or (request-post-data/raw req) #""))
  (if (> (bytes-length body) max-form-bytes)
      ""
      (with-handlers ([exn:fail? (λ (e) "")])
        (define v (assq 'client_id (form-urlencoded->alist (bytes->string/utf-8 body))))
        (if v (cdr v) ""))))

;; (Listof String) PendingInfo -> Void
;; 422 on `scopes` unless every name is one of the app's, none repeats and at least one was asked for
(define (check-chosen! chosen info)
  (define offered (pending-info-scopes info))
  (define (bad! why) (api-error! 422 "invalid" why "scopes"))
  (unless (andmap (λ (s) (assoc s offered)) chosen) (bad! "unknown scope"))
  (when (check-duplicates chosen) (bad! "scopes must not repeat"))
  (unless (ormap (λ (s) (cdr (assoc s offered))) chosen) (bad! "none of the scopes was requested")))



;; String -> Response
;; the 200 {redirect_to} reply: the redirect URL carries an authorization code, so it is never cached
(define (redirect-reply url)
  (json-response (hasheq 'redirect_to url) #:headers (list (make-header #"Cache-Control" #"no-store"))))

;; (Listof Header)
(define cors-headers (list (make-header #"Access-Control-Allow-Origin" #"*")))

;; Response -> Response
;; the response, readable from any origin
(define (with-cors r) (struct-copy response r [headers (append cors-headers (response-headers r))]))

;; Bytes -> Response
;; the answer to a CORS preflight for a route that serves `methods`
(define (preflight methods)
  (no-content #:headers (append cors-headers
                                (list (make-header #"Access-Control-Allow-Methods" methods)
                                      (make-header #"Access-Control-Allow-Headers" #"Content-Type, Authorization")
                                      (make-header #"Access-Control-Max-Age" #"86400")))))

;; Bytes (Request -> Response) -> (Request -> Response)
;; the handler with CORS: preflights answered, everything else readable cross-origin
(define ((cross-origin methods handler) req)
  (if (equal? (request-method req) #"OPTIONS") (preflight methods) (with-cors (handler req))))

;; (-> Response) -> Response
;; the thunk's response, or the 429 when a throttle refused it
(define (or-429 thunk)
  (with-handlers ([exn:throttled? (λ (e) (too-many-requests (exn:throttled-seconds e)))])
    (thunk)))

;; Bucket Any -> Void
;; takes a token for the key, or raises the 429
(define (take! b key)
  (define wait (bucket-take! b key))
  (when wait (throttled! wait)))

;; ------------------------------------------------------------------ routes

;; Deps (String -> Fetched) -> OAuthRoutes
;; the server over the database, its throttles and the route table that serves it
(define (build-routes d fetch)
  (define cfg (deps-cfg d))
  (define db (deps-db d))
  (define trust-proxy? (config-trust-proxy cfg))
  ;; the consent page's path and the epoch check; the metadata fetch gives its connection back first
  (define app
    (make-app (config-public-base-url cfg)
              (λ (id) (string-append "/connect/" id))
              (λ (uid epoch) (and (get-session-user db uid epoch) #t))
              (λ (url) (after-db d (λ () (fetch url))))))
  (define srv (make-oauth-server app (make-pg-oauth-store db) opaque-format))
  (define token-throttle (make-throttle))
  (define token-bucket (make-bucket 60 1))
  (define authorize-bucket (make-bucket 60 1))
  (define register-bucket (make-bucket 10 (/ 10 3600)))

  ;; Request -> String
  ;; the key rate limits count the caller under (an IPv6 caller by its /64)
  (define (caller-key req) (rate-key (client-ip req trust-proxy?)))

  ;; Request -> Response
  ;; the authorization endpoint, per-address limited
  (define (authorize req)
    (take! authorize-bucket (caller-key req))
    (handle-authorize srv req))

  ;; Request -> Response
  ;; the token endpoint: a wrong code or refresh token strikes (client_id, ip); a success forgets the pair
  (define (token req)
    (define ip (caller-key req))
    (take! token-bucket ip)
    (define client-id (form-client-id req))
    (define wait (throttle-wait token-throttle client-id ip))
    (when wait (throttled! wait))
    (define r (handle-token srv req #:on-invalid-grant (λ (cid) (throttle-fail! token-throttle cid ip))))
    (when (= (response-code r) 200) (throttle-clear! token-throttle client-id ip))
    r)

  ;; Request -> Response
  ;; dynamic client registration, limited per address; the library caps the unused clients overall
  (define (register req)
    (take! register-bucket (caller-key req))
    (handle-register srv req))

  (define-endpoint (get-request d req me id)
    (json-response (pending-info->jsexpr (or (pending-view srv id) (not-found!)) scope-descriptions)))

  (define-endpoint (approve-request d req me id)
    #:json [in (approve-input [scopes (strings 1 (length scope-descriptions) 1 20)])]
    (check-chosen! (approve-input-scopes in) (or (pending-view srv id) (not-found!)))
    (define epoch (login-token-epoch (request-login-token req cfg)))
    (redirect-reply (or (approve! srv id (user-id me) epoch (approve-input-scopes in)) (not-found!))))

  (define-endpoint (deny-request d req me id)
    (redirect-reply (or (deny! srv id) (not-found!))))

  (define-endpoint (list-grants d req me)
    (json-response (map grant-info->jsexpr (subject-grants srv (user-id me)))))

  (define-endpoint (delete-grant d req me id)
    (if (revoke! srv (user-id me) id) (no-content) (not-found!)))

  (oauth-routes srv (λ (kit fallback)
    (define named (route-kit-named kit))
    (define signed-in (route-kit-signed-in kit))
    (define (public route handler) (named route (λ (req) (or-429 (λ () (handler req))))))
    (define (discovery route handler) (named route (cross-origin #"GET, HEAD, OPTIONS" (λ (req) (handler srv req)))))
    (define-values (dispatch _url)
      (dispatch-rules
       [(".well-known" "oauth-protected-resource") #:method _ (discovery "/.well-known/oauth-protected-resource" handle-protected-resource)]
       [(".well-known" "oauth-protected-resource" "mcp") #:method _ (discovery "/.well-known/oauth-protected-resource/mcp" handle-protected-resource)]
       [(".well-known" "oauth-authorization-server") #:method _ (discovery "/.well-known/oauth-authorization-server" handle-as-metadata)]
       [("oauth" "authorize") #:method _ (public "/oauth/authorize" authorize)]
       [("oauth" "token") #:method _ (named "/oauth/token" (cross-origin #"POST, OPTIONS" (λ (req) (or-429 (λ () (token req))))))]
       [("oauth" "register") #:method _ (named "/oauth/register" (cross-origin #"POST, OPTIONS" (λ (req) (or-429 (λ () (register req))))))]
       [("api" "oauth" "requests" (string-arg)) #:method "get" (signed-in "/api/oauth/requests/:id" get-request)]
       [("api" "oauth" "requests" (string-arg) "approve") #:method "post" (signed-in "/api/oauth/requests/:id/approve" approve-request)]
       [("api" "oauth" "requests" (string-arg) "deny") #:method "post" (signed-in "/api/oauth/requests/:id/deny" deny-request)]
       [("api" "oauth" "grants") #:method "get" (signed-in "/api/oauth/grants" list-grants)]
       [("api" "oauth" "grants" (string-arg)) #:method "delete" (signed-in "/api/oauth/grants/:id" delete-grant)]
       [else fallback]))
    dispatch)))

(module+ test
  (require rackunit racket/runtime-path racket/promise net/url json)
  (define-runtime-path fixtures "../../docs/api-fixtures")
  (define (fixture name) (call-with-input-file (build-path fixtures name) read-json))
  (define (body-of r) (let ([o (open-output-bytes)]) ((response-output r) o) (get-output-bytes o)))
  (define fixture-app
    (make-app "https://orquelo.example" values (λ (u e) #t) (λ (u) (fetched 404 #f #f #""))))
  (define srv (make-oauth-server fixture-app (make-memory-store) opaque-format))
  (define (get-json handler path)
    (bytes->jsexpr (body-of (handler srv (make-request #"GET" (string->url path) '() (delay '()) #f "127.0.0.1" 80 "127.0.0.1")))))

  (test-case "the metadata documents equal the contract fixtures"
    (check-equal? (get-json handle-protected-resource "/.well-known/oauth-protected-resource")
                  (fixture "oauth-protected-resource.json"))
    (check-equal? (get-json handle-as-metadata "/.well-known/oauth-authorization-server")
                  (fixture "oauth-authorization-server.json")))
  (test-case "oauth-base-ok?: an https or loopback origin without a path"
    (for ([ok '("https://orquelo.example" "https://orquelo.example:8443" "http://localhost:8080" "http://127.0.0.1:1" "http://[::1]:3")])
      (check-true (oauth-base-ok? ok) ok))
    (for ([bad '("http://orquelo.example" "https://orquelo.example/app" "https://orquelo.example/" "ftp://x.example" "")])
      (check-false (oauth-base-ok? bad) bad)))
  (test-case "scopes chosen at consent"
    (define info (pending-info "i" "App" #f #f #f "h" #f '(("decks" . #t) ("results" . #f))))
    (define (field-of chosen) (with-handlers ([exn:api? exn:api-field]) (check-chosen! chosen info) #f))
    (check-false (field-of '("decks")))
    (check-false (field-of '("decks" "results")))
    (for ([bad '(("results") ("nope") ("decks" "decks") ("decks" "nope"))])
      (check-equal? (field-of bad) "scopes" (format "~a" bad)))))
