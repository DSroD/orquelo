#lang racket/base
;; The MCP endpoint (POST /mcp): the generic MCP server over Orquelo's tools, behind the OAuth bearer
;; token of the built-in authorization server. Part of core; it exists only when OAuth does.
(require racket/contract/base racket/match web-server/http
         (only-in "../mcp/main.rkt" make-mcp-server make-streamable-handler mcp-principal tool-error)
         (prefix-in o: "../oauth/main.rkt")
         "../config.rkt" "../db/accounts.rkt" "../db/conn.rkt" "../domain.rkt" "../domain/parse.rkt"
         "deps.rkt" "json.rkt" "mcp-tools.rkt" "oauth-routes.rkt")
(provide (contract-out
          [make-mcp-handler (-> deps? oauth-routes? (-> request? response?))]))

;; String
;; what the agent is told about the server when it connects
(define instructions
  (string-append
   "Orquelo runs live polls for PDF lectures. These tools prepare decks: list_decks and get_deck show what exists "
   "(slides are numbered from 1), create_poll, replace_poll, delete_poll and duplicate_poll manage polls, "
   "set_poll_show_results, rename_deck and set_qa_enabled change settings, and get_results reads aggregate results. "
   "A poll that was ever opened in a session has runs and cannot be replaced or deleted: duplicate it and edit the "
   "copy. Starting sessions, opening polls and uploading PDFs are done by the presenter in the web app, not here. "
   "Failed calls return {error, message, field?}; fix the named field and retry."))

;; Deps OAuthRoutes -> (Request -> Response)
;; the /mcp handler: tools over the database, callers authenticated by the OAuth server, Origin pinned to
;; PUBLIC_BASE_URL
(define (make-mcp-handler d routes)
  (define srv (oauth-routes-server routes))
  (define base (config-public-base-url (deps-cfg d)))
  (make-streamable-handler
   (make-mcp-server "orquelo" "1" mcp-tools #:instructions instructions #:tool-failure tool-failure)
   #:authenticate (λ (req) (authenticate d srv req))
   #:allowed-origin? (λ (origin) (equal? origin base))
   #:insufficient-scope (λ (scope) (o:insufficient-scope-challenge srv scope))
   #:on-failure on-failure))

;; Deps OAuthServer Request -> (or McpPrincipal Response)
;; the caller a valid bearer token speaks for, as the tools' context; 401 when the token is not valid
;; or its user is gone or suspended. The OAuth server already ties tokens to the user's session epoch (a
;; suspension bumps it); loading the user again is defence in depth, and gives the tools their User
(define (authenticate d srv req)
  (match (o:authenticate srv req)
    [(? response? r) r]
    [p (match (get-user (deps-db d) (o:principal-subject p))
         [(? user? u) #:when (equal? (user-status u) "active") (mcp-principal (mcp-ctx d u) (o:principal-scopes p))]
         [_ (invalid-token srv)])]))

;; OAuthServer -> Response
;; the 401 for a token whose user is gone or suspended, the same challenge as for any invalid token
(define (invalid-token srv)
  (response/full 401 #"Unauthorized" (current-seconds) #f
                 (list (o:www-authenticate srv #:error "invalid_token") (make-header #"Cache-Control" #"no-store")) '()))

;; Exn -> (or ToolResult #f)
;; the failed call an API or domain error is: the REST API's {error, message, field?}, except that
;; every bad-argument failure (REST "invalid") has the one code invalid_argument; other exceptions are
;; not tool errors
(define (tool-failure e)
  (match e
    [(? exn:api?)
     (define code (if (equal? (exn:api-code e) "invalid") "invalid_argument" (exn:api-code e)))
     (define body (hasheq 'error code 'message (exn-message e)))
     (tool-error (if (exn:api-field e) (hash-set body 'field (exn:api-field e)) body))]
    [(? exn:domain?)
     (tool-error (hasheq 'error "invalid_argument" 'message (exn-message e) 'field (symbol->string (exn:domain-field e))))]
    [_ #f]))

;; Exn -> (or Response #f)
;; a full database pool is a 503 with Retry-After, the REST answer; anything else is left to the library
(define (on-failure e) (and (exn:fail:pool-timeout? e) (busy-response)))

(module+ test
  (require rackunit "../mcp/main.rkt")
  (define (content e) (tool-result-content (tool-failure e)))
  (define marks (current-continuation-marks))
  (test-case "API errors keep the REST shape; invalid is invalid_argument"
    (check-equal? (content (exn:api "gone" marks 404 "not_found" #f)) (hasheq 'error "not_found" 'message "gone"))
    (check-equal? (content (exn:api "bad" marks 422 "invalid" "slide")) (hasheq 'error "invalid_argument" 'message "bad" 'field "slide"))
    (check-true (tool-result-error? (tool-failure (exn:api "x" marks 409 "poll_has_runs" #f)))))
  (test-case "domain errors name the field; other exceptions are not tool errors"
    (check-equal? (content (exn:domain "bad kind" marks 'kind)) (hasheq 'error "invalid_argument" 'message "bad kind" 'field "kind"))
    (check-false (tool-failure (exn:fail "boom" marks))))
  (test-case "a pool timeout is a 503 with Retry-After, other failures are left to the library"
    (define r (on-failure (exn:fail:pool-timeout "full" marks)))
    (check-equal? (response-code r) 503)
    (check-not-false (headers-assq* #"Retry-After" (response-headers r)))
    (check-false (on-failure (exn:fail "boom" marks)))))
