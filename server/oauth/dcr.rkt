#lang racket/base
;; Dynamic client registration (RFC 7591), narrowed to what this server serves: public clients
;; (no secret) using the authorization code flow, with refresh tokens if they like.
(require racket/contract/base racket/match racket/list racket/string
         "data.rkt" "uri.rkt" "base64url.rkt" "clean.rkt")
(provide (contract-out
          [register (->* (any/c real?) (#:new-id (-> string?)) (or/c client? oauth-error?))]
          [client->registration-jsexpr (-> client? real? any/c)]))

(define max-redirect-uris 20)
(define allowed-grant-types '("authorization_code" "refresh_token"))

;; String String -> OAuthError
(define (invalid-metadata fmt . args) (oauth-error "invalid_client_metadata" (apply format fmt args) 400))

;; JSExpr Integer [#:new-id (-> String)] -> (or Client OAuthError)
;; validates a registration request and makes the Client it asks for (not yet stored). The id is
;; random, so a registered client can be told from a metadata-document one by its shape.
(define (register req now #:new-id [new-id (λ () (random-base64url 16))])
  (define (field key [default #f]) (if (hash? req) (hash-ref req key default) #f))
  (define uris (field 'redirect_uris))
  (define name (field 'client_name))
  (cond
    [(not (hash? req)) (invalid-metadata "the request must be a JSON object")]
    [(not (and (list? uris) (pair? uris) (<= (length uris) max-redirect-uris)))
     (oauth-error "invalid_redirect_uri" "redirect_uris must be a non-empty list of at most 20 URIs" 400)]
    [(not (andmap valid-redirect-uri? uris))
     (oauth-error "invalid_redirect_uri" "redirect URIs must be https, or http on a loopback address" 400)]
    [(not (equal? (field 'token_endpoint_auth_method "none") "none"))
     (invalid-metadata "only token_endpoint_auth_method none is supported")]
    [(not (grant-types-ok? (field 'grant_types '("authorization_code"))))
     (invalid-metadata "grant_types must be a non-empty subset of authorization_code and refresh_token")]
    [(not (equal? (field 'response_types '("code")) '("code")))
     (invalid-metadata "response_types must be [\"code\"]")]
    [(not (or (not name) (string? name))) (invalid-metadata "client_name must be a string")]
    [else (client (new-id) 'registered (clean-name name "Unnamed application")
                  (https-uri-or-false (field 'client_uri)) #f uris
                  (and (member "refresh_token" (field 'grant_types '("authorization_code"))) #t) now #f)]))

;; Any -> Boolean
(define (grant-types-ok? v)
  (and (list? v) (pair? v) (andmap (λ (g) (member g allowed-grant-types)) v) (not (check-duplicates v))))

;; Client Real -> JSExpr
;; the RFC 7591 response for a freshly registered client; it echoes the grant types granted
(define (client->registration-jsexpr c now)
  (hasheq 'client_id (client-id c)
          'client_id_issued_at (inexact->exact (floor now))
          'client_name (client-name c)
          'redirect_uris (client-redirect-uris c)
          'token_endpoint_auth_method "none"
          'grant_types (if (client-refresh? c) allowed-grant-types '("authorization_code"))
          'response_types '("code")))

(module+ test
  (require rackunit)
  (define (ok . kvs) (apply hasheq 'redirect_uris '("https://app.example/cb") kvs))
  (define (code-of r) (and (oauth-error? r) (oauth-error-code r)))

  (test-case "a minimal request registers an unverified public client"
    (define c (register (ok) 50 #:new-id (λ () "id1")))
    (check-equal? (client-id c) "id1")
    (check-equal? (client-kind c) 'registered)
    (check-equal? (client-name c) "Unnamed application")
    (check-false (client-refresh? c) "the default grant type is authorization_code alone")
    (check-equal? (hash-ref (client->registration-jsexpr c 50) 'grant_types) '("authorization_code"))
    (check-false (client-expires c))
    (check-equal? (client-created c) 50))
  (test-case "name and URI are kept when sane"
    (define c (register (ok 'client_name " My\u0007 App " 'client_uri "https://app.example"
                            'grant_types '("authorization_code" "refresh_token")
                            'response_types '("code") 'token_endpoint_auth_method "none")
                        0))
    (check-equal? (client-name c) "My App")
    (check-true (client-refresh? c))
    (check-equal? (hash-ref (client->registration-jsexpr c 0) 'grant_types) '("authorization_code" "refresh_token"))
    (check-equal? (client-uri c) "https://app.example"))
  (test-case "refusals"
    (check-equal? (code-of (register '(1) 0)) "invalid_client_metadata")
    (check-equal? (code-of (register (hasheq) 0)) "invalid_redirect_uri")
    (check-equal? (code-of (register (hasheq 'redirect_uris '()) 0)) "invalid_redirect_uri")
    (check-equal? (code-of (register (hasheq 'redirect_uris "https://app.example/cb") 0)) "invalid_redirect_uri")
    (check-equal? (code-of (register (hasheq 'redirect_uris '("http://app.example/cb")) 0)) "invalid_redirect_uri")
    (check-equal? (code-of (register (hasheq 'redirect_uris '("myapp://cb")) 0)) "invalid_redirect_uri")
    (check-equal? (code-of (register (hasheq 'redirect_uris (make-list 21 "https://a.example/cb")) 0)) "invalid_redirect_uri")
    (check-equal? (code-of (register (ok 'token_endpoint_auth_method "client_secret_basic") 0)) "invalid_client_metadata")
    (check-equal? (code-of (register (ok 'grant_types '("password")) 0)) "invalid_client_metadata")
    (check-equal? (code-of (register (ok 'grant_types '("implicit")) 0)) "invalid_client_metadata")
    (check-equal? (code-of (register (ok 'grant_types '()) 0)) "invalid_client_metadata")
    (check-equal? (code-of (register (ok 'response_types '("token")) 0)) "invalid_client_metadata")
    (check-equal? (code-of (register (ok 'client_name 5) 0)) "invalid_client_metadata"))
  (test-case "the response never has a secret"
    (define j (client->registration-jsexpr (register (ok) 7) 7))
    (check-equal? (hash-ref j 'token_endpoint_auth_method) "none")
    (check-equal? (hash-ref j 'client_id_issued_at) 7)
    (check-false (hash-has-key? j 'client_secret))))
