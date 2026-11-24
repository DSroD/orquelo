#lang racket/base
;; A scripted OAuth client for the integration tests: authorization code with PKCE against the server
;; at `current-base` (see http-client.rkt), for the client in `current-oauth-client`.
(require rackunit racket/string net/uri-codec net/url json "http-client.rkt")
(provide verifier challenge
         (struct-out oauth-client) current-oauth-client register-client!
         (struct-out tokens) oauth-connect!
         query-of authorize-path pending-id authorize! approve deny token-request refresh-request approved-code)

;; An OAuthClient is an (oauth-client String String): its client_id and its one redirect URI
(struct oauth-client (id redirect))
;; A Tokens is a (tokens String String): the access and refresh tokens of a connection
(struct tokens (access refresh))

;; (parameter/c OAuthClient)
(define current-oauth-client (make-parameter #f))

;; the PKCE pair of RFC 7636 appendix B
(define verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
(define challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

;; -> OAuthClient
;; registers a new public client by dynamic registration
(define (register-client!)
  (define redirect "https://dyn.example/cb")
  (define r (http "POST" "/oauth/register" #:json (hasheq 'client_name "Test Agent" 'redirect_uris (list redirect)
                                                       'grant_types '("authorization_code" "refresh_token"))))
  (check-equal? (resp-status r) 201)
  (oauth-client (hash-ref (resp-json r) 'client_id) redirect))

;; String -> (Hash String String)
(define (query-of url) (for/hash ([kv (in-list (url-query (string->url url)))]) (values (car kv) (cdr kv))))

;; (Listof (Pair Symbol String)) -> String
(define (authorize-path . extra)
  (define c (current-oauth-client))
  (string-append "/oauth/authorize?"
                 (alist->form-urlencoded
                  (append (list (cons 'response_type "code") (cons 'client_id (oauth-client-id c))
                                (cons 'redirect_uri (oauth-client-redirect c))
                                (cons 'code_challenge challenge) (cons 'code_challenge_method "S256") (cons 'state "xyz"))
                          extra))))

;; Resp -> String
;; the pending id a successful authorize redirects to
(define (pending-id r)
  (check-equal? (resp-status r) 302)
  (cadr (regexp-match #px"^/connect/([A-Za-z0-9_-]{43})$" (resp-header r "Location"))))

;; (Pair Symbol String) ... -> String
(define (authorize! . extra) (pending-id (http "GET" (apply authorize-path extra))))

;; String String (Listof String) [#:origin (or String #f)] -> Resp
(define (approve path cookie scopes #:origin [origin (current-base)])
  (http "POST" (format "/api/oauth/requests/~a/approve" path) #:json (hasheq 'scopes scopes) #:cookies (list cookie) #:origin origin))
(define (deny path cookie) (http "POST" (format "/api/oauth/requests/~a/deny" path) #:json (hasheq) #:cookies (list cookie)))

;; String String [#:client String] [#:redirect String] -> Resp
(define (token-request code the-verifier #:client [cid (oauth-client-id (current-oauth-client))]
                       #:redirect [redirect-uri (oauth-client-redirect (current-oauth-client))])
  (http "POST" "/oauth/token"
        #:form (list (cons 'grant_type "authorization_code") (cons 'code code) (cons 'client_id cid)
                     (cons 'redirect_uri redirect-uri) (cons 'code_verifier the-verifier))))

;; String -> Resp
(define (refresh-request token)
  (http "POST" "/oauth/token"
        #:form (list (cons 'grant_type "refresh_token") (cons 'refresh_token token)
                     (cons 'client_id (oauth-client-id (current-oauth-client))))))

;; String String [(Listof String)] -> String
;; the authorization code of an approved request
(define (approved-code id cookie [scopes '("decks" "results")])
  (define r (approve id cookie scopes))
  (check-equal? (resp-status r) 200)
  (hash-ref (query-of (hash-ref (resp-json r) 'redirect_to)) 'code))

;; String (Listof String) -> Tokens
;; the whole flow for the signed-in `cookie`: asks for the scopes, approves them and exchanges the code
(define (oauth-connect! cookie scopes)
  (define id (authorize! (cons 'scope (string-join scopes " "))))
  (define t (token-request (approved-code id cookie scopes) verifier))
  (check-equal? (resp-status t) 200)
  (tokens (hash-ref (resp-json t) 'access_token) (hash-ref (resp-json t) 'refresh_token)))

(module+ test)
