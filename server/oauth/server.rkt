#lang racket/base
;; The OAuth 2.1 authorization server: HTTP handlers for the metadata documents, authorization,
;; token and registration endpoints, the calls behind the app's consent page and connected-apps
;; page, and `authenticate` for the resource server. Handlers take and return web-server requests
;; and responses; routing, CORS, throttling and the consent UI belong to the app.
;;
;; Decisions: public clients only, PKCE S256 only, one resource (RFC 8707) that every token is bound
;; to, authorization codes live 60 s and work once, access tokens 1 h, refresh tokens 30 days from
;; their last use (sliding) and rotate on every use. A code or a refresh token presented a second
;; time revokes the whole grant (there is no grace window: a client that retries a refresh after a
;; lost reply loses its grant and must be authorized again). Every approval is its own grant. A
;; grant also dies with its subject's epoch (see `subject-current?`).
;;
;; Request size: the body and query caps below apply after web-server has read the request, so
;; they bound parsing work, not memory. The app must cap the size of requests upstream.
(require racket/contract/base racket/match racket/list racket/string json net/uri-codec net/url
         web-server/http
         "data.rkt" "store.rkt" "token-format.rkt" "base64url.rkt" "pkce.rkt" "uri.rkt" "cimd.rkt"
         "dcr.rkt" "metadata.rkt")
