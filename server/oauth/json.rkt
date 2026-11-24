#lang racket/base
;; The wire encoders of the OAuth server: every JSON document it answers with, as a function of
;; plain values. The endpoints and the app's routes use these, so the documents live in one place.
(require racket/contract/base racket/string json "data.rkt" "dcr.rkt" "metadata.rkt")
(provide (contract-out
          [client->jsexpr (-> client? real? jsexpr?)]
          [token-response->jsexpr (-> string? (or/c string? #f) (listof string?) exact-nonnegative-integer? jsexpr?)]
          [oauth-error->jsexpr (-> oauth-error? jsexpr?)]
          [protected-resource-metadata (-> oauth-app? jsexpr?)]
          [authorization-server-metadata (-> oauth-app? jsexpr?)]))

;; Client Real -> JSExpr
;; the RFC 7591 response for a freshly registered client, registered at `now`; it echoes the grant
;; types granted
(define (client->jsexpr c now)
  (hasheq 'client_id (client-id c)
          'client_id_issued_at (inexact->exact (floor now))
          'client_name (client-name c)
          'redirect_uris (client-redirect-uris c)
          'token_endpoint_auth_method "none"
          'grant_types (if (client-refresh? c) allowed-grant-types '("authorization_code"))
          'response_types '("code")))

;; String (or String #f) (listof String) Natural -> JSExpr
;; the RFC 6749 token response: the access token valid for `expires-in` seconds, the refresh token if
;; one was issued, and the granted scopes
(define (token-response->jsexpr access refresh scopes expires-in)
  (define base (hasheq 'access_token access 'token_type "Bearer" 'expires_in expires-in
                       'scope (string-join scopes " ")))
  (if refresh (hash-set base 'refresh_token refresh) base))

;; OAuthError -> JSExpr
;; the RFC 6749 error body
(define (oauth-error->jsexpr e)
  (hasheq 'error (oauth-error-code e) 'error_description (oauth-error-description e)))

;; OAuthApp -> (listof String)
(define (scope-names app) (map car (oauth-app-scopes app)))

;; OAuthApp -> JSExpr
;; RFC 9728 protected resource metadata
(define (protected-resource-metadata app)
  (hasheq 'resource (oauth-app-resource app)
          'authorization_servers (list (oauth-app-issuer app))
          'scopes_supported (scope-names app)
          'bearer_methods_supported '("header")))

;; OAuthApp -> JSExpr
;; RFC 8414 authorization server metadata
(define (authorization-server-metadata app)
  (define issuer (oauth-app-issuer app))
  (hasheq 'issuer issuer
          'authorization_endpoint (string-append issuer authorize-path)
          'token_endpoint (string-append issuer token-path)
          'registration_endpoint (string-append issuer register-path)
          'scopes_supported (scope-names app)
          'response_types_supported '("code")
          'grant_types_supported '("authorization_code" "refresh_token")
          'code_challenge_methods_supported '("S256")
          'token_endpoint_auth_methods_supported '("none")
          'authorization_response_iss_parameter_supported #t
          'client_id_metadata_document_supported #t))

(module+ test
  (require rackunit)
  (define app (oauth-app "https://orq.example" "https://orq.example/mcp" '(("decks" . "Decks") ("results" . "Results"))
                         values (λ (s e) #t) (λ (u) (error "no")) (λ () 0)))
  (define (a-client refresh?)
    (client "id1" 'registered "App" #f #f '("https://app.example/cb") refresh? 50 #f))
  (test-case "the registration response echoes the grants given"
    (define j (client->jsexpr (a-client #f) 50.7))
    (check-equal? (hash-ref j 'client_id) "id1")
    (check-equal? (hash-ref j 'client_id_issued_at) 50)
    (check-equal? (hash-ref j 'grant_types) '("authorization_code"))
    (check-equal? (hash-ref j 'token_endpoint_auth_method) "none")
    (check-false (hash-has-key? j 'client_secret))
    (check-equal? (hash-ref (client->jsexpr (a-client #t) 0) 'grant_types) '("authorization_code" "refresh_token"))
    (check-true (jsexpr? j)))
  (test-case "the token response carries a refresh token only when there is one"
    (check-equal? (token-response->jsexpr "a" #f '("decks" "results") 3600)
                  (hasheq 'access_token "a" 'token_type "Bearer" 'expires_in 3600 'scope "decks results"))
    (check-equal? (hash-ref (token-response->jsexpr "a" "r" '("decks") 3600) 'refresh_token) "r"))
  (test-case "the error body"
    (check-equal? (oauth-error->jsexpr (oauth-error "invalid_grant" "gone" 400))
                  (hasheq 'error "invalid_grant" 'error_description "gone")))
  (test-case "protected resource metadata"
    (check-equal? (protected-resource-metadata app)
                  (hasheq 'resource "https://orq.example/mcp"
                          'authorization_servers '("https://orq.example")
                          'scopes_supported '("decks" "results")
                          'bearer_methods_supported '("header"))))
  (test-case "authorization server metadata"
    (define m (authorization-server-metadata app))
    (check-equal? (hash-ref m 'issuer) "https://orq.example")
    (check-equal? (hash-ref m 'authorization_endpoint) "https://orq.example/oauth/authorize")
    (check-equal? (hash-ref m 'token_endpoint) "https://orq.example/oauth/token")
    (check-equal? (hash-ref m 'registration_endpoint) "https://orq.example/oauth/register")
    (check-equal? (hash-ref m 'code_challenge_methods_supported) '("S256"))
    (check-equal? (hash-ref m 'token_endpoint_auth_methods_supported) '("none"))
    (check-true (hash-ref m 'client_id_metadata_document_supported))
    (check-true (hash-ref m 'authorization_response_iss_parameter_supported))
    (check-equal? (hash-ref m 'scopes_supported) '("decks" "results"))))
