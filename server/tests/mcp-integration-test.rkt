#lang racket/base
;; The /mcp endpoint end to end: the core edition on a random port against Postgres (TEST_DATABASE_URL),
;; a client connected through the OAuth flow (dynamic registration) and JSON-RPC over POST.
(require rackunit racket/list racket/string racket/file racket/hash json
         db "support.rkt" "../config.rkt" "../db/accounts.rkt" "../main.rkt" "../edition.rkt" "../editions/core.rkt"
         "../live/codes.rkt" "http-client.rkt" "oauth-client.rkt")

;; ------------------------------------------------------------------ the stage
(define static-dir (make-temporary-file "orquelo-mcp-static~a" 'directory))
(define upload-dir (make-temporary-file "orquelo-mcp-up~a" 'directory))
(display-to-file "<html>spa</html>" (build-path static-dir "index.html") #:exists 'truncate)

;; (MutableHash Id Boolean)
;; the decks the edition under test has switched off
(define disabled-decks (make-hasheqv))

;; Plugin -> Plugin
;; the plugin as a storage plugin that reports the decks in `disabled-decks` as disabled
(define (with-disabling core)
  (storage-plugin (plugin-limits core) (plugin-routes core) (λ (c id) #f)
                  (λ (c id) (hash-ref disabled-decks id #f)) (λ (c id) (void))))

;; -> (or (cons Natural (-> Void)) #f)
;; starts the server on a random port, or #f when the port was taken
(define (try-start)
  (define port (+ 20000 (random 30000)))
  (define env (hash "DATABASE_URL" (test-db-url) "PUBLIC_BASE_URL" (format "http://127.0.0.1:~a" port)
                    "STATIC_DIR" (path->string static-dir) "UPLOAD_DIR" (path->string upload-dir)
                    "MIGRATIONS_DIR" (path->string migrations-dir)
                    "SESSION_SECRET" (make-string 40 #\s) "PORT" (number->string port)))
  (define cfg (load-config env))
  (with-handlers ([exn:fail? (λ (e) (eprintf "start failed: ~a\n" (exn-message e)) #f)])
    (cons port (start-server cfg #:plugin (with-disabling ((edition-configure core-edition) env cfg))))))

(define (start) (or (try-start) (try-start) (try-start) (error "could not start server")))

;; ------------------------------------------------------------------ client
;; String -> (Listof String)
(define (bearer token) (list (string-append "Authorization: Bearer " token)))

;; String String [JSObject] -> Resp
;; one JSON-RPC request with the bearer token (legacy era: no _meta, no routing headers)
(define (rpc token method [params (hasheq)])
  (http "POST" "/mcp" #:json (hasheq 'jsonrpc "2.0" 'id 1 'method method 'params params) #:headers (bearer token)))

;; String String [JSObject] -> JSObject
;; the result of a tools/call: {content, structuredContent, isError}
(define (tool token name [args (hasheq)])
  (define r (rpc token "tools/call" (hasheq 'name name 'arguments args)))
  (check-equal? (resp-status r) 200)
  (hash-ref (resp-json r) 'result))

;; JSObject -> JSObject
;; the structured content of a tool result
(define (structured r) (hash-ref r 'structuredContent))
;; JSObject -> (or String #f)
;; the error code of a failed tool result, #f when it succeeded
(define (error-of r) (and (hash-ref r 'isError) (hash-ref (structured r) 'error)))

;; Id (or Natural 'null) [JSObject] -> JSObject
;; the arguments of create_poll for a two-option poll on `slide`, `more` overriding fields
(define (poll-args deck slide [more (hasheq)])
  (hash-union (hasheq 'deck_id deck 'slide slide 'question "Favourite?" 'kind "single"
                      'options (list (hasheq 'label "Red") (hasheq 'label "Blue")))
              more #:combine (λ (a b) b)))

;; Id (or Natural 'null) -> JSObject
;; the arguments of replace_poll
(define (replace-args poll slide) (hash-set (hash-remove (poll-args 0 slide) 'deck_id) 'poll_id poll))

(define pdf (bytes-append #"%PDF-1.4\n" (make-bytes 200 65)))

;; ------------------------------------------------------------------ tests
(module+ test
  (cond
    [(test-db-url)
     (define db (fresh-db!))
     (define s (start))
     (dynamic-wind
      void
      (λ () (parameterize ([current-base (format "http://127.0.0.1:~a" (car s))])
              (parameterize ([current-oauth-client (register-client!)]) (run-tests db))))
      (λ () ((cdr s)) (disconnect db) (delete-directory/files static-dir) (delete-directory/files upload-dir)))]
    [else (eprintf "SKIPPED mcp-integration-test: TEST_DATABASE_URL not set (use scripts/with-ephemeral-pg)\n")]))

;; Connection -> Void
;; every check of this file, against the server at `current-base`
(define (run-tests db)
  ;; String -> String
  ;; the session cookie of a password user, created when missing
  (define (user! email) (ensure-password-user! db email) (login-cookie! email))
  (define cookie (user! "owner@example.org"))
  (define bob (user! "bob@example.org"))
  (define deck (hash-ref (resp-json (upload! "Intro" "10" pdf #:cookie cookie)) 'id))
  (define t (oauth-connect! cookie '("decks" "results")))
  (define token (tokens-access t))
  (define bob-token (tokens-access (oauth-connect! bob '("decks" "results"))))

  (test-case "no token or a bad one: 401 pointing at the resource metadata"
    (define none (http "POST" "/mcp" #:json (hasheq 'jsonrpc "2.0" 'id 1 'method "ping")))
    (check-equal? (resp-status none) 401)
    (check-regexp-match #rx"^Bearer resource_metadata=\"[^\"]*/.well-known/oauth-protected-resource" (resp-header none "WWW-Authenticate"))
    (check-false (regexp-match? #rx"error=" (resp-header none "WWW-Authenticate")))
    (define bad (rpc "nonsense" "ping"))
    (check-equal? (resp-status bad) 401)
    (check-regexp-match #rx"error=\"invalid_token\"" (resp-header bad "WWW-Authenticate")))

  (test-case "a client can follow the discovery chain from the 401 to the endpoints"
    (define challenge (resp-header (http "POST" "/mcp" #:json (hasheq 'jsonrpc "2.0" 'id 1 'method "ping")) "WWW-Authenticate"))
    (define metadata-url (cadr (regexp-match #rx"resource_metadata=\"([^\"]+)\"" challenge)))
    (check-true (string-prefix? metadata-url (current-base)))
    (define prm (resp-json (http "GET" (substring metadata-url (string-length (current-base))))))
    (check-equal? (hash-ref prm 'resource) (string-append (current-base) "/mcp"))
    (define issuer (first (hash-ref prm 'authorization_servers)))
    (check-equal? issuer (current-base))
    (define as (resp-json (http "GET" (string-append (substring issuer (string-length (current-base))) "/.well-known/oauth-authorization-server"))))
    (check-equal? (hash-ref as 'issuer) issuer)
    (check-equal? (hash-ref as 'registration_endpoint) (string-append issuer "/oauth/register"))
    (check-equal? (hash-ref as 'token_endpoint) (string-append issuer "/oauth/token")))

  (test-case "modern discovery and the legacy handshake, both stateless"
    (define d (resp-json (rpc token "server/discover")))
    (check-equal? (hash-ref (hash-ref d 'result) 'supportedVersions) '("2026-07-28" "2025-11-25" "2025-06-18"))
    (check-regexp-match #rx"get_deck" (hash-ref (hash-ref d 'result) 'instructions))
    (define i (rpc token "initialize" (hasheq 'protocolVersion "2025-11-25" 'capabilities (hasheq)
                                              'clientInfo (hasheq 'name "t" 'version "1"))))
    (check-equal? (hash-ref (hash-ref (resp-json i) 'result) 'protocolVersion) "2025-11-25")
    (check-false (resp-header i "Mcp-Session-Id"))
    (define modern (http "POST" "/mcp" #:headers (append (bearer token) '("MCP-Protocol-Version: 2026-07-28" "Mcp-Method: tools/call" "Mcp-Name: list_decks"))
                         #:json (hasheq 'jsonrpc "2.0" 'id 2 'method "tools/call"
                                        'params (hasheq 'name "list_decks" 'arguments (hasheq)
                                                        '_meta (hasheq '|io.modelcontextprotocol/protocolVersion| "2026-07-28"
                                                                       '|io.modelcontextprotocol/clientCapabilities| (hasheq))))))
    (check-equal? (hash-ref (hash-ref (resp-json modern) 'result) 'resultType) "complete"))

  (test-case "tools/list describes every tool with a schema"
    (define tools (hash-ref (hash-ref (resp-json (rpc token "tools/list")) 'result) 'tools))
    (check-equal? (map (λ (x) (hash-ref x 'name)) tools)
                  '("list_decks" "get_deck" "create_poll" "replace_poll" "delete_poll" "duplicate_poll"
                    "set_poll_show_results" "rename_deck" "set_qa_enabled" "list_sessions" "get_results"))
    (define create (findf (λ (x) (equal? (hash-ref x 'name) "create_poll")) tools))
    (check-equal? (hash-ref (hash-ref create 'inputSchema) 'required)
                  '("deck_id" "slide" "question" "kind" "options")))

  (test-case "create_poll through MCP is visible through REST; the other tools act on the deck"
    (define r (tool token "create_poll" (poll-args deck 3)))
    (check-false (hash-ref r 'isError))
    (define poll (structured r))
    (check-equal? (hash-ref poll 'question) "Favourite?")
    (define rest (resp-json (http "GET" (format "/api/decks/~a" deck) #:cookies (list cookie))))
    (check-equal? (map (λ (p) (hash-ref p 'id)) (hash-ref rest 'polls)) (list (hash-ref poll 'id)))
    (define got (structured (tool token "get_deck" (hasheq 'deck_id deck))))
    (check-equal? (hash-ref got 'page_count) 10)
    (check-equal? (hash-ref (car (hash-ref got 'polls)) 'slide) 3)
    (check-false (hash-has-key? got 'sessions))
    (check-equal? (hash-ref (structured (tool token "rename_deck" (hasheq 'deck_id deck 'title "Renamed"))) 'title) "Renamed")
    (check-equal? (hash-ref (resp-json (http "GET" (format "/api/decks/~a" deck) #:cookies (list cookie))) 'title) "Renamed")
    (check-true (hash-ref (structured (tool token "set_qa_enabled" (hasheq 'deck_id deck 'enabled #t))) 'qa_enabled))
    (check-true (hash-ref (car (hash-ref (structured (tool token "list_decks")) 'decks)) 'qa_enabled))
    (check-true (hash-ref (structured (tool token "set_poll_show_results" (hasheq 'poll_id (hash-ref poll 'id) 'show_results #t))) 'show_results))
    (define copy (structured (tool token "duplicate_poll" (hasheq 'poll_id (hash-ref poll 'id)))))
    (check-not-equal? (hash-ref copy 'id) (hash-ref poll 'id))
    (define replaced (structured (tool token "replace_poll" (hash-set (replace-args (hash-ref copy 'id) 'null) 'question "Changed?"))))
    (check-equal? (hash-ref replaced 'question) "Changed?")
    (check-equal? (hash-ref (structured (tool token "delete_poll" (hasheq 'poll_id (hash-ref copy 'id)))) 'deleted) #t))

  (test-case "failures are tool errors in the REST shape"
    (define bad-slide (tool token "create_poll" (poll-args deck 99)))
    (check-equal? (error-of bad-slide) "invalid_argument")
    (check-equal? (hash-ref (structured bad-slide) 'field) "slide")
    (define false-slide (tool token "create_poll" (poll-args deck #f)))
    (check-equal? (error-of false-slide) "invalid_argument")
    (check-equal? (hash-ref (structured false-slide) 'field) "slide")
    (define bad-kind (tool token "create_poll" (hash-set (poll-args deck 1) 'kind "some")))
    (check-equal? (error-of bad-kind) "invalid_argument")
    (check-equal? (hash-ref (structured bad-kind) 'field) "kind")
    (define exclusive (tool token "create_poll" (hash-set (poll-args deck 1) 'options
                                                          (list (hasheq 'label "a" 'exclusive #t) (hasheq 'label "b")))))
    (check-equal? (error-of exclusive) "invalid_argument")
    (check-equal? (hash-ref (structured exclusive) 'field) "options")
    (check-equal? (error-of (tool token "get_deck" (hasheq 'deck_id 999999))) "not_found"))

  (test-case "other people's decks: 404 for a stranger, 403 for a view-only share"
    (check-equal? (error-of (tool bob-token "get_deck" (hasheq 'deck_id deck))) "not_found")
    (check-equal? (error-of (tool bob-token "create_poll" (poll-args deck 1))) "not_found")
    (check-equal? (resp-status (http "PUT" (format "/api/decks/~a/shares/bob@example.org" deck) #:cookies (list cookie)
                                     #:json (hasheq 'edit #f 'moderate #f 'copy #f 'results #f)))
                  200)
    (check-equal? (hash-ref (structured (tool bob-token "get_deck" (hasheq 'deck_id deck))) 'id) deck)
    (check-equal? (error-of (tool bob-token "create_poll" (poll-args deck 1))) "forbidden")
    (check-equal? (error-of (tool bob-token "get_results" (hasheq 'deck_id deck))) "forbidden")
    (check-equal? (error-of (tool bob-token "list_sessions" (hasheq 'deck_id deck))) "forbidden"))

  (define (share! email . flags)
    (http "PUT" (format "/api/decks/~a/shares/~a" deck email) #:cookies (list cookie)
          #:json (for/hasheq ([k '(edit moderate copy results)]) (values k (and (memq k flags) #t)))))

  (test-case "an edit share lets a collaborator's agent edit but not read results"
    (define carol (user! "carol@example.org"))
    (check-equal? (resp-status (share! "carol@example.org" 'edit)) 200)
    (define carol-token (tokens-access (oauth-connect! carol '("decks" "results"))))
    (define made (tool carol-token "create_poll" (poll-args deck 4)))
    (check-false (hash-ref made 'isError))
    (check-equal? (error-of (tool carol-token "get_results" (hasheq 'deck_id deck))) "forbidden"))

  (define poll-id (hash-ref (structured (tool token "create_poll" (poll-args deck 2))) 'id))
  (define (session! label deck-id)
    (resp-json (http "POST" (format "/api/decks/~a/sessions" deck-id) #:cookies (list cookie) #:json (hasheq 'label label))))
  (define session (session! "Class A" deck))
  (define code (hash-ref session 'code))
  (define screen-code (hash-ref session 'screen_code))
  (define run (resp-json (http "POST" (format "/api/sessions/~a/poll/open" code) #:cookies (list cookie) #:json (hasheq 'poll_id poll-id))))
  (define option-ids (map (λ (o) (hash-ref o 'id)) (hash-ref run 'options)))
  (define vote (http "POST" (format "/api/s/~a/~a/vote" deck code) #:json (hasheq 'run_id (hash-ref run 'run_id) 'option_ids (list (cadr option-ids)))
                     #:cookies (list (format "orquelo_participant=~a.~a" code (random-uuid-v4)))))
  (check-equal? (resp-status vote) 200)
  (define secret-question "Why is the sky blue today")
  (check-equal? (resp-status (http "POST" (format "/api/sessions/~a/qa" code) #:cookies (list cookie) #:json (hasheq 'open #t))) 204)
  (check-equal? (resp-status (http "POST" (format "/api/s/~a/~a/qa" deck code) #:json (hasheq 'text secret-question)
                                   #:cookies (list (format "orquelo_participant=~a.~a" code (random-uuid-v4)))))
                201)

  (test-case "a poll with runs cannot be replaced or deleted, but can be duplicated"
    (check-equal? (error-of (tool token "replace_poll" (replace-args poll-id 2))) "poll_has_runs")
    (check-equal? (error-of (tool token "delete_poll" (hasheq 'poll_id poll-id))) "poll_has_runs")
    (check-false (hash-ref (structured (tool token "duplicate_poll" (hasheq 'poll_id poll-id))) 'has_runs)))

  (test-case "polls of another user's deck are not found, whatever the tool"
    (define eve-token (tokens-access (oauth-connect! (user! "eve@example.org") '("decks" "results"))))
    (check-equal? (error-of (tool eve-token "replace_poll" (replace-args poll-id 2))) "not_found")
    (check-equal? (error-of (tool eve-token "delete_poll" (hasheq 'poll_id poll-id))) "not_found")
    (check-equal? (error-of (tool eve-token "duplicate_poll" (hasheq 'poll_id poll-id))) "not_found")
    (check-equal? (error-of (tool eve-token "set_poll_show_results" (hasheq 'poll_id poll-id 'show_results #t))) "not_found"))

  (test-case "a session of another deck is not found through this deck"
    (define other (hash-ref (resp-json (upload! "Other" "2" pdf #:cookie cookie)) 'id))
    (define foreign (hash-ref (session! "Elsewhere" other) 'id))
    (check-equal? (error-of (tool token "get_results" (hasheq 'deck_id deck 'session_id foreign))) "not_found")
    (check-false (hash-ref (tool token "get_results" (hasheq 'deck_id other 'session_id foreign)) 'isError)))

  (test-case "an edit-only collaborator cannot list sessions"
    (define carol-token (tokens-access (oauth-connect! (user! "carol@example.org") '("decks" "results"))))
    (check-equal? (error-of (tool carol-token "list_sessions" (hasheq 'deck_id deck))) "forbidden"))

  (test-case "list_decks lists archived decks only when asked"
    (define old (hash-ref (resp-json (upload! "Old" "2" pdf #:cookie cookie)) 'id))
    (check-equal? (resp-status (http "POST" (format "/api/decks/~a/archive" old) #:cookies (list cookie))) 200)
    (define (ids archived)
      (map (λ (d) (hash-ref d 'id)) (hash-ref (structured (tool token "list_decks" archived)) 'decks)))
    (check-not-false (member old (ids (hasheq 'archived #t))))
    (check-false (member deck (ids (hasheq 'archived #t))))
    (check-false (member old (ids (hasheq))))
    (check-not-false (member deck (ids (hasheq 'archived #f)))))

  (test-case "get_results: per-run aggregates, never codes"
    (define r (tool token "get_results" (hasheq 'deck_id deck)))
    (check-false (hash-ref r 'isError))
    (define s (first (hash-ref (structured r) 'sessions)))
    (check-equal? (sort (hash-keys s) symbol<?) '(ended_at label runs session_id started_at unique_voters))
    (check-equal? (hash-ref s 'label) "Class A")
    (check-equal? (hash-ref s 'unique_voters) 1)
    (define run-result (first (hash-ref s 'runs)))
    (check-equal? (hash-ref run-result 'total_voters) 1)
    (check-equal? (hash-ref run-result 'options) (list (hasheq 'label "Red" 'count 0) (hasheq 'label "Blue" 'count 1)))
    (define text (jsexpr->string (structured r)))
    (check-false (string-contains? text code))
    (check-false (string-contains? text screen-code))
    (check-false (string-contains? text secret-question) "Q&A text stays out")
    (define one (structured (tool token "get_results" (hasheq 'deck_id deck 'session_id (hash-ref s 'session_id)))))
    (check-equal? (length (hash-ref one 'sessions)) 1)
    (check-equal? (error-of (tool token "get_results" (hasheq 'deck_id deck 'session_id 999999))) "not_found")
    (check-false (hash-ref (structured r) 'truncated))
    (check-equal? (hash-ref (structured r) 'total_sessions) 1))

  (test-case "list_sessions: newest first, no codes"
    (define r (tool token "list_sessions" (hasheq 'deck_id deck)))
    (define sessions (hash-ref (structured r) 'sessions))
    (check-equal? (map (λ (s) (hash-ref s 'label)) sessions) '("Class A"))
    (check-equal? (sort (hash-keys (first sessions)) symbol<?) '(ended_at label session_id started_at))
    (check-false (string-contains? (jsexpr->string (structured r)) code)))

  (test-case "a results-only share lets a collaborator's agent read results of every session"
    (define dave (user! "dave@example.org"))
    (check-equal? (resp-status (share! "dave@example.org" 'results)) 200)
    (define dave-token (tokens-access (oauth-connect! dave '("decks" "results"))))
    (check-equal? (length (hash-ref (structured (tool dave-token "list_sessions" (hasheq 'deck_id deck))) 'sessions)) 1)
    (check-equal? (length (hash-ref (structured (tool dave-token "get_results" (hasheq 'deck_id deck))) 'sessions)) 1)
    (check-equal? (error-of (tool dave-token "create_poll" (poll-args deck 1))) "forbidden"))

  (test-case "get_results returns the newest sessions up to `limit` and says when more exist"
    (define many (hash-ref (resp-json (upload! "Many" "3" pdf #:cookie cookie)) 'id))
    (for ([i 12]) (session! (format "S~a" i) many))
    (define (results . extra) (structured (tool token "get_results" (apply hasheq 'deck_id many extra))))
    (define default (results))
    (check-equal? (length (hash-ref default 'sessions)) 10)
    (check-equal? (hash-ref default 'total_sessions) 12)
    (check-true (hash-ref default 'truncated))
    (check-equal? (hash-ref (first (hash-ref default 'sessions)) 'label) "S11" "newest first")
    (define two (results 'limit 2))
    (check-equal? (map (λ (s) (hash-ref s 'label)) (hash-ref two 'sessions)) '("S11" "S10"))
    (define all (results 'limit 50))
    (check-equal? (length (hash-ref all 'sessions)) 12)
    (check-false (hash-ref all 'truncated))
    (check-equal? (length (hash-ref (structured (tool token "list_sessions" (hasheq 'deck_id many))) 'sessions)) 12)
    (check-equal? (error-of (tool token "get_results" (hasheq 'deck_id many 'limit 51))) "invalid_argument")
    (check-equal? (error-of (tool token "get_results" (hasheq 'deck_id many 'limit 0))) "invalid_argument")
    (define one (results 'session_id (hash-ref (first (hash-ref default 'sessions)) 'session_id) 'limit 1))
    (check-equal? (length (hash-ref one 'sessions)) 1)
    (check-false (hash-ref one 'truncated))
    (check-equal? (hash-ref (results 'session_id 'null) 'total_sessions) 12 "null reads as absent"))

  (test-case "a deck the edition disabled: the owner sees the flag and edits are refused"
    (check-false (hash-has-key? (structured (tool token "get_deck" (hasheq 'deck_id deck))) 'disabled))
    (hash-set! disabled-decks deck #t)
    (check-true (hash-ref (structured (tool token "get_deck" (hasheq 'deck_id deck))) 'disabled))
    (check-equal? (error-of (tool token "create_poll" (poll-args deck 1))) "deck_disabled")
    (check-equal? (error-of (tool token "rename_deck" (hasheq 'deck_id deck 'title "Nope"))) "deck_disabled")
    (hash-remove! disabled-decks deck))

  (test-case "scopes: a results-only token reads results but gets 403 insufficient_scope on a decks tool"
    (define results-token (tokens-access (oauth-connect! cookie '("results"))))
    (check-false (hash-ref (tool results-token "get_results" (hasheq 'deck_id deck)) 'isError))
    (define r (rpc results-token "tools/call" (hasheq 'name "get_deck" 'arguments (hasheq 'deck_id deck))))
    (check-equal? (resp-status r) 403)
    (check-regexp-match #rx"error=\"insufficient_scope\", scope=\"decks\"" (resp-header r "WWW-Authenticate"))
    (check-equal? (resp-status (rpc results-token "tools/list")) 200))

  (test-case "refresh rotates the pair; reusing the old refresh token revokes the grant and its access tokens"
    (define c (user! "rotate@example.org"))
    (define first-pair (oauth-connect! c '("decks")))
    (define r (refresh-request (tokens-refresh first-pair)))
    (check-equal? (resp-status r) 200)
    (define next (hash-ref (resp-json r) 'access_token))
    (check-equal? (resp-status (rpc next "ping")) 200)
    (check-equal? (resp-status (refresh-request (tokens-refresh first-pair))) 400)
    (check-equal? (resp-status (rpc next "ping")) 401)
    (check-regexp-match #rx"invalid_token" (resp-header (rpc next "ping") "WWW-Authenticate")))

  (test-case "disconnecting the app in Connected apps ends its access"
    (define c (user! "revoke@example.org"))
    (define pair (oauth-connect! c '("decks")))
    (check-equal? (resp-status (rpc (tokens-access pair) "ping")) 200)
    (define g (first (resp-json (http "GET" "/api/oauth/grants" #:cookies (list c)))))
    (check-equal? (resp-status (http "DELETE" (string-append "/api/oauth/grants/" (hash-ref g 'id)) #:cookies (list c))) 204)
    (check-equal? (resp-status (rpc (tokens-access pair) "ping")) 401))

  (test-case "a password change through the account endpoint ends the access of every connected app"
    (define email "passwd@example.org")
    (define c (user! email))
    (define pair (oauth-connect! c '("decks")))
    (check-equal? (resp-status (rpc (tokens-access pair) "ping")) 200)
    (check-equal? (resp-status (http "PUT" "/api/me/password" #:cookies (list c)
                                     #:json (hasheq 'current test-password 'new "a brand new password")))
                  204)
    (check-equal? (resp-status (rpc (tokens-access pair) "ping")) 401)
    (check-equal? (hash-ref (first (resp-json (http "GET" "/api/oauth/grants" #:cookies (list (login-cookie! email "a brand new password"))))) 'needs_reconnect) #t))

  (test-case "a suspension ends the access of every connected app"
    (define uid (ensure-password-user! db "suspend@example.org"))
    (define pair (oauth-connect! (login-cookie! "suspend@example.org") '("decks")))
    (check-equal? (resp-status (rpc (tokens-access pair) "ping")) 200)
    (set-user-status! db uid "suspended")
    (check-equal? (resp-status (rpc (tokens-access pair) "ping")) 401))

  (test-case "Origin, method and notifications"
    (check-equal? (resp-status (http "POST" "/mcp" #:origin "https://evil.example" #:headers (bearer token)
                                     #:json (hasheq 'jsonrpc "2.0" 'id 1 'method "ping")))
                  403)
    (define get (http "GET" "/mcp" #:headers (bearer token)))
    (check-equal? (resp-status get) 405)
    (check-equal? (resp-header get "Allow") "POST")
    (check-equal? (resp-status (http "DELETE" "/mcp" #:headers (bearer token))) 405)
    (check-equal? (resp-status (http "POST" "/mcp" #:origin #f #:headers (bearer token)
                                     #:json (hasheq 'jsonrpc "2.0" 'id 1 'method "ping")))
                  200 "an absent Origin is fine")
    (define n (http "POST" "/mcp" #:headers (bearer token) #:json (hasheq 'jsonrpc "2.0" 'method "notifications/initialized")))
    (check-equal? (resp-status n) 202)))
