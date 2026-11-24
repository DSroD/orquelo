#lang racket/base
;; The MCP protocol layer, independent of HTTP: given a parsed JSON-RPC message and the request's
;; headers, answers with the reply to send. Serves the modern protocol (2026-07-28: per-request
;; `_meta`, `server/discover`, header checks) and, through `initialize`, the legacy 2025 versions,
;; always statelessly (no session id is ever minted).
(require racket/contract/base racket/list racket/match racket/string json net/base64
         "jsonrpc.rkt" "schema.rkt" "tool.rkt")
(provide (contract-out
          [struct missing-scope ([name string?])]
          [mcp-server? (-> any/c boolean?)]
          [make-mcp-server (->* (string? string? (listof tool?))
                                (#:instructions (or/c string? #f)
                                 #:tool-failure (-> exn:fail? (or/c tool-result? #f))
                                 #:ttl-ms exact-nonnegative-integer?)
                                mcp-server?)]
          [modern-versions (listof string?)]
          [legacy-versions (listof string?)]
          [mcp-dispatch (-> mcp-server? any/c (listof string?)
                            (or/c rpc-request? rpc-notification? rpc-failure?)
                            (-> string? (or/c string? #f))
                            (or/c jsexpr? 'accepted missing-scope?))]))

;; A McpServer is a (mcp-server String String (or String #f) (listof Tool) (exn:fail -> (or ToolResult #f)) Natural)
;;   name, version, instructions, tools (listed in this order), a hook turning an exception raised by a tool
;;   into a failed call (#f: let it escape), and the ttlMs advertised for cacheable results.
;; A Headers is a (String -> (or String #f)): the value of a request header, by case-insensitive name.
;; A MissingScope is a (missing-scope String): the call needs a scope the caller lacks.
;; A Method is a (method String (or Symbol #f) Serve): the name, the capability it implies (#f: none)
;;   and what answers it. A Serve is
;;   (McpServer Ctx (listof String) Id JSObject Boolean -> (or JSExpr MissingScope)), where the Boolean says
;;   whether the request is modern.
(struct mcp-server (name version instructions tools tool-failure ttl-ms))
(struct missing-scope (name))
(struct method (name capability serve))

;; String String (listof Tool) [#:instructions (or String #f)] [#:tool-failure (exn:fail -> (or ToolResult #f))]
;;   [#:ttl-ms Natural] -> McpServer
;; a server for these tools, whose names must be unique
(define (make-mcp-server name version tools
                         #:instructions [instructions #f]
                         #:tool-failure [tool-failure (λ (e) #f)]
                         #:ttl-ms [ttl-ms 60000])
  (define dup (check-duplicates (map tool-name tools)))
  (when dup (raise-arguments-error 'make-mcp-server "duplicate tool name" "name" dup))
  (mcp-server name version instructions tools tool-failure ttl-ms))

;; the one place the supported protocol versions are listed, newest first
(define modern-versions '("2026-07-28"))
(define legacy-versions '("2025-11-25" "2025-06-18"))
(define all-versions (append modern-versions legacy-versions))

(define version-key '|io.modelcontextprotocol/protocolVersion|)
(define capabilities-key '|io.modelcontextprotocol/clientCapabilities|)
(define server-info-key '|io.modelcontextprotocol/serverInfo|)

;; McpServer Ctx (listof String) (or RpcRequest RpcNotification RpcFailure) Headers
;;   -> (or JSExpr 'accepted MissingScope)
;; the reply to a message: a JSON-RPC response (result or error), 'accepted for a notification, or the
;; scope a tool call lacks
(define (mcp-dispatch srv ctx scopes msg header)
  (match msg
    [(rpc-failure id code message) (rpc-error id code message)]
    [(rpc-notification _ _) 'accepted]
    [(rpc-request id name params)
     (cond [(equal? name "initialize") (rpc-result id (initialize-result srv params))]
           [(findf (λ (m) (equal? (method-name m) name)) methods)
            => (λ (m) (route srv ctx scopes id m params header))]
           [else (rpc-error id method-not-found (format "unknown method: ~a" name))])]))

;; McpServer Ctx (listof String) Id Method JSObject Headers -> (or JSExpr MissingScope)
;; decides which protocol era a request belongs to. server/discover is always answered, whatever its
;; `_meta` and headers say, so a client can learn the versions. A request without `_meta` is legacy
;; when its MCP-Protocol-Version header says so (or is absent)
(define (route srv ctx scopes id m params header)
  (define meta (let ([x (hash-ref params '_meta (hasheq))]) (if (hash? x) x (hasheq))))
  (define header-version (decoded-header header "MCP-Protocol-Version"))
  (define (serve modern?) ((method-serve m) srv ctx scopes id params modern?))
  (cond [(equal? (method-name m) "server/discover") (serve #t)]
        [(eq? header-version 'malformed) (rpc-error id header-mismatch "MCP-Protocol-Version header is malformed")]
        [(hash-has-key? meta version-key) (modern id m params meta header serve)]
        [(or (not header-version) (member header-version legacy-versions)) (serve #f)]
        [(member header-version modern-versions) (rpc-error id invalid-params (missing-meta version-key))]
        [else (unsupported id header-version)]))

;; Id Method JSObject JSObject Headers (Boolean -> X) -> (or X JSExpr)
;; validates the `_meta` and headers of a modern request, then serves it
(define (modern id m params meta header serve)
  (define version (hash-ref meta version-key #f))
  (cond [(not (string? version)) (rpc-error id invalid-params (missing-meta version-key))]
        [(not (member version modern-versions)) (unsupported id version)]
        [(not (hash? (hash-ref meta capabilities-key #f))) (rpc-error id invalid-params (missing-meta capabilities-key))]
        [(header-problem header version (method-name m) params) => (λ (problem) (rpc-error id header-mismatch problem))]
        [else (serve #t)]))

;; Symbol -> String
(define (missing-meta key) (format "params._meta[\"~a\"] is required" key))

;; Id String -> JSExpr
(define (unsupported id requested)
  (rpc-error id unsupported-version (format "unsupported protocol version: ~a" requested)
             (hasheq 'supported all-versions 'requested requested)))

;; Headers String String JSObject -> (or String #f)
;; what is wrong with the routing headers of a modern request, if anything
(define (header-problem header version name params)
  (define (check header-name expected)
    (match (decoded-header header header-name)
      [#f (format "~a header is required" header-name)]
      ['malformed (format "~a header is malformed" header-name)]
      [v (and (not (equal? v expected)) (format "~a header does not match the request" header-name))]))
  (or (check "MCP-Protocol-Version" version)
      (check "Mcp-Method" name)
      (and (equal? name "tools/call") (check "Mcp-Name" (hash-ref params 'name #f)))))

;; Headers String -> (or String #f 'malformed)
;; a header value with the =?base64?...?= sentinel decoded; #f when absent, 'malformed when the
;; sentinel does not hold valid base64 of UTF-8 text
(define (decoded-header header name)
  (match (header name)
    [#f #f]
    [(regexp #px"^=\\?base64\\?(.*)\\?=$" (list _ b64)) (or (decode-base64-text b64) 'malformed)]
    [raw raw]))

;; String -> (or String #f)
(define (decode-base64-text s)
  (and (regexp-match? #px"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$" s)
       (with-handlers ([exn:fail:contract? (λ (_) #f)])
         (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 s))))))

;; McpServer Boolean JSObject Boolean -> JSObject
;; modern results say they are complete and name the server; cacheable ones add ttlMs and cacheScope
;; ("private": what a caller sees may depend on who they are)
(define (finish srv modern? result cache?)
  (cond [(not modern?) result]
        [else
         (define r (hash-set* result 'resultType "complete"
                              '_meta (hasheq server-info-key (server-info srv))))
         (if cache? (hash-set* r 'ttlMs (mcp-server-ttl-ms srv) 'cacheScope "private") r)]))

;; (McpServer -> JSObject) Boolean -> Serve
;; a Serve for a method that always succeeds with the built result
(define (simple build cache?)
  (λ (srv ctx scopes id params modern?) (rpc-result id (finish srv modern? (build srv) cache?))))

;; McpServer -> JSObject
;; every tool is listed; the scope is enforced when a tool is called
(define (tools-list srv) (hasheq 'tools (map tool->jsexpr (mcp-server-tools srv))))

;; McpServer Ctx (listof String) Id JSObject Boolean -> (or JSExpr MissingScope)
;; runs a tool: an unknown one is -32602, one outside the caller's scopes is a MissingScope
(define (serve-call srv ctx scopes id params modern?)
  (define name (hash-ref params 'name #f))
  (define args (hash-ref params 'arguments (hasheq)))
  (define t (and (string? name) (findf (λ (t) (equal? (tool-name t) name)) (mcp-server-tools srv))))
  (cond [(not (string? name)) (rpc-error id invalid-params "params.name is required")]
        [(not t) (rpc-error id invalid-params (format "unknown tool: ~a" name))]
        [(not (hash? args)) (rpc-error id invalid-params "params.arguments must be an object")]
        [(and (tool-scope t) (not (member (tool-scope t) scopes))) (missing-scope (tool-scope t))]
        [else (rpc-result id (finish srv modern? (call-result (call-tool srv t ctx args)) #f))]))

;; McpServer Tool Ctx JSObject -> ToolResult
;; runs a tool; bad arguments become a failed call naming the field, and so do the exceptions the
;; app's hook recognises (the others escape)
(define (call-tool srv t ctx args)
  (with-handlers ([exn:mcp:invalid-argument?
                   (λ (e)
                     (define field (exn:mcp:invalid-argument-field e))
                     (tool-error (hasheq 'error "invalid_argument" 'field field
                                         'message (string-trim (format "~a ~a" field (exn-message e))))))]
                  [exn:fail? (λ (e) (or ((mcp-server-tool-failure srv) e) (raise e)))])
    ((tool-handler t) ctx args)))

;; ToolResult -> JSObject
;; the tools/call result: the content as text and as structuredContent
(define (call-result r)
  (define content (tool-result-content r))
  (hasheq 'content (list (hasheq 'type "text" 'text (jsexpr->string content)))
          'structuredContent content
          'isError (tool-result-error? r)))

;; McpServer -> JSObject
(define (server-info srv) (hasheq 'name (mcp-server-name srv) 'version (mcp-server-version srv)))

;; McpServer -> JSObject
(define (discover-result srv)
  (with-instructions srv (hasheq 'supportedVersions all-versions 'capabilities (capabilities))))

;; McpServer JSObject -> JSObject
(define (with-instructions srv result)
  (define instructions (mcp-server-instructions srv))
  (if instructions (hash-set result 'instructions instructions) result))

;; -> JSObject
;; the capabilities the method table implies
(define (capabilities)
  (for*/hasheq ([m (in-list methods)] [c (in-value (method-capability m))] #:when c)
    (values c (hasheq))))

;; McpServer JSObject -> JSObject
;; the legacy handshake: the client's version if we speak it, else our newest legacy one
(define (initialize-result srv params)
  (define requested (hash-ref params 'protocolVersion #f))
  (with-instructions srv
    (hasheq 'protocolVersion (if (member requested legacy-versions) requested (first legacy-versions))
            'capabilities (capabilities)
            'serverInfo (server-info srv))))

;; the methods served besides `initialize`; drives both dispatch and the advertised capabilities
(define methods
  (list (method "ping" #f (simple (λ (srv) (hasheq)) #f))
        (method "server/discover" #f (simple discover-result #t))
        (method "tools/list" 'tools (simple tools-list #t))
        (method "tools/call" 'tools serve-call)))

(module+ test
  (require rackunit)
  (define-tool (echo ctx)
    #:description "Echoes."
    #:read-only
    #:args [in (list [text (string 1 5)])]
    (hasheq 'text (car in) 'ctx (format "~a" ctx)))
  (define-tool (secret ctx) #:description "Needs a scope." #:scope "decks" (hasheq 'ok #t))
  (define-tool (explode ctx) #:description "Raises." (error "boom"))
  (define srv (make-mcp-server "orq" "1.0" (list echo secret explode) #:instructions "Hi"
                               #:tool-failure (λ (e) (and (regexp-match? #rx"boom" (exn-message e))
                                                          (tool-error (hasheq 'error "boom"))))))
  (define meta (hasheq version-key "2026-07-28" capabilities-key (hasheq)))
  (define (headers . kvs) (λ (name) (for/first ([p (in-list kvs)] #:when (string-ci=? (car p) name)) (cdr p))))
  (define modern-headers (headers '("MCP-Protocol-Version" . "2026-07-28") '("Mcp-Method" . "tools/list")))
  (define (ask method params [h (headers)] #:scopes [scopes '("decks")])
    (mcp-dispatch srv 'me scopes (rpc-request 1 method params) h))
  (define (code-of reply) (response-error-code reply))
  (define (result-of reply) (hash-ref reply 'result))
  (define (tool-call name args #:version [v "2026-07-28"])
    (ask "tools/call" (hasheq 'name name 'arguments args '_meta (hasheq version-key v capabilities-key (hasheq)))
         (headers (cons "MCP-Protocol-Version" v) '("Mcp-Method" . "tools/call") (cons "Mcp-Name" name))))

  (test-case "server/discover lists versions and is cacheable"
    (define r (result-of (ask "server/discover" (hasheq))))
    (check-equal? (hash-ref r 'supportedVersions) '("2026-07-28" "2025-11-25" "2025-06-18"))
    (check-equal? (hash-ref r 'resultType) "complete")
    (check-equal? (hash-ref r 'cacheScope) "private")
    (check-equal? (hash-ref r 'ttlMs) 60000)
    (check-equal? (hash-ref r 'instructions) "Hi")
    (check-equal? (hash-ref (hash-ref r '_meta) server-info-key) (hasheq 'name "orq" 'version "1.0")))
  (test-case "a modern tools/list carries resultType, ttlMs and cacheScope, and lists every tool whatever the scopes"
    (define params (hasheq '_meta meta))
    (define r (result-of (ask "tools/list" params modern-headers)))
    (check-equal? (map (λ (t) (hash-ref t 'name)) (hash-ref r 'tools)) '("echo" "secret" "explode"))
    (check-equal? (list (hash-ref r 'resultType) (hash-ref r 'ttlMs) (hash-ref r 'cacheScope)) '("complete" 60000 "private"))
    (check-equal? (map (λ (t) (hash-ref t 'name)) (hash-ref (result-of (ask "tools/list" params modern-headers #:scopes '())) 'tools))
                  '("echo" "secret" "explode")))
  (test-case "server/discover ignores _meta versions and protocol headers"
    (for ([params (list (hasheq) (hasheq '_meta (hasheq version-key "2025-11-25")) (hasheq '_meta (hasheq version-key "2030-01-01")))]
          [h (list (headers) (headers '("MCP-Protocol-Version" . "2030-01-01") '("Mcp-Method" . "tools/list"))
                   (headers '("MCP-Protocol-Version" . "=?base64?!!!?=")))])
      (check-equal? (hash-ref (result-of (ask "server/discover" params h)) 'resultType) "complete")))
  (test-case "capabilities come from the method table"
    (check-equal? (hash-ref (result-of (ask "server/discover" (hasheq))) 'capabilities) (hasheq 'tools (hasheq)))
    (check-equal? (hash-ref (result-of (ask "initialize" (hasheq 'protocolVersion "2025-11-25"))) 'capabilities) (hasheq 'tools (hasheq))))
  (test-case "duplicate tool names are refused"
    (check-exn #rx"duplicate tool name" (λ () (make-mcp-server "x" "1" (list echo echo)))))
  (test-case "a modern request needs its _meta"
    (check-equal? (code-of (ask "tools/list" (hasheq) (headers '("MCP-Protocol-Version" . "2026-07-28")))) invalid-params)
    (check-equal? (code-of (ask "tools/list" (hasheq '_meta (hasheq version-key "2026-07-28")) modern-headers)) invalid-params)
    (check-equal? (code-of (ask "tools/list" (hasheq '_meta (hasheq version-key 7)) modern-headers)) invalid-params))
  (test-case "an unsupported version lists the supported ones"
    (define e (hash-ref (ask "tools/list" (hasheq '_meta (hasheq version-key "2030-01-01" capabilities-key (hasheq))) modern-headers) 'error))
    (check-equal? (hash-ref e 'code) unsupported-version)
    (check-equal? (hash-ref e 'data) (hasheq 'supported all-versions 'requested "2030-01-01"))
    (check-equal? (code-of (ask "tools/list" (hasheq) (headers '("MCP-Protocol-Version" . "1999-01-01")))) unsupported-version))
  (test-case "routing headers must be present and match"
    (define params (hasheq '_meta meta))
    (check-equal? (code-of (ask "tools/list" params (headers))) header-mismatch)
    (check-equal? (code-of (ask "tools/list" params (headers '("MCP-Protocol-Version" . "2026-07-28")))) header-mismatch)
    (check-equal? (code-of (ask "tools/list" params (headers '("MCP-Protocol-Version" . "2026-07-28") '("Mcp-Method" . "tools/call")))) header-mismatch)
    (check-equal? (code-of (ask "tools/list" params (headers '("MCP-Protocol-Version" . "2025-11-25") '("Mcp-Method" . "tools/list")))) header-mismatch)
    (check-equal? (code-of (ask "tools/call" (hasheq 'name "echo" '_meta meta)
                                (headers '("MCP-Protocol-Version" . "2026-07-28") '("Mcp-Method" . "tools/call")))) header-mismatch)
    (check-equal? (code-of (ask "tools/call" (hasheq 'name "echo" '_meta meta)
                                (headers '("MCP-Protocol-Version" . "2026-07-28") '("Mcp-Method" . "tools/call") '("Mcp-Name" . "other")))) header-mismatch)
    (check-pred hash? (result-of (ask "tools/call" (hasheq 'name "echo" 'arguments (hasheq 'text "x") '_meta meta)
                                      (headers '("mcp-protocol-version" . "2026-07-28") '("MCP-METHOD" . "tools/call") '("Mcp-Name" . "echo"))))))
  (test-case "header values may use the base64 sentinel"
    (define (b64 s) (format "=?base64?~a?=" (bytes->string/utf-8 (base64-encode (string->bytes/utf-8 s) #""))))
    (check-pred hash? (result-of (ask "tools/list" (hasheq '_meta meta)
                                      (headers (cons "MCP-Protocol-Version" (b64 "2026-07-28")) (cons "Mcp-Method" (b64 "tools/list"))))))
    (check-equal? (code-of (ask "tools/list" (hasheq '_meta meta)
                                (headers (cons "MCP-Protocol-Version" (b64 "2026-07-28")) (cons "Mcp-Method" (b64 "tools/call")))))
                  header-mismatch)
    (define (problem h) (hash-ref (hash-ref (ask "tools/list" (hasheq '_meta meta) h) 'error) 'message))
    (define (malformed-method m) (headers '("MCP-Protocol-Version" . "2026-07-28") (cons "Mcp-Method" m)))
    (for ([m '("=?base64?!!!?=" "=?base64?dG9vbHM?=" "=?base64?/w==?=")])  ; bad alphabet, bad padding, not UTF-8
      (check-equal? (code-of (ask "tools/list" (hasheq '_meta meta) (malformed-method m))) header-mismatch)
      (check-regexp-match #rx"malformed" (problem (malformed-method m))))
    (check-regexp-match #rx"required" (problem (headers '("MCP-Protocol-Version" . "2026-07-28"))))
    (check-regexp-match #rx"does not match" (problem (headers '("MCP-Protocol-Version" . "2026-07-28") '("Mcp-Method" . "x"))))
    (check-equal? (code-of (ask "tools/list" (hasheq) (headers '("MCP-Protocol-Version" . "=?base64?!!!?=")))) header-mismatch)
    (check-pred hash? (result-of (tool-call "echo" (hasheq 'text "x")))))
  (test-case "legacy initialize answers on both legacy versions and mints no session"
    (for ([v legacy-versions])
      (define r (result-of (ask "initialize" (hasheq 'protocolVersion v 'capabilities (hasheq) 'clientInfo (hasheq)))))
      (check-equal? (hash-ref r 'protocolVersion) v)
      (check-equal? (hash-ref r 'serverInfo) (hasheq 'name "orq" 'version "1.0"))
      (check-false (hash-has-key? r 'resultType)))
    (check-equal? (hash-ref (result-of (ask "initialize" (hasheq 'protocolVersion "2030-01-01"))) 'protocolVersion) "2025-11-25"))
  (test-case "legacy requests after initialize work without _meta"
    (for ([h (list (headers) (headers '("MCP-Protocol-Version" . "2025-06-18")))])
      (define r (result-of (ask "tools/list" (hasheq) h)))
      (check-equal? (length (hash-ref r 'tools)) 3)
      (check-false (hash-has-key? r 'resultType)))
    (check-equal? (result-of (ask "ping" (hasheq))) (hasheq)))
  (test-case "notifications are accepted, unknown methods and failures are errors"
    (check-equal? (mcp-dispatch srv 'me '() (rpc-notification "notifications/initialized" (hasheq)) (headers)) 'accepted)
    (check-equal? (code-of (ask "resources/list" (hasheq))) method-not-found)
    (check-equal? (code-of (mcp-dispatch srv 'me '() (rpc-failure 'null parse-error "x") (headers))) parse-error))
  (test-case "tools/call: success, bad arguments, unknown tool, scope, failures"
    (define ok (result-of (tool-call "echo" (hasheq 'text "hi"))))
    (check-equal? (hash-ref ok 'isError) #f)
    (check-equal? (hash-ref ok 'structuredContent) (hasheq 'text "hi" 'ctx "me"))
    (check-equal? (hash-ref (car (hash-ref ok 'content)) 'type) "text")
    (check-equal? (string->jsexpr (hash-ref (car (hash-ref ok 'content)) 'text)) (hasheq 'text "hi" 'ctx "me"))
    (check-equal? (hash-ref ok 'resultType) "complete")
    (define bad (result-of (tool-call "echo" (hasheq 'text ""))))
    (check-equal? (hash-ref bad 'isError) #t)
    (check-equal? (hash-ref (hash-ref bad 'structuredContent) 'field) "text")
    (check-regexp-match #rx"^text must be" (hash-ref (hash-ref bad 'structuredContent) 'message))
    (check-equal? (code-of (tool-call "nope" (hasheq))) invalid-params)
    (check-equal? (code-of (ask "tools/call" (hasheq 'name "echo" 'arguments 3))) invalid-params)
    (check-equal? (missing-scope-name (mcp-dispatch srv 'me '() (rpc-request 1 "tools/call" (hasheq 'name "secret")) (headers))) "decks")
    (check-equal? (hash-ref (hash-ref (result-of (tool-call "explode" (hasheq))) 'structuredContent) 'error) "boom")
    (check-true (hash-ref (result-of (tool-call "explode" (hasheq))) 'isError)))
  (test-case "an exception the app does not recognise escapes"
    (define plain (make-mcp-server "orq" "1" (list explode)))
    (check-exn #rx"boom" (λ () (mcp-dispatch plain 'me '() (rpc-request 1 "tools/call" (hasheq 'name "explode")) (headers))))))
