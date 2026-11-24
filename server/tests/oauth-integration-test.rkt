#lang racket/base
;; The OAuth endpoints and the consent API end to end: the core edition on a random port against
;; Postgres (TEST_DATABASE_URL), the client metadata document served by a stub fetch.
(require rackunit racket/list racket/string racket/file json net/uri-codec net/url
         db "support.rkt" "../config.rkt" "../db/conn.rkt" "../main.rkt" "../edition.rkt" "../editions/core.rkt"
         "../oauth/data.rkt" "../db/accounts.rkt" "http-client.rkt")

;; ------------------------------------------------------------------ the stage
(define static-dir (make-temporary-file "orquelo-oauth-static~a" 'directory))
(define upload-dir (make-temporary-file "orquelo-oauth-up~a" 'directory))
(display-to-file "<html>spa</html>" (build-path static-dir "index.html") #:exists 'truncate)

(define client-id "https://agent.example/client.json")
(define redirect "https://agent.example/cb")
(define verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
(define challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

;; String -> Fetched
;; the metadata document of the one client the tests know; everything else is not found
(define (stub-fetch url)
  (if (equal? url client-id)
      (fetched 200 "application/json" "max-age=600"
               (jsexpr->bytes (hasheq 'client_id client-id 'client_name "Example Agent" 'client_uri "https://agent.example"
                                      'redirect_uris (list redirect)
                                      'grant_types '("authorization_code" "refresh_token"))))
      (fetched 404 #f #f #"")))

;; String -> (or (cons Natural (-> Void)) #f)
;; starts a server whose PUBLIC_BASE_URL is the loopback origin plus `suffix`
(define (try-start suffix)
  (define port (+ 20000 (random 30000)))
  (define env (hash "DATABASE_URL" (test-db-url) "PUBLIC_BASE_URL" (format "http://127.0.0.1:~a~a" port suffix)
                    "STATIC_DIR" (path->string static-dir) "UPLOAD_DIR" (path->string upload-dir)
                    "MIGRATIONS_DIR" (path->string migrations-dir)
                    "SESSION_SECRET" (make-string 40 #\s) "PORT" (number->string port)))
  (define cfg (load-config env))
  (with-handlers ([exn:fail? (λ (e) (eprintf "start failed: ~a\n" (exn-message e)) #f)])
    (cons port (start-server cfg #:plugin ((edition-configure core-edition) env cfg) #:oauth-fetch stub-fetch))))

(define (start suffix) (or (try-start suffix) (try-start suffix) (try-start suffix) (error "could not start server")))

;; ------------------------------------------------------------------ helpers
(define (code-of r) (hash-ref (resp-json r) 'error))
(define (query-of url) (for/hash ([kv (in-list (url-query (string->url url)))]) (values (car kv) (cdr kv))))

;; (Listof (Pair Symbol String)) -> String
(define (authorize-path . extra)
  (string-append "/oauth/authorize?"
                 (alist->form-urlencoded
                  (append (list (cons 'response_type "code") (cons 'client_id client-id) (cons 'redirect_uri redirect)
                                (cons 'code_challenge challenge) (cons 'code_challenge_method "S256") (cons 'state "xyz"))
                          extra))))

;; Resp -> String
;; the pending id a successful authorize redirects to
(define (pending-id r)
  (check-equal? (resp-status r) 302)
  (cadr (regexp-match #px"^/connect/([A-Za-z0-9_-]{43})$" (resp-header r "Location"))))

;; String -> String
(define (authorize! . extra) (pending-id (http "GET" (apply authorize-path extra))))

(define (approve path cookie scopes #:origin [origin (current-base)])
  (http "POST" (format "/api/oauth/requests/~a/approve" path) #:json (hasheq 'scopes scopes) #:cookies (list cookie) #:origin origin))
(define (deny path cookie) (http "POST" (format "/api/oauth/requests/~a/deny" path) #:json (hasheq) #:cookies (list cookie)))

;; String String -> Resp
(define (token-request code the-verifier #:client [cid client-id] #:redirect [redirect-uri redirect])
  (http "POST" "/oauth/token"
        #:form (list (cons 'grant_type "authorization_code") (cons 'code code) (cons 'client_id cid)
                     (cons 'redirect_uri redirect-uri) (cons 'code_verifier the-verifier))))

;; String -> Resp
(define (refresh-request token)
  (http "POST" "/oauth/token"
        #:form (list (cons 'grant_type "refresh_token") (cons 'refresh_token token) (cons 'client_id client-id))))

;; String Cookie -> String
;; the authorization code of an approved request
(define (approved-code id cookie)
  (define r (approve id cookie '("decks" "results")))
  (check-equal? (resp-status r) 200)
  (hash-ref (query-of (hash-ref (resp-json r) 'redirect_to)) 'code))

;; ------------------------------------------------------------------ tests
(module+ test
  (cond
    [(test-db-url)
     (define db (fresh-db!))
     (define main (start ""))
     (define bad-base (start "/app"))
     (dynamic-wind
      void
      (λ ()
        (parameterize ([current-base (format "http://127.0.0.1:~a" (car main))])
          (run-tests db))
        (parameterize ([current-base (format "http://127.0.0.1:~a" (car bad-base))])
          (run-disabled-tests)))
      (λ () ((cdr main)) ((cdr bad-base)) (disconnect db) (delete-directory/files static-dir) (delete-directory/files upload-dir)))]
    [else (eprintf "SKIPPED oauth-integration-test: TEST_DATABASE_URL not set (use scripts/with-ephemeral-pg)\n")]))

(define (run-disabled-tests)
  (test-case "OAuth is off when PUBLIC_BASE_URL has a path"
    (for ([p '("/.well-known/oauth-authorization-server" "/.well-known/oauth-protected-resource" "/oauth/authorize" "/oauth/register")])
      (check-equal? (resp-status (http "GET" p)) 404 p))
    (check-equal? (resp-status (http "POST" "/oauth/token" #:form '((grant_type . "x")))) 404)))

(define (run-tests db)
  (define cookie (begin (ensure-password-user! db "oauth@example.org") (login-cookie! "oauth@example.org")))
  (define other (begin (ensure-password-user! db "other@example.org") (login-cookie! "other@example.org")))
  (define base (current-base))

  (test-case "discovery documents with CORS"
    (for ([p '("/.well-known/oauth-protected-resource" "/.well-known/oauth-protected-resource/mcp")])
      (define r (http "GET" p))
      (check-equal? (resp-status r) 200)
      (check-equal? (resp-header r "Access-Control-Allow-Origin") "*")
      (check-equal? (hash-ref (resp-json r) 'resource) (string-append base "/mcp")))
    (define as (http "GET" "/.well-known/oauth-authorization-server"))
    (check-equal? (hash-ref (resp-json as) 'issuer) base)
    (check-equal? (hash-ref (resp-json as) 'token_endpoint) (string-append base "/oauth/token"))
    (check-equal? (resp-header as "Access-Control-Allow-Origin") "*")
    (for ([p '("/oauth/token" "/.well-known/oauth-authorization-server")])
      (define pre (http "OPTIONS" p #:origin "https://app.example"))
      (check-equal? (resp-status pre) 204 p)
      (check-equal? (resp-header pre "Access-Control-Allow-Origin") "*")
      (check-regexp-match #rx"Authorization" (resp-header pre "Access-Control-Allow-Headers"))))

  (test-case "authorize: a bad redirect gets an error page and no redirect; a good request goes to the consent page"
    (define bad (http "GET" (string-replace (authorize-path) (uri-encode redirect) (uri-encode "https://evil.example/cb"))))
    (check-equal? (resp-status bad) 400)
    (check-regexp-match #rx"text/html" (resp-header bad "Content-Type"))
    (check-false (resp-header bad "Location"))
    (check-equal? (resp-status (http "GET" "/oauth/authorize")) 400)
    (check-equal? (string-length (authorize!)) 43))

  (test-case "the consent request: signed-in only, in the contract's shape"
    (define id (authorize! (cons 'scope "decks")))
    (define path (string-append "/api/oauth/requests/" id))
    (check-equal? (resp-status (http "GET" path)) 401)
    (define r (http "GET" path #:cookies (list cookie)))
    (check-equal? (resp-status r) 200)
    (define j (resp-json r))
    (check-equal? (hash-ref j 'id) id)
    (check-equal? (hash-ref j 'client) (hasheq 'name "Example Agent" 'host "agent.example" 'uri "https://agent.example" 'verified #t))
    (check-equal? (hash-ref j 'redirect_host) "agent.example")
    (check-false (hash-ref j 'redirect_host_differs))
    (check-equal? (for/list ([s (hash-ref j 'scopes)]) (list (hash-ref s 'name) (hash-ref s 'requested))) '(("decks" #t) ("results" #f)))
    (check-equal? (resp-status (http "GET" "/api/oauth/requests/nope" #:cookies (list cookie))) 404)
    (test-case "approve: Origin required, scopes validated, then the request is used up"
      (check-equal? (code-of (approve id cookie '("decks") #:origin #f)) "bad_origin")
      (check-equal? (resp-status (approve id cookie '("decks") #:origin #f)) 403)
      (for ([bad '(("results") ("nope") ("decks" "decks") ())])
        (define v (approve id cookie bad))
        (check-equal? (resp-status v) 422 (format "~a" bad))
        (check-equal? (hash-ref (resp-json v) 'field) "scopes"))
      (check-equal? (resp-status (http "GET" path #:cookies (list cookie))) 200 "refusals leave the request alone")
      (check-equal? (resp-status (approve id cookie '("decks"))) 200)
      (check-equal? (resp-status (approve id cookie '("decks"))) 404)
      (check-equal? (resp-status (deny id cookie)) 404)))

  (test-case "approve, then token: code + state + iss, PKCE, access and refresh tokens; the code works once"
    (define id (authorize!))
    (define r (approve id cookie '("decks" "results")))
    (check-equal? (resp-status r) 200)
    (define to (hash-ref (resp-json r) 'redirect_to))
    (check-true (string-prefix? to (string-append redirect "?")))
    (define q (query-of to))
    (check-equal? (hash-ref q 'state) "xyz")
    (check-equal? (hash-ref q 'iss) base)
    (define t (token-request (hash-ref q 'code) verifier))
    (check-equal? (resp-status t) 200)
    (check-equal? (resp-header t "Cache-Control") "no-store")
    (define tj (resp-json t))
    (check-equal? (hash-ref tj 'token_type) "Bearer")
    (check-true (string? (hash-ref tj 'access_token)))
    (check-equal? (hash-ref tj 'scope) "decks results")
    (check-true (string? (hash-ref tj 'refresh_token)))
    (check-equal? (code-of (token-request (hash-ref q 'code) verifier)) "invalid_grant"))

  (test-case "refresh_token grant: a new pair, and the retired refresh token is refused"
    (define first-pair (resp-json (token-request (approved-code (authorize!) cookie) verifier)))
    (define old (hash-ref first-pair 'refresh_token))
    (define r (refresh-request old))
    (check-equal? (resp-status r) 200)
    (define next (resp-json r))
    (check-not-equal? (hash-ref next 'refresh_token) old)
    (check-not-equal? (hash-ref next 'access_token) (hash-ref first-pair 'access_token))
    (define reuse (refresh-request old))
    (check-equal? (resp-status reuse) 400)
    (check-equal? (code-of reuse) "invalid_grant"))

  (test-case "(client_id, ip) throttle: repeated invalid_grant answers give 429; a success clears the pair"
    (define (register!)
      (hash-ref (resp-json (http "POST" "/oauth/register" #:json (hasheq 'client_name "Throttled" 'redirect_uris '("https://dyn.example/cb")))) 'client_id))
    (define (code-for cid)
      (define id (pending-id (http "GET" (string-append "/oauth/authorize?"
                                                        (alist->form-urlencoded
                                                         `((response_type . "code") (client_id . ,cid) (redirect_uri . "https://dyn.example/cb")
                                                           (code_challenge . ,challenge) (code_challenge_method . "S256")))))))
      (hash-ref (query-of (hash-ref (resp-json (approve id cookie '("decks"))) 'redirect_to)) 'code))
    (define (bad cid) (token-request "nope" verifier #:client cid #:redirect "https://dyn.example/cb"))
    ;; four strikes stay below the threshold, a success forgets them, four more are again below it
    (define cleared (register!))
    (for ([_ 4]) (check-equal? (code-of (bad cleared)) "invalid_grant"))
    (check-equal? (resp-status (token-request (code-for cleared) verifier #:client cleared #:redirect "https://dyn.example/cb")) 200)
    (for ([_ 4]) (check-equal? (code-of (bad cleared)) "invalid_grant"))
    ;; five strikes start the back-off: the next attempt is a 429, long before the 60-token address bucket is empty
    (define struck (register!))
    (for ([_ 5]) (check-equal? (code-of (bad struck)) "invalid_grant"))
    (define r (bad struck))
    (check-equal? (resp-status r) 429)
    (check-equal? (code-of r) "throttled")
    (check-true (and (resp-header r "Retry-After") #t))
    (check-equal? (resp-status (token-request "nope" verifier #:client client-id)) 400 "another client is not affected"))

  (test-case "a password change makes the grant need a reconnect"
    (define email "reconnect@example.org")
    (define uid (ensure-password-user! db email))
    (define c1 (login-cookie! email))
    (check-equal? (resp-status (token-request (approved-code (authorize!) c1) verifier)) 200)
    (check-false (hash-ref (first (resp-json (http "GET" "/api/oauth/grants" #:cookies (list c1)))) 'needs_reconnect))
    (bump-session-epoch! db uid)
    (define c2 (login-cookie! email))
    (check-true (hash-ref (first (resp-json (http "GET" "/api/oauth/grants" #:cookies (list c2)))) 'needs_reconnect)))

  (test-case "approve after the request expired is a 404"
    (define id (authorize!))
    (query-exec db "UPDATE oauth_pending SET expires_at = 0")
    (check-equal? (resp-status (approve id cookie '("decks"))) 404))

  (test-case "a wrong PKCE verifier is invalid_grant"
    (define code (approved-code (authorize!) cookie))
    (define t (token-request code "x-wrong-verifier-wrong-verifier-wrong-verifier-0"))
    (check-equal? (resp-status t) 400)
    (check-equal? (code-of t) "invalid_grant"))

  (test-case "deny sends the user back with access_denied"
    (define r (deny (authorize!) cookie))
    (check-equal? (resp-status r) 200)
    (define q (query-of (hash-ref (resp-json r) 'redirect_to)))
    (check-equal? (hash-ref q 'error) "access_denied")
    (check-equal? (hash-ref q 'state) "xyz"))

  (test-case "dynamic registration, then an unverified client at the consent page"
    (define r (http "POST" "/oauth/register" #:json (hasheq 'client_name "Dyn App" 'redirect_uris '("https://dyn.example/cb"))))
    (check-equal? (resp-status r) 201)
    (define cid (hash-ref (resp-json r) 'client_id))
    (define id (pending-id (http "GET" (string-append "/oauth/authorize?"
                                                      (alist->form-urlencoded
                                                       `((response_type . "code") (client_id . ,cid)
                                                         (code_challenge . ,challenge) (code_challenge_method . "S256")))))))
    (define c (hash-ref (resp-json (http "GET" (string-append "/api/oauth/requests/" id) #:cookies (list cookie))) 'client))
    (check-equal? (hash-ref c 'host) 'null)
    (check-false (hash-ref c 'verified))
    (check-equal? (resp-status (http "POST" "/oauth/register" #:json (hasheq 'redirect_uris '("http://evil.example/cb")))) 400))

  (test-case "connected apps: listed once used, disconnected only by their owner"
    (define code (approved-code (authorize!) cookie))
    (define before (length (resp-json (http "GET" "/api/oauth/grants" #:cookies (list cookie)))))
    (check-equal? (resp-status (token-request code verifier)) 200)
    (define gs (resp-json (http "GET" "/api/oauth/grants" #:cookies (list cookie))))
    (check-equal? (length gs) (add1 before))
    (define g (first gs))
    (check-equal? (sort (hash-keys g) symbol<?) '(client created_at id last_used_at needs_reconnect scopes))
    (check-equal? (hash-ref g 'scopes) '("decks" "results"))
    (check-false (hash-ref g 'needs_reconnect))
    (check-regexp-match #px"^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\d\\.000Z$" (hash-ref g 'last_used_at))
    (check-equal? (resp-json (http "GET" "/api/oauth/grants" #:cookies (list other))) '())
    (define path (string-append "/api/oauth/grants/" (hash-ref g 'id)))
    (check-equal? (resp-status (http "DELETE" path #:cookies (list other))) 404)
    (check-equal? (resp-status (http "DELETE" path #:cookies (list cookie) #:origin #f)) 403)
    (check-equal? (resp-status (http "DELETE" path #:cookies (list cookie))) 204)
    (check-equal? (resp-status (http "DELETE" path #:cookies (list cookie))) 404)
    (check-equal? (resp-status (http "GET" "/api/oauth/grants")) 401))

  (test-case "/connect/<id> is the SPA, never framed and without a referrer"
    (define r (http "GET" "/connect/x"))
    (check-equal? (resp-body r) #"<html>spa</html>")
    (check-equal? (resp-header r "Content-Security-Policy") "frame-ancestors 'none'")
    (check-equal? (resp-header r "Referrer-Policy") "no-referrer")
    (check-false (resp-header (http "GET" "/login") "Content-Security-Policy")))

  (test-case "unknown OAuth and MCP paths are JSON 404s, not the SPA"
    (check-equal? (resp-status (http "GET" "/oauth/nope")) 404)
    (check-equal? (code-of (http "GET" "/mcp")) "not_found"))

  (test-case "bursts are answered with 429 and Retry-After"
    (define (burst path thunk)
      (define limited (for/first ([i 70] #:when (= 429 (resp-status (thunk)))) (thunk)))
      (check-true (and limited #t) path)
      (check-true (and (resp-header limited "Retry-After") #t) path)
      (check-equal? (code-of limited) "throttled"))
    (burst "/oauth/token" (λ () (token-request "nope" verifier #:client "https://nobody.example/c")))
    (burst "/oauth/register" (λ () (http "POST" "/oauth/register" #:json (hasheq 'redirect_uris '("https://dyn.example/cb")))))
    (burst "/oauth/authorize" (λ () (http "GET" "/oauth/authorize")))))
