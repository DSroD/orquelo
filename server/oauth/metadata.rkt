#lang racket/base
;; The endpoint paths and where the discovery documents live (the documents are in json.rkt). The paths
;; are fixed here so the documents and the app's routes cannot drift apart: the app mounts its handlers at `authorize-path`, `token-path` and `register-path`.
(require racket/contract/base racket/match "data.rkt")
(provide (contract-out
          [authorize-path string?]
          [token-path string?]
          [register-path string?]
          [protected-resource-metadata-url (-> oauth-app? string?)]
          [validate-app! (-> oauth-app? oauth-app?)]))

(define authorize-path "/oauth/authorize")
(define token-path "/oauth/token")
(define register-path "/oauth/register")

;; OAuthApp -> String
;; where the resource's metadata is served: its well-known path inserted before the resource's own
;; path (RFC 9728 section 3.1)
(define (protected-resource-metadata-url app)
  (match (regexp-match #rx"^(https?://[^/]+)(/.*)?$" (oauth-app-resource app))
    [(list _ origin path) (string-append origin "/.well-known/oauth-protected-resource" (or path ""))]
    [#f (string-append (oauth-app-resource app) "/.well-known/oauth-protected-resource")]))

(define origin-rx #px"^(?:https://[A-Za-z0-9.-]+|http://(?:127\\.0\\.0\\.1|localhost|\\[::1\\]))(?::[0-9]{1,5})?")

;; OAuthApp -> OAuthApp
;; the app itself, when its issuer is an origin and its resource a URL without query or fragment,
;; both https or on a loopback host; raises exn:fail:contract otherwise
(define (validate-app! app)
  (unless (regexp-match? (pregexp (string-append (object-name origin-rx) "$")) (oauth-app-issuer app))
    (raise-arguments-error 'oauth-app "issuer must be an https (or loopback http) origin without path"
                           "issuer" (oauth-app-issuer app)))
  (unless (regexp-match? (pregexp (string-append (object-name origin-rx) "(?:/[^?#\\s]*)?$")) (oauth-app-resource app))
    (raise-arguments-error 'oauth-app "resource must be an https (or loopback http) URL without query or fragment"
                           "resource" (oauth-app-resource app)))
  app)

(module+ test
  (require rackunit)
  (define app (oauth-app "https://orq.example" "https://orq.example/mcp" '(("decks" . "Decks") ("results" . "Results"))
                         values (λ (s e) #t) (λ (u) (error "no")) (λ () 0)))
  (test-case "the protected resource metadata URL"
    (check-equal? (protected-resource-metadata-url app)
                  "https://orq.example/.well-known/oauth-protected-resource/mcp"))
  (test-case "apps are validated"
    (define (with issuer resource) (struct-copy oauth-app app [issuer issuer] [resource resource]))
    (check-eq? (validate-app! app) app)
    (check-true (oauth-app? (validate-app! (with "http://127.0.0.1:8080" "http://127.0.0.1:8080/mcp"))))
    (check-true (oauth-app? (validate-app! (with "http://localhost:8080" "http://localhost:8080"))))
    (for ([bad (list (with "http://orq.example" "https://orq.example/mcp")
                     (with "https://orq.example/" "https://orq.example/mcp")
                     (with "https://orq.example/base" "https://orq.example/mcp")
                     (with "https://orq.example?x=1" "https://orq.example/mcp")
                     (with "https://orq.example" "https://orq.example/mcp?x=1")
                     (with "https://orq.example" "https://orq.example/mcp#f")
                     (with "https://orq.example" "http://orq.example/mcp")
                     (with "https://orq.example" "orq"))])
      (check-exn exn:fail:contract? (λ () (validate-app! bad)))))
  (test-case "the metadata URL is total"
    (check-equal? (protected-resource-metadata-url (struct-copy oauth-app app [resource "weird"]))
                  "weird/.well-known/oauth-protected-resource")))
