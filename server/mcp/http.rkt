#lang racket/base
;; Streamable HTTP for MCP, as a web-server handler: POST only, JSON replies only, stateless.
;; The app decides who may call (`authenticate`) and which Origins are acceptable; this module
;; applies both to every request and maps JSON-RPC errors to HTTP statuses.
(require racket/contract/base racket/match json web-server/http
         "jsonrpc.rkt" "server.rkt")
;; the largest body served, in bytes, unless the app says otherwise
(define default-max-body (* 1024 1024))

(provide (contract-out
          [struct mcp-principal ([ctx any/c] [scopes (listof string?)])]
          [make-streamable-handler
           (->* (mcp-server?
                 #:authenticate (-> request? (or/c mcp-principal? response?))
                 #:allowed-origin? (-> string? boolean?)
                 #:insufficient-scope (-> string? response?))
                (#:max-body exact-nonnegative-integer?
                 #:on-failure (-> exn:fail? (or/c response? #f)))
                (-> request? response?))]))

;; A McpPrincipal is a (mcp-principal Ctx (listof String)): what the app passes to tools, and the
;; scopes the caller holds
(struct mcp-principal (ctx scopes))

;; McpServer #:authenticate #:allowed-origin? #:insufficient-scope [#:max-body Natural]
;;   [#:on-failure (exn:fail -> (or Response #f))] -> (Request -> Response)
;; The handler checks, in order: Origin (403), method (405), body size (413), authentication, then
;; parses and dispatches.
;; authenticate: a principal, or the response to send instead (e.g. 401 with WWW-Authenticate);
;; allowed-origin?: judges an Origin header when the request has one;
;; insufficient-scope: the response (403) for a call that needs the given scope;
;; max-body: web-server has already read the body by now, so this bounds the parsing work, not memory;
;; on-failure: a response for an exception raised by a hook or a tool (e.g. 503 on a pool timeout), or
;;   #f for a JSON-RPC internal error
(define (make-streamable-handler server
                                 #:authenticate authenticate
                                 #:allowed-origin? allowed-origin?
                                 #:insufficient-scope insufficient-scope
                                 #:max-body [max-body default-max-body]
                                 #:on-failure [on-failure (λ (e) #f)])
  (λ (req)
    (with-handlers ([exn:fail? (λ (e) (or (on-failure e) (failure-response e 'null)))])
      (define origin (request-header req "Origin"))
      (define body (or (request-post-data/raw req) #""))
      (cond [(and origin (not (allowed-origin? origin))) (error-response 403 "origin not allowed")]
            [(not (equal? (request-method req) #"POST"))
             (struct-copy response (error-response 405 "POST only") [headers (list (make-header #"Allow" #"POST"))])]
            [(> (bytes-length body) max-body) (error-response 413 "request body too large")]
            [else
             (match (authenticate req)
               [(? response? r) r]
               [principal (handle server principal req body insufficient-scope on-failure)])]))))

;; McpServer McpPrincipal Request Bytes (String -> Response) (exn:fail -> (or Response #f)) -> Response
;; parses the body and answers it; an exception from dispatch is answered with the request's id
(define (handle server principal req body insufficient-scope on-failure)
  (define msg (parse-message body))
  (with-handlers ([exn:fail? (λ (e) (or (on-failure e) (failure-response e (message-id msg))))])
    (reply->response
     (mcp-dispatch server (mcp-principal-ctx principal) (mcp-principal-scopes principal) msg
                   (λ (name) (request-header req name)))
     insufficient-scope)))

;; (or RpcRequest RpcNotification RpcFailure) -> (or Id 'null)
(define (message-id msg) (if (rpc-request? msg) (rpc-request-id msg) 'null))

;; (or JSExpr 'accepted MissingScope) (String -> Response) -> Response
(define (reply->response reply insufficient-scope)
  (match reply
    ['accepted (response/full 202 #"Accepted" (current-seconds) #f '() '())]
    [(missing-scope name) (insufficient-scope name)]
    [_ (json-response (error-status (or (response-error-code reply) 0)) reply)]))

;; Exn (or Id 'null) -> Response
;; the JSON-RPC internal error for an exception no hook handled; the message is not leaked
(define (failure-response e id)
  (log-error "mcp: ~a" (exn-message e))
  (json-response 500 (rpc-error id internal-error "internal error")))

;; Natural String -> Response
;; a JSON-RPC invalid-request error with no id, for failures before a message is read
(define (error-response status message)
  (json-response status (rpc-error 'null invalid-request message)))

;; Natural JSExpr -> Response
;; a JSON reply with this HTTP status
(define (json-response status body)
  (response/full status (reason status) (current-seconds) #"application/json" '() (list (jsexpr->bytes body))))

;; Natural -> Bytes
;; the HTTP reason phrase of a status this module sends
(define (reason status)
  (case status
    [(200) #"OK"] [(400) #"Bad Request"] [(403) #"Forbidden"] [(404) #"Not Found"]
    [(405) #"Method Not Allowed"] [(413) #"Payload Too Large"] [else #"Internal Server Error"]))

;; Request String -> (or String #f)
;; the value of a request header (case-insensitive name), as text
(define (request-header req name)
  (define h (headers-assq* (string->bytes/utf-8 name) (request-headers/raw req)))
  (and h (bytes->string/utf-8 (header-value h) #\?)))

(module+ test
  (require rackunit net/url racket/promise racket/port "tool.rkt")
  (define-tool (echo ctx) #:description "Echoes." #:read-only #:args [in (list [text (string 1 5)])] (hasheq 'text (car in)))
  (define-tool (secret ctx) #:description "Needs a scope." #:scope "decks" (hasheq 'ok #t))
  (define-tool (explode ctx) #:description "Raises." (error "boom"))
  (define server (make-mcp-server "orq" "1.0" (list echo secret explode)))
  (define challenge
    (response/full 401 #"Unauthorized" (current-seconds) #f
                   (list (make-header #"WWW-Authenticate" #"Bearer resource_metadata=\"https://x/.well-known\"")) '()))

  (define (authenticate req)
    (match (request-header req "Authorization")
      ["Bearer all" (mcp-principal 'me '("decks"))]
      ["Bearer none" (mcp-principal 'me '())]
      [_ challenge]))
  (define handler
    (make-streamable-handler server #:authenticate authenticate
                             #:allowed-origin? (λ (o) (equal? o "https://orq.example"))
                             #:insufficient-scope (λ (scope) (response/full 403 #"Forbidden" (current-seconds) #f '() '()))
                             #:max-body 1000))
  (define (make-req method body [headers '()])
    (make-request method (string->url "/mcp") (for/list ([h headers]) (make-header (string->bytes/utf-8 (car h)) (string->bytes/utf-8 (cdr h))))
                  (delay '()) body "127.0.0.1" 80 "127.0.0.1"))
  (define (post body headers) (handler (make-req #"POST" (if (string? body) (string->bytes/utf-8 body) body) (cons '("Authorization" . "Bearer all") headers))))
  (define (body-of r) (let ([o (open-output-bytes)]) ((response-output r) o) (get-output-bytes o)))
  (define (json-of r) (bytes->jsexpr (body-of r)))
  (define (header-of r name) (let ([h (headers-assq* name (response-headers r))]) (and h (header-value h))))
  (define (code-of r) (response-error-code (json-of r)))

  (define modern-meta "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}")
  (define (modern-list) (format "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{~a}}" modern-meta))
  (define modern-list-headers '(("MCP-Protocol-Version" . "2026-07-28") ("Mcp-Method" . "tools/list")))

  (test-case "a modern request round-trips as JSON"
    (define r (post (modern-list) modern-list-headers))
    (check-equal? (response-code r) 200)
    (check-equal? (response-mime r) #"application/json")
    (check-equal? (hash-ref (hash-ref (json-of r) 'result) 'resultType) "complete")
    (check-equal? (length (hash-ref (hash-ref (json-of r) 'result) 'tools)) 3))
  (test-case "a modern request names the call in Mcp-Name"
    (define call (format "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"},~a}}" modern-meta))
    (define ok (post call '(("MCP-Protocol-Version" . "2026-07-28") ("Mcp-Method" . "tools/call") ("Mcp-Name" . "echo"))))
    (check-equal? (hash-ref (hash-ref (json-of ok) 'result) 'isError) #f)
    (define r (post call '(("MCP-Protocol-Version" . "2026-07-28") ("Mcp-Method" . "tools/call"))))
    (check-equal? (response-code r) 400)
    (check-equal? (code-of r) header-mismatch))
  (test-case "missing or mismatched headers are 400 with -32020"
    (define r (post (modern-list) '(("MCP-Protocol-Version" . "2026-07-28"))))
    (check-equal? (response-code r) 400)
    (check-equal? (code-of r) header-mismatch)
    (check-equal? (code-of (post (modern-list) '(("MCP-Protocol-Version" . "2026-07-28") ("Mcp-Method" . "tools/call")))) header-mismatch)
    (check-equal? (code-of (post (modern-list) '(("MCP-Protocol-Version" . "2026-07-28") ("Mcp-Method" . "=?base64?dG9vbHMvbGlzdA==?=")))) #f))
  (test-case "an unsupported version is 400 with -32022 and the supported list"
    (define body "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2030-01-01\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}")
    (define r (post body '(("MCP-Protocol-Version" . "2030-01-01") ("Mcp-Method" . "tools/list"))))
    (check-equal? (response-code r) 400)
    (check-equal? (hash-ref (hash-ref (hash-ref (json-of r) 'error) 'data) 'requested) "2030-01-01")
    (check-equal? (hash-ref (hash-ref (hash-ref (json-of r) 'error) 'data) 'supported) '("2026-07-28" "2025-11-25" "2025-06-18")))
  (test-case "a missing _meta key is 400 with -32602"
    (define r (post "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}" modern-list-headers))
    (check-equal? (response-code r) 400)
    (check-equal? (code-of r) invalid-params))
  (test-case "legacy clients initialize on both legacy versions, with no session id"
    (for ([v legacy-versions])
      (define r (post (format "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"~a\",\"capabilities\":{},\"clientInfo\":{\"name\":\"c\",\"version\":\"1\"}}}" v)
                      '(("Mcp-Session-Id" . "ignored"))))
      (check-equal? (response-code r) 200)
      (check-equal? (hash-ref (hash-ref (json-of r) 'result) 'protocolVersion) v)
      (check-false (header-of r #"Mcp-Session-Id"))
      (define l (post "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}" `(("MCP-Protocol-Version" . ,v) ("Mcp-Session-Id" . "ignored"))))
      (check-equal? (response-code l) 200)
      (check-equal? (length (hash-ref (hash-ref (json-of l) 'result) 'tools)) 3)))
  (test-case "notifications are 202 with no body"
    (define r (post "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" '()))
    (check-equal? (response-code r) 202)
    (check-equal? (body-of r) #""))
  (test-case "only POST: GET and DELETE are 405 with Allow"
    (for ([m '(#"GET" #"DELETE")])
      (define r (handler (make-req m #f '(("Authorization" . "Bearer all")))))
      (check-equal? (response-code r) 405)
      (check-equal? (header-of r #"Allow") #"POST")))
  (test-case "a foreign Origin is 403, an allowed or absent one passes"
    (check-equal? (response-code (post (modern-list) (cons '("Origin" . "https://evil.example") modern-list-headers))) 403)
    (check-equal? (response-code (post (modern-list) (cons '("Origin" . "https://orq.example") modern-list-headers))) 200)
    (check-equal? (response-code (post (modern-list) modern-list-headers)) 200))
  (test-case "the auth hook's challenge is returned as is, on every method"
    (define r (handler (make-req #"POST" (string->bytes/utf-8 (modern-list)) modern-list-headers)))
    (check-equal? (response-code r) 401)
    (check-equal? (header-of r #"WWW-Authenticate") #"Bearer resource_metadata=\"https://x/.well-known\"")
    (check-equal? (response-code (handler (make-req #"POST" #"{nope" '()))) 401))
  (test-case "the method, the size and the Origin are judged before authentication"
    (check-equal? (response-code (handler (make-req #"GET" #f))) 405)
    (check-equal? (response-code (handler (make-req #"POST" (make-bytes 1001 65)))) 413)
    (check-equal? (response-code (handler (make-req #"POST" #"{}" '(("Origin" . "https://evil.example"))))) 403))
  (test-case "a tool the caller has no scope for gets the app's response, given the scope it needs"
    (define call "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"secret\"}}")
    (define needed (box #f))
    (define scoped
      (make-streamable-handler server #:authenticate authenticate #:allowed-origin? (λ (o) #t)
                               #:insufficient-scope (λ (scope) (set-box! needed scope) (response/full 403 #"Forbidden" (current-seconds) #f '() '()))))
    (check-equal? (response-code (post call '())) 200)
    (check-equal? (response-code (scoped (make-req #"POST" (string->bytes/utf-8 call) '(("Authorization" . "Bearer none"))))) 403)
    (check-equal? (unbox needed) "decks"))
  (test-case "a modern notification with its headers is 202"
    (define r (post (format "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{~a}}" modern-meta)
                    '(("MCP-Protocol-Version" . "2026-07-28") ("Mcp-Method" . "notifications/cancelled"))))
    (check-equal? (response-code r) 202)
    (check-equal? (body-of r) #""))
  (test-case "a body of exactly max-body bytes is served"
    (define base "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}")
    (define padded (string-append base (make-string (- 1000 (string-length base)) #\space)))
    (check-equal? (response-code (post padded '())) 200))
  (test-case "unknown methods are 404, parse errors and batches 400, big bodies 413"
    (check-equal? (response-code (post "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/list\"}" '())) 404)
    (define bad (post "{nope" '()))
    (check-equal? (response-code bad) 400)
    (check-equal? (code-of bad) parse-error)
    (define batch (post "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]" '()))
    (check-equal? (response-code batch) 400)
    (check-equal? (code-of batch) invalid-request)
    (check-equal? (response-code (post (make-bytes 1001 65) '())) 413))
  (test-case "an exception from a tool is a JSON-RPC internal error unless the app handles it"
    (define call "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"explode\"}}")
    (define r (post call '()))
    (check-equal? (response-code r) 500)
    (check-equal? (code-of r) internal-error)
    (check-false (regexp-match? #rx"boom" (body-of r)))
    (define busy (make-streamable-handler server #:authenticate authenticate #:allowed-origin? (λ (o) #f)
                                          #:insufficient-scope (λ (s) challenge)
                                          #:on-failure (λ (e) (response/full 503 #"Service Unavailable" (current-seconds) #f '() '()))))
    (check-equal? (response-code (busy (make-req #"POST" (string->bytes/utf-8 call) '(("Authorization" . "Bearer all"))))) 503))
  (test-case "exceptions from the authenticate and Origin hooks go through on-failure too"
    (define (busy-handler #:authenticate auth #:allowed-origin? ok)
      (make-streamable-handler server #:authenticate auth #:allowed-origin? ok
                               #:insufficient-scope (λ (s) challenge)
                               #:on-failure (λ (e) (and (regexp-match? #rx"pool" (exn-message e))
                                                        (response/full 503 #"Service Unavailable" (current-seconds) #f '() '())))))
    (define req (make-req #"POST" #"{}" '(("Origin" . "https://orq.example"))))
    (check-equal? (response-code ((busy-handler #:authenticate (λ (r) (error "pool timeout")) #:allowed-origin? (λ (o) #t)) req)) 503)
    (check-equal? (response-code ((busy-handler #:authenticate authenticate #:allowed-origin? (λ (o) (error "pool timeout"))) req)) 503)
    (check-equal? (response-code ((busy-handler #:authenticate (λ (r) (error "other")) #:allowed-origin? (λ (o) #t)) req)) 500)))