(provide (contract-out
          [oauth-server? (-> any/c boolean?)]
          [make-oauth-server (-> oauth-app? oauth-store? token-format? oauth-server?)]
          [handle-protected-resource (-> oauth-server? request? response?)]
          [handle-as-metadata (-> oauth-server? request? response?)]
          [handle-authorize (-> oauth-server? request? response?)]
          [handle-token (->* (oauth-server? request?) (#:on-invalid-grant (-> string? any)) response?)]
          [handle-register (-> oauth-server? request? response?)]
          [pending-view (-> oauth-server? string? (or/c pending-info? #f))]
          [approve! (-> oauth-server? string? any/c exact-nonnegative-integer? (listof string?) (or/c string? #f))]
          [deny! (-> oauth-server? string? (or/c string? #f))]
          [subject-grants (-> oauth-server? any/c (listof grant-info?))]
          [revoke! (-> oauth-server? any/c string? boolean?)]
          [authenticate (-> oauth-server? request? (or/c principal? response?))]
          [www-authenticate (->* (oauth-server?) (#:error (or/c string? #f) #:scope (or/c string? #f)) header?)]
          [insufficient-scope-challenge (-> oauth-server? string? response?)]
          [maybe-sweep! (-> oauth-server? void?)]
          [sweep! (-> oauth-server? void?)]))

(define pending-ttl (* 10 60))
(define code-ttl 60)
(define access-ttl (* 60 60))
(define refresh-ttl (* 30 24 60 60))
(define sweep-interval (* 10 60))
(define touch-interval (* 5 60))
(define max-param-length 4096)
(define max-query-length 8192)
(define max-form-bytes (* 64 1024))
(define max-registration-bytes (* 16 1024))
(define max-state-length 1024)

;; An OAuthServer is an (oauth-server OAuthApp OAuthStore TokenFormat NegativeCache Semaphore (Boxof (or Real #f)))
;; the app, its store, the format of access and refresh tokens, the cache of failed metadata
;; fetches, and the lock and time of the last sweep
(struct oauth-server (app store format negatives sweep-lock last-sweep))

;; OAuthApp OAuthStore TokenFormat -> OAuthServer
;; raises exn:fail:contract when the app's issuer or resource is not an acceptable URL
(define (make-oauth-server app store format)
  (oauth-server (validate-app! app) store format (make-negative-cache) (make-semaphore 1) (box #f)))

;; OAuthServer -> Integer
(define (now-of srv) ((oauth-app-clock (oauth-server-app srv))))

;; ---------------------------------------------------------------------------------------------
;; Responses

;; Natural -> Bytes
(define (reason status)
  (case status
    [(200) #"OK"] [(201) #"Created"] [(302) #"Found"] [(400) #"Bad Request"] [(401) #"Unauthorized"]
    [(403) #"Forbidden"] [(404) #"Not Found"] [(405) #"Method Not Allowed"] [(413) #"Payload Too Large"]
    [else #"Error"]))

(define no-store (list (make-header #"Cache-Control" #"no-store") (make-header #"Pragma" #"no-cache")))

;; Natural (listof Header) (or Bytes #f) Bytes -> Response
(define (http-response status headers mime body)
  (response/full status (reason status) (current-seconds) mime headers (list body)))

;; Natural JSExpr [(listof Header)] -> Response
(define (json-response status body [headers no-store])
  (http-response status headers #"application/json; charset=utf-8" (jsexpr->bytes body)))

;; OAuthError -> Response
;; the RFC 6749 error reply
(define (error-response e)
  (json-response (oauth-error-status e)
                 (hasheq 'error (oauth-error-code e) 'error_description (oauth-error-description e))))

;; Natural String -> Response
;; the page for an authorization request we cannot safely redirect back to; `message` is fixed text
(define (error-page status message)
  (http-response status
                 (cons (make-header #"Content-Security-Policy" #"default-src 'none'") no-store)
                 #"text/html; charset=utf-8"
                 (string->bytes/utf-8
                  (format "<!doctype html><meta charset=utf-8><title>Authorization error</title><p>~a</p>" message))))

;; (listof Symbol) -> Response
(define (method-not-allowed allow)
  (http-response 405 (list (make-header #"Allow" (string->bytes/utf-8 allow))) #"text/plain" #"method not allowed"))

;; ---------------------------------------------------------------------------------------------
;; Request parsing

;; Request String -> (or String #f)
(define (request-header req name)
  (define h (headers-assq* (string->bytes/utf-8 name) (request-headers/raw req)))
  (and h (bytes->string/utf-8 (header-value h) #\?)))

;; (listof (cons Symbol (or String #f))) -> (or (Hash String String) #f)
;; the parameters, or #f when one repeats or is too long (every parameter here is single-valued)
(define (alist->params alist)
  (define pairs (for/list ([kv (in-list alist)]) (cons (symbol->string (car kv)) (or (cdr kv) ""))))
  (and (not (check-duplicates (map car pairs)))
       (andmap (λ (kv) (<= (string-length (cdr kv)) max-param-length)) pairs)
       (make-immutable-hash pairs)))

;; Request -> (or (Hash String String) #f)
(define (query-params req)
  (define q (url-query (request-uri req)))
  (and (<= (for/sum ([kv (in-list q)]) (+ (string-length (symbol->string (car kv))) (string-length (or (cdr kv) "")))) max-query-length)
       (alist->params q)))

;; Request Natural -> (or (Hash String String) #f)
;; the form-encoded body, #f when it is not a form, too large or malformed
(define (form-params req limit)
  (define body (or (request-post-data/raw req) #""))
  (define type (request-header req "Content-Type"))
  (and (<= (bytes-length body) limit)
       type (regexp-match? #px"^\\s*(?i:application/x-www-form-urlencoded)\\s*(;|$)" type)
       (with-handlers ([exn:fail? (λ (e) #f)])
         (alist->params (form-urlencoded->alist (bytes->string/utf-8 body))))))

;; ---------------------------------------------------------------------------------------------
;; Metadata

;; OAuthServer Request (-> JSExpr) -> Response
(define (metadata-response req document)
  (match (request-method req)
    [(or #"GET" #"HEAD") (json-response 200 (document) (list (make-header #"Cache-Control" #"public, max-age=300")))]
    [_ (method-not-allowed "GET, HEAD")]))

(define (handle-protected-resource srv req)
  (metadata-response req (λ () (protected-resource-metadata (oauth-server-app srv)))))

(define (handle-as-metadata srv req)
  (metadata-response req (λ () (authorization-server-metadata (oauth-server-app srv)))))

;; ---------------------------------------------------------------------------------------------
;; Authorization endpoint

;; String -> Nothing
;; stops the current request with an OAuth error
(define (fail! code description [status 400])
  (raise (oauth-error code description status)))

;; OAuthServer Request -> Response
;; validates an authorization request. Every fault, whoever's it is, gets an error page and no
;; redirect: nothing the client sent has been confirmed by the user yet, so an error redirect
;; would only let a hostile client bounce the user around with a message of its choosing. Only a
;; refusal by the user (`deny!`) goes back to the client. A good request is parked as a pending
;; request and the user sent to the app's consent page.
(define (handle-authorize srv req)
  (maybe-sweep! srv)
  (cond
    [(not (equal? (request-method req) #"GET")) (method-not-allowed "GET")]
    [else
     (define p (query-params req))
     (with-handlers ([oauth-error? (λ (e) (error-page 400 (oauth-error-description e)))])
       (unless p (fail! "invalid_request" "The authorization request is malformed."))
       (define-values (c redirect-uri explicit?) (check-client srv p))
       (define-values (scopes challenge resource) (check-request srv p))
       (define id ((token-format-mint opaque-format)))
       (store-pending-put! (oauth-server-store srv)
                           (pending (hash-token id) (client-id c) redirect-uri explicit? scopes
                                    (hash-ref p "state" #f) challenge resource
                                    (+ (now-of srv) pending-ttl)))
       (http-response 302 (list (make-header #"Location" (string->bytes/utf-8 ((oauth-app-consent-path (oauth-server-app srv)) id)))
                                (make-header #"Referrer-Policy" #"no-referrer"))
                      #f #""))]))

;; OAuthServer Params -> (values Client String Boolean)
;; the client, the redirect URI to use and whether the request named it; or an OAuthError whose
;; description is fixed text for the error page
(define (check-client srv p)
  (define id (hash-ref p "client_id" #f))
  (define c (and id (resolve-client (oauth-server-app srv) (oauth-server-store srv) (oauth-server-negatives srv) id)))
  (unless c (fail! "invalid_request" "The client is unknown or its metadata could not be fetched."))
  (define requested (hash-ref p "redirect_uri" #f))
  (define registered (client-redirect-uris c))
  (define uri
    (cond [requested (and (valid-redirect-uri? requested)
                          (ormap (λ (r) (redirect-matches? r requested)) registered)
                          requested)]
          [(= (length registered) 1) (car registered)]
          [else #f]))
  (unless uri (fail! "invalid_request" "The redirect URI does not match the client's registration."))
  (values c uri (and requested #t)))

;; OAuthServer Params -> (values (listof String) String String)
;; scopes, S256 challenge and resource of a request, or an OAuthError (fixed text) for the error page
(define (check-request srv p)
  (define app (oauth-server-app srv))
  (unless (equal? (hash-ref p "response_type" #f) "code")
    (fail! "unsupported_response_type" "The request must ask for response_type code."))
  (unless (<= (string-length (hash-ref p "state" "")) max-state-length)
    (fail! "invalid_request" "The state parameter is too long."))
  (define challenge (hash-ref p "code_challenge" #f))
  (unless (s256-challenge? challenge)
    (fail! "invalid_request" "The request needs a PKCE code_challenge."))
  (unless (equal? (hash-ref p "code_challenge_method" #f) "S256")
    (fail! "invalid_request" "The code_challenge_method must be S256."))
  (define resource (hash-ref p "resource" (oauth-app-resource app)))
  (unless (equal? resource (oauth-app-resource app))
    (fail! "invalid_target" "The resource is not served by this authorization server."))
  (values (requested-scopes app (hash-ref p "scope" "")) challenge resource))

;; OAuthApp String -> (listof String)
;; the scopes asked for (all of the app's when none), in the app's order
(define (requested-scopes app text)
  (define names (string-split text))
  (define known (map car (oauth-app-scopes app)))
  (unless (andmap (λ (n) (member n known)) names)
    (fail! "invalid_scope" "The request asks for an unknown scope."))
  (if (null? names) known (filter (λ (k) (member k names)) known)))

;; (or String #f) -> (listof (cons Symbol String))
(define (state-param state)
  (if (and state (<= (string-length state) max-state-length)) (list (cons 'state state)) '()))

;; String (listof (cons Symbol String)) -> String
;; the redirect URI with the parameters added to its query
(define (with-query uri params)
  (string-append uri (if (regexp-match? #rx"[?]" uri) "&" "?") (alist->form-urlencoded params)))

;; OAuthServer String (listof (cons Symbol String)) -> String
;; the redirect URI carrying the parameters and `iss` (RFC 9207)
(define (authorization-response-url srv uri params)
  (with-query uri (append params (list (cons 'iss (oauth-app-issuer (oauth-server-app srv)))))))

;; ---------------------------------------------------------------------------------------------
;; Consent calls

;; Client -> (or String #f)
;; the host the client's identity rests on: the host of a metadata-document client_id, else #f
(define (client-host-of c)
  (and (eq? (client-kind c) 'metadata-document) (car (cimd-url-parts (client-id c)))))

;; OAuthServer String -> (or PendingInfo #f)
;; what the consent page shows for a pending request; #f when it is unknown, used or expired.
;; Only `client-host` is verified; the name is the client's own claim.
(define (pending-view srv id)
  (define store (oauth-server-store srv))
  (define p (store-pending-ref store (hash-token id) (now-of srv)))
  (define c (and p (store-client-ref store (pending-client-id p))))
  (and c
       (let* ([host (client-host-of c)]
              [shown (redirect-host (pending-redirect-uri p))]
              [shown-name (regexp-replace #px":[0-9]+$" shown "")])
         (pending-info id (client-name c) host (client-uri c) (and host #t) shown
                       (and host (not (equal? host shown-name)))
                       (for/list ([s (in-list (oauth-app-scopes (oauth-server-app srv)))])
                         (cons (car s) (and (member (car s) (pending-scopes p)) #t)))))))

;; OAuthServer String Subject Natural (listof String) -> (or String #f)
;; the user approves with the scopes they chose (those not asked for are dropped): the URL to send
;; them to, carrying the code, the client's state and `iss`. Each approval creates a new grant.
;; #f when the request is gone or no scope is left; the request is then left alone.
(define (approve! srv id subject epoch chosen)
  (define store (oauth-server-store srv))
  (define now (now-of srv))
  (define h (hash-token id))
  (store-atomically
   store
   (λ ()
     (define asked (store-pending-ref store h now))
     (define scopes (if asked (filter (λ (s) (member s chosen)) (pending-scopes asked)) '()))
     (define p (and (pair? scopes) (store-pending-take! store h now)))
     (and p
          (let* ([g (store-grant-create! store subject (pending-client-id p) scopes epoch now)]
                 [code ((token-format-mint opaque-format))])
            (store-code-put! store (code-record (hash-token code) (grant-id g) (pending-redirect-uri p)
                                                (pending-explicit-redirect? p)
                                                (pending-challenge p) (pending-resource p) scopes (+ now code-ttl)))
            (authorization-response-url srv (pending-redirect-uri p)
                                        (cons (cons 'code code) (state-param (pending-state p)))))))))

;; OAuthServer String -> (or String #f)
;; the user refuses: the URL to send them to, carrying error=access_denied; #f when the request is gone
(define (deny! srv id)
  (define p (store-pending-take! (oauth-server-store srv) (hash-token id) (now-of srv)))
  (and p (authorization-response-url srv (pending-redirect-uri p)
                                     (cons (cons 'error "access_denied") (state-param (pending-state p))))))

;; OAuthServer Subject -> (listof GrantInfo)
;; the subject's connected apps, newest first, one per approval. A grant that was never used
;; (`last-used` is set when its first tokens are issued) is not an app yet and is not listed.
(define (subject-grants srv subject)
  (define app (oauth-server-app srv))
  (define store (oauth-server-store srv))
  (for/list ([g (in-list (sort (filter grant-last-used (store-grants-of store subject)) > #:key grant-created))])
    (define c (store-client-ref store (grant-client-id g)))
    (define host (and c (client-host-of c)))
    (grant-info (grant-id g) (if c (client-name c) (grant-client-id g)) host (and c (client-uri c))
                (and host #t) (grant-scopes g) (grant-created g) (grant-last-used g)
                ((oauth-app-subject-current? app) (grant-subject g) (grant-epoch g)))))

;; OAuthServer Subject String -> Boolean
;; disconnects one approval: deletes the grant and with it every token; #f when the subject has no such grant
(define (revoke! srv subject id)
  (store-grant-delete! (oauth-server-store srv) subject id))

;; ---------------------------------------------------------------------------------------------
;; Token endpoint

;; OAuthServer Request #:on-invalid-grant (String -> Any) -> Response
;; the token endpoint. `on-invalid-grant` is told the client_id of each invalid_grant answer, so
;; the app can throttle guessing.
(define (handle-token srv req #:on-invalid-grant [on-invalid-grant void])
  (maybe-sweep! srv)
  (cond
    [(not (equal? (request-method req) #"POST")) (method-not-allowed "POST")]
    [else
     (define p (form-params req max-form-bytes))
     (with-handlers ([oauth-error?
                      (λ (e)
                        (when (equal? (oauth-error-code e) "invalid_grant")
                          (on-invalid-grant (hash-ref (or p (hasheq)) "client_id" "")))
                        (error-response e))])
       (unless p (fail! "invalid_request" "the body must be a form-encoded request of at most 64 KiB"))
       (json-response 200
                      (match (hash-ref p "grant_type" #f)
                        ["authorization_code" (exchange-code srv p)]
                        ["refresh_token" (exchange-refresh srv p)]
                        [_ (fail! "unsupported_grant_type" "grant_type must be authorization_code or refresh_token")])))]))

;; Params String -> String
(define (need p key)
  (define v (hash-ref p key #f))
  (if (and v (not (string=? v ""))) v (fail! "invalid_request" (format "~a is required" key))))

;; OAuthServer Params -> Void
;; a resource parameter, when there is one, must name the app's resource
(define (check-resource! srv p)
  (define r (hash-ref p "resource" #f))
  (unless (or (not r) (equal? r (oauth-app-resource (oauth-server-app srv))))
    (fail! "invalid_target" "resource is not served by this authorization server")))

;; OAuthServer String -> Void
;; deletes a grant by id, whoever it belongs to
(define (revoke-grant! srv gid)
  (define store (oauth-server-store srv))
  (define g (store-grant-ref store gid))
  (when g (store-grant-delete! store (grant-subject g) gid)))

;; -> Nothing
(define (invalid-grant! [why "the grant is invalid, expired or revoked"])
  (fail! "invalid_grant" why))

;; OAuthServer Params -> JSExpr
;; authorization_code grant: a code, its redirect URI and PKCE verifier become an access token and,
;; for a client that may hold one, a refresh token.
;;
;; A code is spent on first use, success or not. Replaying a code whose first use succeeded revokes
;; its grant (RFC 6749 section 4.1.2). When the first use fails (wrong verifier, wrong client, ...)
;; the grant, which has no tokens yet, is deleted instead: the code is burned and the approval gone.
;; Replaying such a code then revokes nothing, so a party that only ever saw a code cannot use it
;; to take down a working grant.
(define (exchange-code srv p)
  (define store (oauth-server-store srv))
  (define app (oauth-server-app srv))
  (define now (now-of srv))
  (define client-id* (need p "client_id"))
  (define code (need p "code"))
  (define verifier (need p "code_verifier"))
  (check-resource! srv p)
  (define key ((token-format-key opaque-format) code))
  (define rec (and key (store-code-consume! store (hash-token key) now)))
  (when (reused? rec) (revoke-grant! srv (reused-grant-id rec)) (invalid-grant! "the code was already used"))
  (unless rec (invalid-grant!))
  (define g (store-grant-ref store (code-record-grant-id rec)))
  (define c (and g (store-client-ref store (grant-client-id g))))
  (define given-redirect (hash-ref p "redirect_uri" #f))
  (unless (and g c
               (equal? (grant-client-id g) client-id*)
               (if (code-record-explicit-redirect? rec)
                   (equal? given-redirect (code-record-redirect-uri rec))
                   (or (not given-redirect) (equal? given-redirect (code-record-redirect-uri rec))))
               (s256-matches? verifier (code-record-challenge rec))
               ((oauth-app-subject-current? app) (grant-subject g) (grant-epoch g)))
    (when g (store-grant-delete! store (grant-subject g) (grant-id g)))
    (invalid-grant!))
  (define-values (access-token access-hash) (mint-token srv))
  (define-values (refresh-token refresh-hash) (if (client-refresh? c) (mint-token srv) (values #f #f)))
  (define scopes (code-record-scopes rec))
  (define resource (code-record-resource rec))
  (store-atomically
   store
   (λ ()
     (unless (and (store-token-put! store (token-record access-hash (grant-id g) 'access scopes resource (+ now access-ttl)))
                  (or (not refresh-token)
                      (store-token-put! store (token-record refresh-hash (grant-id g) 'refresh scopes resource (+ now refresh-ttl)))))
       (invalid-grant!))
     (store-grant-touch! store (grant-id g) now)))
  (token-response access-token refresh-token scopes))

;; OAuthServer Params -> JSExpr
;; refresh_token grant: a live refresh token is exchanged for a new pair (the old one is retired
;; and its lifetime starts over). Presenting a retired one revokes the grant. A `scope` parameter
;; is ignored: the new tokens carry the scopes of the old.
;; The app's hooks run here, before the store is asked to rotate, so the store never calls back
;; into the app.
(define (exchange-refresh srv p)
  (define store (oauth-server-store srv))
  (define app (oauth-server-app srv))
  (define now (now-of srv))
  (define client-id* (need p "client_id"))
  (define presented (need p "refresh_token"))
  (check-resource! srv p)
  (define key ((token-format-key (oauth-server-format srv)) presented))
  (define found (and key (store-refresh-ref store (hash-token key) now)))
  (match found
    [(reused gid) (revoke-grant! srv gid) (invalid-grant! "the refresh token was already used")]
    [#f (invalid-grant!)]
    [(cons old g)
     (unless (and (equal? (grant-client-id g) client-id*)
                  ((oauth-app-subject-current? app) (grant-subject g) (grant-epoch g)))
       (invalid-grant!))
     (define-values (access-token access-hash) (mint-token srv))
     (define-values (refresh-token refresh-hash) (mint-token srv))
     (define scopes (token-record-scopes old))
     (define resource (token-record-resource old))
     (match (store-refresh-rotate!
             store (token-record-hash old) now (grant-id g)
             (list (token-record refresh-hash (grant-id g) 'refresh scopes resource (+ now refresh-ttl))
                   (token-record access-hash (grant-id g) 'access scopes resource (+ now access-ttl))))
       [(? grant?) (token-response access-token refresh-token scopes)]
       [(reused gid) (revoke-grant! srv gid) (invalid-grant! "the refresh token was already used")]
       [#f (invalid-grant!)])]))

;; OAuthServer -> (values String Bytes)
;; a new token of the server's format and the hash it is stored under
(define (mint-token srv)
  (define fmt (oauth-server-format srv))
  (define token ((token-format-mint fmt)))
  (values token (hash-token (or ((token-format-key fmt) token) (error 'oauth "the token format mints tokens it cannot key")))))

;; String (or String #f) (listof String) -> JSExpr
(define (token-response access refresh scopes)
  (define base (hasheq 'access_token access 'token_type "Bearer" 'expires_in access-ttl
                       'scope (string-join scopes " ")))
  (if refresh (hash-set base 'refresh_token refresh) base))

;; ---------------------------------------------------------------------------------------------
;; Registration endpoint

;; OAuthServer Request -> Response
;; RFC 7591 dynamic client registration
(define (handle-register srv req)
  (cond
    [(not (equal? (request-method req) #"POST")) (method-not-allowed "POST")]
    [else
     (define body (or (request-post-data/raw req) #""))
     (define doc
       (and (<= (bytes-length body) max-registration-bytes)
            (with-handlers ([exn:fail? (λ (e) #f)]) (bytes->jsexpr body))))
     (define now (now-of srv))
     (match (and doc (register doc now))
       [(? client? c)
        (store-client-put! (oauth-server-store srv) c)
        (json-response 201 (client->registration-jsexpr c now))]
       [(? oauth-error? e) (error-response e)]
       [#f (error-response (oauth-error "invalid_client_metadata" "the body must be a JSON object of at most 16 KiB" 400))])]))

;; ---------------------------------------------------------------------------------------------
;; Resource server side

;; OAuthServer [#:error (or String #f)] [#:scope (or String #f)] -> Header
;; the WWW-Authenticate challenge (RFC 6750, with the RFC 9728 pointer to the resource metadata)
(define (www-authenticate srv #:error [error #f] #:scope [scope #f])
  (define fields
    (append (list (format "resource_metadata=~s" (protected-resource-metadata-url (oauth-server-app srv))))
            (if error (list (format "error=~s" error)) '())
            (if scope (list (format "scope=~s" scope)) '())))
  (make-header #"WWW-Authenticate" (string->bytes/utf-8 (string-append "Bearer " (string-join fields ", ")))))

;; OAuthServer Request -> (or Principal Response)
;; who the request's bearer token speaks for, or the 401 to send: with no error when no token was
;; presented, with error="invalid_token" when it is unknown, expired, revoked, for another resource
;; or its subject's epoch has moved on
(define (authenticate srv req)
  (define auth (request-header req "Authorization"))
  (match (and auth (regexp-match #px"^(?i:bearer)(?:\\s+(.*))?$" auth))
    [#f (challenge srv 401 #f)]
    [(list _ token)
     (or (and token (regexp-match? #px"^[!-~]+$" token) (principal-of srv token))
         (challenge srv 401 "invalid_token"))]))

;; OAuthServer Natural (or String #f) -> Response
(define (challenge srv status error)
  (http-response status (cons (www-authenticate srv #:error error) no-store) #f #""))

;; OAuthServer String -> Response
;; the 403 for a valid token that lacks `scope`
(define (insufficient-scope-challenge srv scope)
  (http-response 403 (cons (www-authenticate srv #:error "insufficient_scope" #:scope scope) no-store) #f #""))

;; OAuthServer String -> (or Principal #f)
(define (principal-of srv token)
  (define store (oauth-server-store srv))
  (define app (oauth-server-app srv))
  (define now (now-of srv))
  (define key ((token-format-key (oauth-server-format srv)) token))
  (match (and key (store-access-ref store (hash-token key) now))
    [(cons rec g)
     #:when (and (equal? (token-record-resource rec) (oauth-app-resource app))
                 ((oauth-app-subject-current? app) (grant-subject g) (grant-epoch g)))
     (when (or (not (grant-last-used g)) (> (- now (grant-last-used g)) touch-interval))
       (store-grant-touch! store (grant-id g) now))
     (principal (grant-subject g) (grant-id g) (grant-client-id g) (token-record-scopes rec))]
    [_ #f]))

;; ---------------------------------------------------------------------------------------------
;; Housekeeping

;; OAuthServer -> Void
;; deletes expired state now
(define (sweep! srv)
  (define now (now-of srv))
  (store-sweep! (oauth-server-store srv) now)
  (negative-cache-sweep! (oauth-server-negatives srv) now))

;; OAuthServer -> Void
;; `sweep!` when the last one was over ten minutes ago; at most one thread sweeps at a time and the
;; others carry on. A failing sweep is logged, not raised: the request in hand is not at fault.
(define (maybe-sweep! srv)
  (define lock (oauth-server-sweep-lock srv))
  (when (semaphore-try-wait? lock)
    (dynamic-wind
     void
     (λ ()
       (define now (now-of srv))
       (define last (unbox (oauth-server-last-sweep srv)))
       (when (or (not last) (>= (- now last) sweep-interval))
         (set-box! (oauth-server-last-sweep srv) now)
         (with-handlers ([exn:fail? (λ (e) (log-error "oauth: sweep failed: ~a" (exn-message e)))])
           (sweep! srv))))
     (λ () (semaphore-post lock)))))

(module+ test
  (require rackunit racket/promise racket/port)

  ;; the stage: a stub document server, a settable clock, subjects whose epoch can move on
  (define now (box 1000))
  (define epochs (make-hash))
  (define documents (make-hash))
  (define fetch-count (box 0))
  (define app-id "https://app.example/client.json")
  (define spoof-id "https://evil.example/claude.json")
  (define issuer "https://orq.example")
  (define resource "https://orq.example/mcp")
  (define redirect "https://app.example/cb")
  (define verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  (define challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

  (define (fetch-document url)
    (set-box! fetch-count (add1 (unbox fetch-count)))
    (define d (hash-ref documents url #f))
    (if d (fetched 200 "application/json" "max-age=600" (jsexpr->bytes d)) (fetched 404 #f #f #"")))
  (define app (oauth-app issuer resource '(("decks" . "Manage decks") ("results" . "Read results"))
                         (λ (id) (string-append "/connect/" id))
                         (λ (subject epoch) (= epoch (hash-ref epochs subject 0)))
                         fetch-document (λ () (unbox now))))

  ;; -> (values OAuthServer OAuthStore)
  (define (stage!)
    (set-box! now 1000)
    (hash-clear! epochs)
    (hash-clear! documents)
    (hash-set! documents app-id (hasheq 'client_id app-id 'client_name "Fine App" 'client_uri "https://app.example"
                                        'redirect_uris (list redirect "http://127.0.0.1/cb")))
    (hash-set! documents spoof-id (hasheq 'client_id spoof-id 'client_name "Claude" 'client_uri "https://claude.ai"
                                          'logo_uri "https://claude.ai/logo.png"
                                          'redirect_uris '("https://claude.ai/api/mcp/auth_callback")))
    (define store (make-memory-store))
    (values (make-oauth-server app store opaque-format) store))

  (define (make-req method url [body #""] [headers '()])
    (make-request method (string->url url)
                  (for/list ([h headers]) (make-header (string->bytes/utf-8 (car h)) (string->bytes/utf-8 (cdr h))))
                  (delay '()) body "127.0.0.1" 80 "127.0.0.1"))
  (define (form alist) (string->bytes/utf-8 (alist->form-urlencoded alist)))
  (define (post-form srv alist #:handler [handler handle-token] #:type [type "application/x-www-form-urlencoded"])
    (handler srv (make-req #"POST" "/oauth/token" (form alist) (list (cons "Content-Type" type)))))
  (define (body-of r) (let ([o (open-output-bytes)]) ((response-output r) o) (get-output-bytes o)))
  (define (json-of r) (bytes->jsexpr (body-of r)))
  (define (header-of r name) (let ([h (headers-assq* (string->bytes/utf-8 name) (response-headers r))]) (and h (bytes->string/utf-8 (header-value h)))))
  (define (query-of url-string)
    (for/hash ([kv (url-query (string->url url-string))]) (values (symbol->string (car kv)) (cdr kv))))

  (define (authorize-params . overrides)
    (define base (hash "response_type" "code" "client_id" app-id "redirect_uri" redirect "state" "xyz"
                       "code_challenge" challenge "code_challenge_method" "S256"
                       "scope" "decks results" "resource" resource))
    (for/fold ([h base]) ([kv (in-slice 2 overrides)])
      (if (cadr kv) (hash-set h (car kv) (cadr kv)) (hash-remove h (car kv)))))
  (define (in-slice n lst) (for/list ([i (in-range 0 (length lst) n)]) (take (drop lst i) n)))
  (define (opaque-token) ((token-format-mint opaque-format)))
  (define (authorize srv . overrides)
    (define h (apply authorize-params overrides))
    (handle-authorize srv (make-req #"GET" (string-append "/oauth/authorize?" (alist->form-urlencoded (for/list ([(k v) h]) (cons (string->symbol k) v)))))))
  ;; the pending id from the Location of a successful authorize response
  (define (pending-id r) (last (string-split (header-of r "Location") "/")))
  (define (code-of-url u) (hash-ref (query-of u) "code"))

  ;; runs authorize, approve and the code exchange; the token response JSON
  (define (connect! srv #:subject [subject 7] #:scopes [chosen '("decks" "results")])
    (define id (pending-id (authorize srv)))
    (define url (approve! srv id subject (hash-ref epochs subject 0) chosen))
    (json-of (code-exchange srv (code-of-url url))))
  (define (code-exchange srv code #:verifier [v verifier] #:redirect [r redirect] #:client [c app-id])
    (post-form srv (append (list (cons 'grant_type "authorization_code") (cons 'code code) (cons 'code_verifier v)
                                 (cons 'client_id c))
                           (if r (list (cons 'redirect_uri r)) '()))))
  (define (refresh-with srv token #:client [c app-id])
    (post-form srv (list (cons 'grant_type "refresh_token") (cons 'refresh_token token) (cons 'client_id c))))
  (define (bearer token) (make-req #"POST" "/mcp" #"" (list (cons "Authorization" (string-append "Bearer " token)))))
  (define (authenticate-with srv token) (authenticate srv (bearer token)))
  (define (error-of r) (hash-ref (json-of r) 'error))

  (test-case "metadata documents are served as JSON, GET only"
    (define-values (srv store) (stage!))
    (define as (handle-as-metadata srv (make-req #"GET" "/.well-known/oauth-authorization-server")))
    (check-equal? (response-code as) 200)
    (check-equal? (json-of as) (authorization-server-metadata app))
    (check-equal? (json-of (handle-protected-resource srv (make-req #"GET" "/x"))) (protected-resource-metadata app))
    (check-equal? (response-code (handle-as-metadata srv (make-req #"POST" "/x"))) 405))

  (test-case "the whole flow: authorize, consent, token, authenticate"
    (define-values (srv store) (stage!))
    (define r (authorize srv))
    (check-equal? (response-code r) 302)
    (check-regexp-match #px"^/connect/[A-Za-z0-9_-]{43}$" (header-of r "Location"))
    (define id (pending-id r))
    (define view (pending-view srv id))
    (check-equal? (pending-info-client-name view) "Fine App")
    (check-equal? (pending-info-client-host view) "app.example")
    (check-equal? (pending-info-client-uri view) "https://app.example")
    (check-true (pending-info-verified? view))
    (check-equal? (pending-info-redirect-host view) "app.example")
    (check-false (pending-info-redirect-host-differs? view))
    (check-equal? (pending-info-scopes view) '(("decks" . #t) ("results" . #t)))
    (define url (approve! srv id 7 0 '("decks" "results")))
    (define q (query-of url))
    (check-true (string-prefix? url (string-append redirect "?")))
    (check-equal? (hash-ref q "state") "xyz")
    (check-equal? (hash-ref q "iss") issuer)
    (define t (post-form srv (list (cons 'grant_type "authorization_code") (cons 'code (hash-ref q "code"))
                                   (cons 'code_verifier verifier) (cons 'redirect_uri redirect) (cons 'client_id app-id)
                                   (cons 'resource resource))))
    (check-equal? (response-code t) 200)
    (check-equal? (header-of t "Cache-Control") "no-store")
    (define j (json-of t))
    (check-equal? (hash-ref j 'token_type) "Bearer")
    (check-equal? (hash-ref j 'expires_in) 3600)
    (check-equal? (hash-ref j 'scope) "decks results")
    (match (authenticate-with srv (hash-ref j 'access_token))
      [(principal subject gid cid scopes)
       (check-equal? subject 7)
       (check-equal? cid app-id)
       (check-equal? scopes '("decks" "results"))
       (check-equal? (grant-id (store-grant-ref store gid)) gid)]
      [other (fail (format "not a principal: ~a" other))])
    (check-false (pending-view srv id) "the pending request is spent")
    (check-false (approve! srv id 7 0 '("decks"))))

  (test-case "omitted scope means all scopes and omitted resource the sole resource"
    (define-values (srv store) (stage!))
    (define r (authorize srv "scope" #f "resource" #f))
    (check-equal? (response-code r) 302)
    (check-equal? (pending-info-scopes (pending-view srv (pending-id r))) '(("decks" . #t) ("results" . #t))))

  (test-case "scopes can be narrowed at consent, never widened"
    (define-values (srv store) (stage!))
    (check-equal? (hash-ref (connect! srv #:scopes '("results")) 'scope) "results")
    (define r (authorize srv "scope" "decks"))
    (define id (pending-id r))
    (check-false (approve! srv id 7 0 '("results")) "nothing asked for is chosen")
    (check-true (pending-info? (pending-view srv id)) "the request survives")
    (define t (json-of (code-exchange srv (code-of-url (approve! srv id 7 0 '("decks" "results" "bogus"))))))
    (check-equal? (hash-ref t 'scope) "decks"))

  (test-case "invalid clients and redirect URIs get an error page, never a redirect"
    (define-values (srv store) (stage!))
    (for ([overrides (list '("client_id" #f) '("client_id" "https://nowhere.example/c.json") '("client_id" "plain")
                           '("redirect_uri" "https://evil.example/cb") '("redirect_uri" "myapp://cb")
                           '("redirect_uri" "http://127.0.0.1.evil.example/cb"))])
      (define r (apply authorize srv overrides))
      (check-equal? (response-code r) 400 (format "~a" overrides))
      (check-false (header-of r "Location"))
      (check-regexp-match #rx"^text/html" (bytes->string/utf-8 (response-mime r)))
      (check-equal? (header-of r "Content-Security-Policy") "default-src 'none'"))
    (check-equal? (response-code (handle-authorize srv (make-req #"POST" "/oauth/authorize"))) 405)
    (check-equal? (response-code (handle-authorize srv (make-req #"GET" "/oauth/authorize?a=1&a=2"))) 400))

  (test-case "every authorization fault gets an error page, never a redirect"
    (define-values (srv store) (stage!))
    (for ([overrides (list '("response_type" "token") '("response_type" #f) '("code_challenge" #f)
                           '("code_challenge" "short") '("code_challenge_method" "plain")
                           '("code_challenge_method" #f) '("scope" "decks admin")
                           '("resource" "https://other.example/mcp"))])
      (define r (apply authorize srv overrides))
      (check-equal? (response-code r) 400 (format "~a" overrides))
      (check-false (header-of r "Location") (format "~a" overrides))
      (check-regexp-match #rx"^text/html" (bytes->string/utf-8 (response-mime r)))
      (check-false (regexp-match? #rx"xyz" (body-of r)) "nothing from the request is reflected"))
    (check-equal? (response-code (authorize srv "state" (make-string 1025 #\a))) 400))

  (test-case "a redirect URI with a query keeps it"
    (define-values (srv store) (stage!))
    (hash-set! documents app-id (hasheq 'client_id app-id 'redirect_uris '("https://app.example/cb?tenant=1")))
    (define r (authorize srv "redirect_uri" "https://app.example/cb?tenant=1"))
    (define url (approve! srv (pending-id r) 7 0 '("decks")))
    (check-true (string-prefix? url "https://app.example/cb?tenant=1&code="))
    (check-equal? (hash-ref (query-of url) "tenant") "1"))

  (test-case "a loopback redirect may use any port"
    (define-values (srv store) (stage!))
    (define r (authorize srv "redirect_uri" "http://127.0.0.1:53123/cb"))
    (check-equal? (response-code r) 302)
    (define url (approve! srv (pending-id r) 7 0 '("decks")))
    (check-true (string-prefix? url "http://127.0.0.1:53123/cb?code=")))

  (test-case "the redirect URI may be omitted only when exactly one is registered"
    (define-values (srv store) (stage!))
    (check-equal? (response-code (authorize srv "redirect_uri" #f)) 400)
    (hash-set! documents app-id (hasheq 'client_id app-id 'redirect_uris (list redirect)))
    (define srv2 (make-oauth-server app (make-memory-store) opaque-format))
    (define r (authorize srv2 "redirect_uri" #f))
    (check-equal? (response-code r) 302)
    ;; the whole flow works without a redirect_uri at the token endpoint, and with the right one
    (define url (approve! srv2 (pending-id r) 7 0 '("decks")))
    (check-true (string-prefix? url (string-append redirect "?code=")))
    (check-equal? (response-code (code-exchange srv2 (code-of-url url) #:redirect #f)) 200)
    (define url2 (approve! srv2 (pending-id (authorize srv2 "redirect_uri" #f)) 7 0 '("decks")))
    (check-equal? (response-code (code-exchange srv2 (code-of-url url2))) 200)
    (define url3 (approve! srv2 (pending-id (authorize srv2 "redirect_uri" #f)) 7 0 '("decks")))
    (check-equal? (error-of (code-exchange srv2 (code-of-url url3) #:redirect "https://app.example/other")) "invalid_grant"))

  (test-case "a redirect URI named in the request must be repeated at the token endpoint"
    (define-values (srv store) (stage!))
    (define url (approve! srv (pending-id (authorize srv)) 7 0 '("decks")))
    (check-equal? (error-of (code-exchange srv (code-of-url url) #:redirect #f)) "invalid_grant"))

  (test-case "deny sends access_denied with state and iss"
    (define-values (srv store) (stage!))
    (define id (pending-id (authorize srv)))
    (define q (query-of (deny! srv id)))
    (check-equal? (hash-ref q "error") "access_denied")
    (check-equal? (hash-ref q "state") "xyz")
    (check-equal? (hash-ref q "iss") issuer)
    (check-false (deny! srv id))
    (check-false (pending-view srv id)))

  (test-case "pending requests expire after ten minutes"
    (define-values (srv store) (stage!))
    (define id (pending-id (authorize srv)))
    (set-box! now (+ 1000 599))
    (check-true (pending-info? (pending-view srv id)))
    (set-box! now (+ 1000 600))
    (check-false (pending-view srv id))
    (check-false (approve! srv id 7 0 '("decks"))))

  (test-case "dynamic registration, and its clients are labelled unverified"
    (define-values (srv store) (stage!))
    (define r (handle-register srv (make-req #"POST" "/oauth/register"
                                             (jsexpr->bytes (hasheq 'redirect_uris '("http://127.0.0.1/cb") 'client_name "Local Tool")))))
    (check-equal? (response-code r) 201)
    (check-equal? (header-of r "Cache-Control") "no-store")
    (define cid (hash-ref (json-of r) 'client_id))
    (define a (authorize srv "client_id" cid "redirect_uri" "http://127.0.0.1:4000/cb"))
    (check-equal? (response-code a) 302)
    (define view (pending-view srv (pending-id a)))
    (check-false (pending-info-verified? view))
    (check-false (pending-info-client-host view))
    (check-false (pending-info-redirect-host-differs? view))
    (check-equal? (pending-info-client-name view) "Local Tool")
    (check-equal? (pending-info-redirect-host view) "127.0.0.1")
    (for ([bad (list #"not json" (jsexpr->bytes (hasheq)) (jsexpr->bytes (hasheq 'redirect_uris '("https://a.example/cb") 'token_endpoint_auth_method "client_secret_post"))
                     (make-bytes 17000 32))])
      (define e (handle-register srv (make-req #"POST" "/oauth/register" bad)))
      (check-equal? (response-code e) 400)
      (check-true (hash-has-key? (json-of e) 'error)))
    (check-equal? (response-code (handle-register srv (make-req #"GET" "/oauth/register"))) 405))

  (test-case "refresh tokens only go to clients registered for them"
    (define-values (srv store) (stage!))
    (define (register! . kvs)
      (define r (handle-register srv (make-req #"POST" "/oauth/register"
                                               (jsexpr->bytes (apply hasheq 'redirect_uris '("https://app.example/cb") kvs)))))
      (json-of r))
    (define (tokens-for registered)
      (define cid (hash-ref registered 'client_id))
      (define url (approve! srv (pending-id (authorize srv "client_id" cid)) 7 0 '("decks")))
      (json-of (code-exchange srv (code-of-url url) #:client cid)))
    (define plain (register!))
    (check-equal? (hash-ref plain 'grant_types) '("authorization_code"))
    (check-false (hash-has-key? (tokens-for plain) 'refresh_token))
    (define both (register! 'grant_types '("authorization_code" "refresh_token")))
    (check-equal? (hash-ref both 'grant_types) '("authorization_code" "refresh_token"))
    (check-true (hash-has-key? (tokens-for both) 'refresh_token)))

  (test-case "a lookalike client is told apart by its host, not its name"
    (define-values (srv store) (stage!))
    (define r (authorize srv "client_id" spoof-id "redirect_uri" "https://claude.ai/api/mcp/auth_callback"))
    (check-equal? (response-code r) 302)
    (define view (pending-view srv (pending-id r)))
    (check-equal? (pending-info-client-name view) "Claude")
    (check-equal? (pending-info-client-host view) "evil.example")
    (check-true (pending-info-verified? view))
    (check-false (pending-info-client-uri view) "claude.ai is not the client_id's host")
    (check-equal? (pending-info-redirect-host view) "claude.ai")
    (check-true (pending-info-redirect-host-differs? view))
    (define url (approve! srv (pending-id r) 7 0 '("decks")))
    (check-true (string-prefix? url "https://claude.ai/api/mcp/auth_callback?"))
    (code-exchange srv (code-of-url url) #:client spoof-id #:redirect "https://claude.ai/api/mcp/auth_callback")
    (match (subject-grants srv 7)
      [(list info)
       (check-equal? (grant-info-client-name info) "Claude")
       (check-equal? (grant-info-client-host info) "evil.example")
       (check-false (grant-info-client-uri info))]))

  (test-case "a code works once; replaying it revokes the grant"
    (define-values (srv store) (stage!))
    (define id (pending-id (authorize srv)))
    (define code (code-of-url (approve! srv id 7 0 '("decks"))))
    (define invalid (box '()))
    (define (try) (post-form srv (list (cons 'grant_type "authorization_code") (cons 'code code) (cons 'code_verifier verifier)
                                       (cons 'redirect_uri redirect) (cons 'client_id app-id))
                             #:handler (λ (s r) (handle-token s r #:on-invalid-grant (λ (c) (set-box! invalid (cons c (unbox invalid))))))))
    (define issued (json-of (try)))
    (check-true (principal? (authenticate-with srv (hash-ref issued 'access_token))))
    (define again (try))
    (check-equal? (response-code again) 400)
    (check-equal? (error-of again) "invalid_grant")
    (check-equal? (unbox invalid) (list app-id))
    (check-true (response? (authenticate-with srv (hash-ref issued 'access_token))))
    (check-equal? (store-grants-of store 7) '()))

  (test-case "replaying a code whose first use failed revokes nothing"
    (define-values (srv store) (stage!))
    (define t (connect! srv))
    (define code (code-of-url (approve! srv (pending-id (authorize srv)) 7 0 '("decks"))))
    (check-equal? (error-of (code-exchange srv code #:verifier (make-string 43 #\a))) "invalid_grant")
    (check-equal? (length (store-grants-of store 7)) 1 "the failed approval is gone, the other grant stays")
    (check-equal? (error-of (code-exchange srv code)) "invalid_grant")
    (check-true (principal? (authenticate-with srv (hash-ref t 'access_token)))))

  (test-case "a code is bound to its verifier, redirect, client and lifetime"
    (define-values (srv store) (stage!))
    (define (fresh-code) (code-of-url (approve! srv (pending-id (authorize srv)) 7 0 '("decks"))))
    (check-equal? (error-of (code-exchange srv (fresh-code) #:verifier (make-string 43 #\a))) "invalid_grant")
    (check-equal? (error-of (code-exchange srv (fresh-code) #:redirect "https://app.example/other")) "invalid_grant")
    (check-equal? (error-of (code-exchange srv (fresh-code) #:client "https://other.example/c.json")) "invalid_grant")
    (define stale (fresh-code))
    (set-box! now (+ 1000 60))
    (check-equal? (error-of (code-exchange srv stale)) "invalid_grant")
    (check-equal? (error-of (code-exchange srv "short")) "invalid_grant")
    (check-equal? (response-code (code-exchange srv (fresh-code))) 200))

  (test-case "token endpoint request errors"
    (define-values (srv store) (stage!))
    (check-equal? (error-of (post-form srv '((grant_type . "password")))) "unsupported_grant_type")
    (check-equal? (error-of (post-form srv '())) "unsupported_grant_type")
    (check-equal? (error-of (post-form srv '((grant_type . "authorization_code")))) "invalid_request")
    (check-equal? (error-of (post-form srv '((grant_type . "refresh_token") (client_id . "x")))) "invalid_request")
    (check-equal? (error-of (post-form srv '((grant_type . "refresh_token")) #:type "application/json")) "invalid_request")
    (check-equal? (error-of (post-form srv '((grant_type . "authorization_code") (grant_type . "refresh_token")))) "invalid_request")
    (check-equal? (error-of (post-form srv (list (cons 'grant_type "authorization_code") (cons 'junk (make-string 70000 #\a))))) "invalid_request")
    (check-equal? (error-of (post-form srv (list (cons 'grant_type "authorization_code") (cons 'junk (make-string 5000 #\a))))) "invalid_request")
    (check-equal? (error-of (post-form srv '((grant_type . "authorization_code") (code . "c") (code_verifier . "v") (client_id . "x")
                                             (resource . "https://other.example/mcp"))))
                  "invalid_target")
    (check-equal? (response-code (handle-token srv (make-req #"GET" "/oauth/token"))) 405))

  (test-case "refresh rotates and slides; replaying a retired token revokes the grant"
    (define-values (srv store) (stage!))
    (define t1 (connect! srv))
    (define day (* 24 60 60))
    (set-box! now (+ 1000 (* 29 day)))
    (define t2 (json-of (refresh-with srv (hash-ref t1 'refresh_token))))
    (check-not-equal? (hash-ref t2 'refresh_token) (hash-ref t1 'refresh_token))
    (check-equal? (hash-ref t2 'scope) "decks results")
    (check-true (principal? (authenticate-with srv (hash-ref t2 'access_token))))
    ;; 31 days after the first token: past its 30 days, inside 30 days of the second
    (set-box! now (+ 1000 (* 31 day)))
    (define t3 (json-of (refresh-with srv (hash-ref t2 'refresh_token))))
    (check-true (hash-has-key? t3 'access_token))
    ;; the retired one is replayed: the grant dies, newest tokens included
    (define replay (refresh-with srv (hash-ref t2 'refresh_token)))
    (check-equal? (error-of replay) "invalid_grant")
    (check-true (response? (authenticate-with srv (hash-ref t3 'access_token))))
    (check-equal? (error-of (refresh-with srv (hash-ref t3 'refresh_token))) "invalid_grant"))

  (test-case "a refresh token expires 30 days after its last use"
    (define-values (srv store) (stage!))
    (define t1 (connect! srv))
    (set-box! now (+ 1000 (* 30 24 60 60)))
    (check-equal? (error-of (refresh-with srv (hash-ref t1 'refresh_token))) "invalid_grant"))

  (test-case "a refresh token is for its own client and does not rotate for another"
    (define-values (srv store) (stage!))
    (define t1 (connect! srv))
    (check-equal? (error-of (refresh-with srv (hash-ref t1 'refresh_token) #:client "https://other.example/c.json")) "invalid_grant")
    (check-equal? (response-code (refresh-with srv (hash-ref t1 'refresh_token))) 200)
    (check-equal? (error-of (refresh-with srv "short")) "invalid_grant")
    (check-equal? (error-of (post-form srv (list (cons 'grant_type "refresh_token") (cons 'refresh_token (hash-ref t1 'refresh_token))
                                                 (cons 'client_id app-id) (cons 'resource "https://other.example/mcp"))))
                  "invalid_target"))

  (test-case "access tokens expire after an hour"
    (define-values (srv store) (stage!))
    (define t (connect! srv))
    (set-box! now (+ 1000 3599))
    (check-true (principal? (authenticate-with srv (hash-ref t 'access_token))))
    (set-box! now (+ 1000 3600))
    (check-true (response? (authenticate-with srv (hash-ref t 'access_token)))))

  (test-case "a token for another audience is refused"
    (define-values (srv store) (stage!))
    (define t (connect! srv))
    (define g (car (store-grants-of store 7)))
    (define other (opaque-token))
    (store-token-put! store (token-record (hash-token other) (grant-id g) 'access '("decks") "https://other.example/mcp" 99999))
    (check-true (response? (authenticate-with srv other)))
    (define mine (opaque-token))
    (store-token-put! store (token-record (hash-token mine) (grant-id g) 'access '("decks") resource 99999))
    (check-true (principal? (authenticate-with srv mine))))

  (test-case "authenticate answers with WWW-Authenticate challenges"
    (define-values (srv store) (stage!))
    (define missing (authenticate srv (make-req #"POST" "/mcp")))
    (check-equal? (response-code missing) 401)
    (check-equal? (header-of missing "WWW-Authenticate")
                  "Bearer resource_metadata=\"https://orq.example/.well-known/oauth-protected-resource/mcp\"")
    (for ([h (list "Bearer " "Bearer nonsense" (string-append "Bearer " (opaque-token)) "Basic abc")])
      (define r (authenticate srv (make-req #"POST" "/mcp" #"" (list (cons "Authorization" h)))))
      (check-equal? (response-code r) 401 h)
      (check-equal? (header-of r "WWW-Authenticate")
                    (if (string-prefix? h "Basic")
                        "Bearer resource_metadata=\"https://orq.example/.well-known/oauth-protected-resource/mcp\""
                        "Bearer resource_metadata=\"https://orq.example/.well-known/oauth-protected-resource/mcp\", error=\"invalid_token\"")))
    (define scoped (insufficient-scope-challenge srv "results"))
    (check-equal? (response-code scoped) 403)
    (check-equal? (header-of scoped "WWW-Authenticate")
                  "Bearer resource_metadata=\"https://orq.example/.well-known/oauth-protected-resource/mcp\", error=\"insufficient_scope\", scope=\"results\""))

  (test-case "a subject whose epoch moved on loses every credential"
    (define-values (srv store) (stage!))
    (define t (connect! srv))
    (check-true (grant-info-current? (car (subject-grants srv 7))))
    (hash-set! epochs 7 1)
    (check-true (response? (authenticate-with srv (hash-ref t 'access_token))))
    (check-equal? (error-of (refresh-with srv (hash-ref t 'refresh_token))) "invalid_grant")
    (check-false (grant-info-current? (car (subject-grants srv 7))))
    (hash-set! epochs 7 0)
    (define id (pending-id (authorize srv)))
    (define code (code-of-url (approve! srv id 7 0 '("decks"))))
    (hash-set! epochs 7 2)
    (check-equal? (error-of (code-exchange srv code)) "invalid_grant"))

  (test-case "an approval that was never exchanged is not listed"
    (define-values (srv store) (stage!))
    (define url (approve! srv (pending-id (authorize srv)) 7 0 '("decks")))
    (check-equal? (length (store-grants-of store 7)) 1)
    (check-equal? (subject-grants srv 7) '())
    (check-equal? (response-code (code-exchange srv (code-of-url url))) 200)
    (check-equal? (length (subject-grants srv 7)) 1))

  (test-case "connected apps can be listed and revoked by their owner only"
    (define-values (srv store) (stage!))
    (define t (connect! srv))
    (match (subject-grants srv 7)
      [(list (grant-info id name host uri verified? scopes created last-used current?))
       (check-equal? name "Fine App")
       (check-equal? host "app.example")
       (check-equal? uri "https://app.example")
       (check-true verified?)
       (check-equal? scopes '("decks" "results"))
       (check-equal? created 1000)
       (check-equal? last-used 1000)
       (check-true current?)
       (check-false (revoke! srv 8 id))
       (check-true (principal? (authenticate-with srv (hash-ref t 'access_token))))
       (check-true (revoke! srv 7 id))
       (check-false (revoke! srv 7 id))])
    (check-true (response? (authenticate-with srv (hash-ref t 'access_token))))
    (check-equal? (error-of (refresh-with srv (hash-ref t 'refresh_token))) "invalid_grant")
    (check-equal? (subject-grants srv 7) '())
    (check-equal? (subject-grants srv 8) '()))

  (test-case "every approval is an independent grant"
    (define-values (srv store) (stage!))
    (define t1 (connect! srv))
    (define t2 (connect! srv #:scopes '("decks")))
    (check-equal? (length (subject-grants srv 7)) 2)
    (check-true (principal? (authenticate-with srv (hash-ref t1 'access_token))))
    (check-equal? (principal-scopes (authenticate-with srv (hash-ref t2 'access_token))) '("decks"))
    (check-not-equal? (principal-grant-id (authenticate-with srv (hash-ref t1 'access_token)))
                      (principal-grant-id (authenticate-with srv (hash-ref t2 'access_token))))
    ;; reuse on one revokes only that one
    (define id (pending-id (authorize srv)))
    (define code (code-of-url (approve! srv id 7 0 '("decks"))))
    (check-equal? (response-code (code-exchange srv code)) 200)
    (check-equal? (error-of (code-exchange srv code)) "invalid_grant")
    (check-equal? (length (subject-grants srv 7)) 2)
    (check-true (principal? (authenticate-with srv (hash-ref t1 'access_token))))
    ;; revoke! works per grant id
    (define gid (principal-grant-id (authenticate-with srv (hash-ref t2 'access_token))))
    (check-true (revoke! srv 7 gid))
    (check-true (response? (authenticate-with srv (hash-ref t2 'access_token))))
    (check-true (principal? (authenticate-with srv (hash-ref t1 'access_token))))
    (check-equal? (error-of (refresh-with srv (hash-ref t2 'refresh_token))) "invalid_grant")
    (check-equal? (response-code (refresh-with srv (hash-ref t1 'refresh_token))) 200))

  (test-case "a failed token insert (grant revoked meanwhile) is invalid_grant"
    (define-values (srv store) (stage!))
    (define code (code-of-url (approve! srv (pending-id (authorize srv)) 7 0 '("decks"))))
    (define racing
      (struct-copy oauth-store store
                   [token-put! (λ (t) (store-grant-delete! store 7 (token-record-grant-id t)) (store-token-put! store t))]))
    (define srv2 (make-oauth-server app racing opaque-format))
    (check-equal? (error-of (code-exchange srv2 code)) "invalid_grant"))

  (test-case "sweeping runs when ten minutes have passed and removes expired state"
    (define-values (srv store) (stage!))
    (define id (pending-id (authorize srv)))       ; the first call sweeps, at 1000; expires at 1600
    (check-true (pending? (store-pending-ref store (hash-token id) 0)))
    (set-box! now 1700)
    (maybe-sweep! srv)
    (check-false (store-pending-ref store (hash-token id) 0))
    (define id2 (pending-id (authorize srv)))      ; expires at 2300
    (set-box! now 2301)
    (maybe-sweep! srv)
    (check-false (store-pending-ref store (hash-token id2) 0))
    (define id3 (pending-id (authorize srv)))      ; expires at 2901
    (set-box! now 2901)
    (sweep! srv)
    (check-false (store-pending-ref store (hash-token id3) 0)))

  (test-case "maybe-sweep! leaves a recent sweep alone"
    (define-values (srv store) (stage!))
    (maybe-sweep! srv)
    (store-pending-put! store (pending #"expired" app-id redirect #t '("decks") #f challenge resource 1))
    (set-box! now 1100)
    (maybe-sweep! srv)
    (check-true (pending? (store-pending-ref store #"expired" 0)) "only 100 s since the last sweep")
    (set-box! now 1700)
    (maybe-sweep! srv)
    (check-false (store-pending-ref store #"expired" 0)))

  (test-case "a failing sweep does not fail the request"
    (define broken (struct-copy oauth-store (make-memory-store) [sweep! (λ (now) (error "disk on fire"))]))
    (define srv (make-oauth-server app broken opaque-format))
    (hash-set! documents app-id (hasheq 'client_id app-id 'redirect_uris (list redirect)))
    (parameterize ([current-logger (make-logger)])
      (check-equal? (response-code (authorize srv)) 302)))

  (test-case "metadata fetches are cached and failures remembered"
    (define-values (srv store) (stage!))
    (set-box! fetch-count 0)
    (authorize srv)
    (authorize srv)
    (check-equal? (unbox fetch-count) 1)
    (hash-remove! documents app-id)
    (set-box! now (+ 1000 600))
    (check-equal? (response-code (authorize srv)) 400)
    (check-equal? (response-code (authorize srv)) 400)
    (check-equal? (unbox fetch-count) 2)))
