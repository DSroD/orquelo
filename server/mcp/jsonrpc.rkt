#lang racket/base
;; JSON-RPC 2.0 messages for MCP: parsing one message (batches are refused) and building replies.
(require racket/contract/base racket/match json)
(provide (contract-out
          [struct rpc-request ([id (or/c string? exact-integer?)] [method string?] [params hash?])]
          [struct rpc-notification ([method string?] [params hash?])]
          [struct rpc-failure ([id (or/c string? exact-integer? 'null)] [code exact-integer?] [message string?])]
          [parse-message (-> bytes? (or/c rpc-request? rpc-notification? rpc-failure?))]
          [rpc-result (-> (or/c string? exact-integer?) jsexpr? jsexpr?)]
          [rpc-error (->* ((or/c string? exact-integer? 'null) exact-integer? string?) (jsexpr?) jsexpr?)]
          [error-status (-> exact-integer? (integer-in 200 599))]
          [response-error-code (-> jsexpr? (or/c exact-integer? #f))]
          [parse-error exact-integer?]
          [invalid-request exact-integer?]
          [method-not-found exact-integer?]
          [invalid-params exact-integer?]
          [internal-error exact-integer?]
          [header-mismatch exact-integer?]
          [unsupported-version exact-integer?]))

;; An Id is (or String Integer)
;; A RpcRequest is a (rpc-request Id String JSObject): id, method, params
;; A RpcNotification is a (rpc-notification String JSObject)
;; An RpcFailure is a (rpc-failure (or Id 'null) Integer String): the reply a malformed message earns
(struct rpc-request (id method params) #:transparent)
(struct rpc-notification (method params) #:transparent)
(struct rpc-failure (id code message) #:transparent)

(define parse-error -32700)
(define invalid-request -32600)
(define method-not-found -32601)
(define invalid-params -32602)
(define internal-error -32603)
(define header-mismatch -32020)
(define unsupported-version -32022)

;; Bytes -> (or RpcRequest RpcNotification RpcFailure)
;; reads one JSON-RPC message
(define (parse-message body)
  (match (read-single-json body)
    [(? void?) (rpc-failure 'null parse-error "body is not valid JSON")]
    [(? list?) (rpc-failure 'null invalid-request "batches are not supported")]
    [(? hash? h) (parse-object h)]
    [_ (rpc-failure 'null invalid-request "message must be a JSON object")]))

;; Bytes -> (or JSExpr Void)
;; the one JSON value in the body; void when it is empty, malformed or followed by anything but whitespace
(define (read-single-json body)
  (define in (open-input-bytes body))
  (define v (with-handlers ([exn:fail:read? void]) (read-json in)))
  (if (and (not (eof-object? v)) (not (void? v)) (regexp-match? #px"^\\s*$" in)) v (void)))

;; JSObject -> (or RpcRequest RpcNotification RpcFailure)
;; a request, a notification (no id) or the failure a malformed JSON-RPC object earns
(define (parse-object h)
  (define id (hash-ref h 'id 'none))
  (define id-ok? (or (eq? id 'none) (string? id) (exact-integer? id)))
  (define fail-id (if (or (string? id) (exact-integer? id)) id 'null))
  (define params (hash-ref h 'params (hasheq)))
  (define method (hash-ref h 'method #f))
  (cond [(not (equal? (hash-ref h 'jsonrpc #f) "2.0")) (rpc-failure fail-id invalid-request "jsonrpc must be \"2.0\"")]
        [(not id-ok?) (rpc-failure 'null invalid-request "id must be a string or an integer")]
        [(not (string? method)) (rpc-failure fail-id invalid-request "method must be a string")]
        [(not (hash? params)) (rpc-failure fail-id invalid-request "params must be an object")]
        [(eq? id 'none) (rpc-notification method params)]
        [else (rpc-request id method params)]))

;; Id JSExpr -> JSExpr
(define (rpc-result id result)
  (hasheq 'jsonrpc "2.0" 'id id 'result result))

;; (or Id 'null) Integer String [JSExpr] -> JSExpr
(define (rpc-error id code message [data #f])
  (define err (hasheq 'code code 'message message))
  (hasheq 'jsonrpc "2.0" 'id id 'error (if data (hash-set err 'data data) err)))

;; JSExpr -> (or Integer #f)
;; the error code of a reply, if it is an error
(define (response-error-code reply)
  (define err (and (hash? reply) (hash-ref reply 'error #f)))
  (and err (hash-ref err 'code)))

;; Integer -> HTTP status
;; the HTTP status that carries a JSON-RPC error code (Streamable HTTP)
(define (error-status code)
  (cond [(= code method-not-found) 404]
        [(= code internal-error) 500]
        [(memv code (list parse-error invalid-request invalid-params header-mismatch unsupported-version))
         400]
        [else 200]))

(module+ test
  (require rackunit)
  (define (parse s) (parse-message (string->bytes/utf-8 s)))
  (test-case "requests and notifications"
    (check-equal? (parse "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}") (rpc-request 1 "ping" (hasheq)))
    (check-equal? (parse "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"m\",\"params\":{\"x\":1}}")
                  (rpc-request "a" "m" (hasheq 'x 1)))
    (check-equal? (parse "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
                  (rpc-notification "notifications/initialized" (hasheq))))
  (test-case "malformed input is a failure naming the code"
    (check-equal? (rpc-failure-code (parse "{oops")) parse-error)
    (check-equal? (rpc-failure-code (parse "")) parse-error)
    (check-equal? (rpc-failure-code (parse "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"} x")) parse-error)
    (check-equal? (rpc-failure-code (parse "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}{}")) parse-error)
    (check-equal? (parse " {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n ") (rpc-request 1 "ping" (hasheq)))
    (check-equal? (rpc-failure-code (parse "[]")) invalid-request)
    (check-equal? (rpc-failure-code (parse "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]")) invalid-request)
    (check-equal? (rpc-failure-code (parse "3")) invalid-request)
    (check-equal? (rpc-failure-code (parse "{\"id\":1,\"method\":\"ping\"}")) invalid-request)
    (check-equal? (rpc-failure-code (parse "{\"jsonrpc\":\"2.0\",\"id\":1}")) invalid-request)
    (check-equal? (rpc-failure-code (parse "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"m\"}")) invalid-request)
    (check-equal? (rpc-failure-code (parse "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"m\"}")) invalid-request)
    (check-equal? (rpc-failure-code (parse "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":[1]}")) invalid-request)
    (check-equal? (rpc-failure-id (parse "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":3}")) 7))
  (test-case "replies"
    (check-equal? (rpc-result 1 (hasheq 'a 1)) (hasheq 'jsonrpc "2.0" 'id 1 'result (hasheq 'a 1)))
    (check-equal? (rpc-error 'null -32700 "x") (hasheq 'jsonrpc "2.0" 'id 'null 'error (hasheq 'code -32700 'message "x")))
    (check-equal? (response-error-code (rpc-error 1 -32022 "x" (hasheq 'supported '()))) -32022)
    (check-false (response-error-code (rpc-result 1 (hasheq)))))
  (test-case "error codes map to HTTP statuses"
    (check-equal? (map error-status (list parse-error invalid-request method-not-found invalid-params
                                          internal-error header-mismatch unsupported-version 12))
                  '(400 400 404 400 500 400 400 200))))
