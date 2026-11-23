#lang racket/base
;; The URIs OAuth clients hand us: redirect URIs and CIMD client ids. Parsed with regexps rather
;; than net/url on purpose: the accepted language is small and fixed, so what we check is exactly
;; what a browser will follow.
(require racket/contract/base racket/match)
(provide (contract-out
          [valid-redirect-uri? (-> any/c boolean?)]
          [redirect-matches? (-> string? string? boolean?)]
          [redirect-host (-> string? string?)]
          [cimd-url? (-> any/c boolean?)]
          [cimd-url-parts (-> any/c (or/c (cons/c string? string?) #f))]))

(define max-uri-length 2048)
(define tail "([/?][^#\\s\\\\]*)?$")
;; http only on a loopback host (RFC 8252 section 7.3); the optional port is group 2
(define loopback-rx (pregexp (string-append "^http://(127\\.0\\.0\\.1|\\[::1\\]|localhost)(?::([0-9]{1,5}))?" tail)))
(define https-rx (pregexp (string-append "^https://([A-Za-z0-9.-]+|\\[[0-9a-fA-F:.]+\\])(?::([0-9]{1,5}))?" tail)))
(define cimd-rx #px"^https://([A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+)(/[A-Za-z0-9._~!$&'()*+,;=:@%/-]*)$")

;; Any -> Boolean
;; printable ASCII only, so no control character, space or non-ASCII look-alike can pass
(define (plain-uri-text? v)
  (and (string? v) (<= (string-length v) max-uri-length) (regexp-match? #px"^[!-~]+$" v)))

;; Regexp String -> (or (list String (or String #f) String) #f)
;; host, port and the rest of a URI that matches, with a port in range
(define (parse rx s)
  (match (regexp-match rx s)
    [(list _ host port rest)
     (and (or (not port) (<= (string->number port) 65535))
          (list host port (or rest "")))]
    [_ #f]))

;; Any -> Boolean
;; https, or http on a loopback host; no userinfo, no fragment, no private-use scheme
(define (valid-redirect-uri? v)
  (and (plain-uri-text? v)
       (or (parse https-rx v) (parse loopback-rx v))
       #t))

;; String String -> Boolean
;; does the `requested` redirect URI match the `registered` one: exactly, except that for a
;; loopback address the port may differ
(define (redirect-matches? registered requested)
  (or (equal? registered requested)
      (match* ((parse loopback-rx registered) (parse loopback-rx requested))
        [((list h1 _ r1) (list h2 _ r2)) (and (equal? h1 h2) (equal? r1 r2) (valid-redirect-uri? requested))]
        [(_ _) #f])))

;; String -> String
;; the host a redirect URI sends the user to, for display (with its port unless loopback)
(define (redirect-host uri)
  (match (or (parse https-rx uri) (parse loopback-rx uri))
    [(list host port _) (if (and port (regexp-match? #rx"^https" uri)) (string-append host ":" port) host)]
    [#f ""]))

;; Any -> (or (cons String String) #f)
;; host and path of a CIMD client id: https on the default port, a DNS name (not an IP address),
;; a non-empty path without dot segments, no query, fragment or userinfo
(define (cimd-url-parts v)
  (match (and (plain-uri-text? v) (regexp-match cimd-rx v))
    [(list _ host path)
     (and (not (regexp-match? #px"^[0-9.]+$" host))
          (not (regexp-match? #px"(^|/)\\.\\.?(/|$)" path))
          (cons host path))]
    [_ #f]))

;; Any -> Boolean
(define (cimd-url? v) (and (cimd-url-parts v) #t))

(module+ test
  (require rackunit)
  (test-case "valid redirect URIs"
    (for ([u '("https://app.example/cb" "https://app.example:8443/cb?x=1" "http://127.0.0.1:8765/cb"
               "http://localhost/cb" "http://[::1]:9/cb" "https://app.example")])
      (check-true (valid-redirect-uri? u) u)))
  (test-case "invalid redirect URIs"
    (for ([u '("http://app.example/cb" "myapp://cb" "https://app.example/cb#frag" "https://user@app.example/cb"
               "https://app.example\\@evil/cb" "http://127.0.0.1:99999/cb" "javascript:alert(1)" "/relative"
               "https://app.example/c b" "https://app.example/é" "" "http://127.0.0.1.evil.com/cb")])
      (check-false (valid-redirect-uri? u) u))
    (check-false (valid-redirect-uri? 5))
    (check-false (valid-redirect-uri? (string-append "https://a.example/" (make-string 2100 #\a)))))
  (test-case "redirect matching"
    (check-true (redirect-matches? "https://app.example/cb" "https://app.example/cb"))
    (check-false (redirect-matches? "https://app.example/cb" "https://app.example/cb2"))
    (check-false (redirect-matches? "https://app.example/cb" "https://app.example:444/cb"))
    (check-true (redirect-matches? "http://127.0.0.1/cb" "http://127.0.0.1:5555/cb"))
    (check-true (redirect-matches? "http://[::1]:1/cb" "http://[::1]:2/cb"))
    (check-false (redirect-matches? "http://127.0.0.1/cb" "http://localhost:5555/cb"))
    (check-false (redirect-matches? "http://127.0.0.1/cb" "http://127.0.0.1:5555/other"))
    (check-false (redirect-matches? "http://127.0.0.1/cb" "http://127.0.0.1:70000/cb")))
  (test-case "redirect host"
    (check-equal? (redirect-host "https://app.example:8443/cb") "app.example:8443")
    (check-equal? (redirect-host "https://app.example/cb") "app.example")
    (check-equal? (redirect-host "http://127.0.0.1:8080/cb") "127.0.0.1"))
  (test-case "CIMD URLs"
    (check-true (cimd-url? "https://app.example/oauth/client.json"))
    (check-equal? (cimd-url-parts "https://app.example/a/b") (cons "app.example" "/a/b"))
    (for ([u '("http://app.example/c.json" "https://app.example" "https://app.example:443/c.json"
               "https://app.example/c.json?x=1" "https://app.example/c.json#f" "https://u@app.example/c.json"
               "https://127.0.0.1/c.json" "https://[::1]/c.json" "https://localhost/c.json"
               "https://app.example/a/../c.json" "https://app.example/./c.json" "https://app.example./c.json")])
      (check-false (cimd-url? u) u))
    (check-false (cimd-url? #f))))
