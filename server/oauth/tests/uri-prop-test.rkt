#lang racket/base
;; Properties of URI validation, redirect matching, CIMD client ids and name cleaning.
(require rackcheck rackunit racket/list racket/string
         "../uri.rkt" "../clean.rkt" "prop.rkt" "reference.rkt" "gen.rkt")

;; String -> Boolean
(define (printable-ascii? s) (for/and ([c (in-string s)]) (<= 33 (char->integer c) 126)))

;; String String -> Boolean
(define (starts-with? s prefix) (and (>= (string-length s) (string-length prefix)) (string=? (substring s 0 (string-length prefix)) prefix)))

;; The URI is built from parts, half of them valid-looking (https or http on a loopback host) and the
;; rest adversarial in every part. The loopback-biased generator also yields the unbiased parts
;; of gen:uri-parts, so one property covers both.
(test-case "a redirect URI is accepted exactly when it meets the specification"
  (check-property
   (prop-config 3000)
   (property ([p gen:loopback-parts])
     (equal? (valid-redirect-uri? (parts->string p)) (and (expected-redirect-valid? p) #t)))))

;; Kept although the equality above exists: it does not use expected-redirect-valid?, so it catches
;; gen.rkt and the library misreading the rules in the same way. It also covers text not built from
;; parts: valid-looking URIs with a troublemaker inserted or a character dropped (3), plain
;; generated URIs (1), and short junk (1).
(test-case "an accepted redirect URI is safe to send a browser to"
  (check-property
   (prop-config 3000)
   (property ([s (gen:frequency (list (cons 3 gen:mutated-uri-string) (cons 1 gen:uri-string) (cons 1 (gen:bad-string 40))))])
     (or (not (valid-redirect-uri? s))
         (and (printable-ascii? s) (<= (string-length s) 2048)
              (or (starts-with? s "https://")
                  (and (starts-with? s "http://") (member (authority-host s) '("127.0.0.1" "[::1]" "localhost"))))
              (not (regexp-match? #rx"[#\\\\]" s))
              (not (regexp-match? #rx"^https?://[^/?]*@" s)))))))

;; UriParts String -> UriParts
;; `p` with one component changed
(define (change p what v)
  (case what
    [(port) (struct-copy uri-parts p [port v])]
    [(path) (struct-copy uri-parts p [path v])]
    [(host) (struct-copy uri-parts p [host v])]
    [else (struct-copy uri-parts p [scheme v])]))

(define alternatives
  (hasheq 'port '("8080" "1" "" "65536" "443" #f) 'path '("/other" "/cb" "" "?q")
          'host '("127.0.0.1" "localhost" "[::1]" "app.example") 'scheme '("http" "https")))

;; Gen
;; a loopback-biased URI and a copy of it, usually with one part changed (port, path, host or
;; scheme), sometimes unchanged
(define gen:pair
  (gen:let ([p gen:loopback-parts]
            [what (gen:one-of '(none port port path host scheme))]
            [v (gen:one-of (hash-ref alternatives what '("")))])
    (cons p (if (eq? what 'none) p (change p what v)))))

(test-case "a registered redirect URI matches itself, and a loopback one also matches with another port"
  ;; with r registered and q requested: r matches r when valid; a match implies q is valid too; a
  ;; match is equal text or a loopback URI with another port; and valid loopback URIs that differ
  ;; at most in the port always match
  (check-property
   (prop-config 3000)
   (property ([pq gen:pair])
     (define r (car pq))
     (define q (cdr pq))
     (define rs (parts->string r))
     (define qs (parts->string q))
     (define m (redirect-matches? rs qs))
     (and (or (not (expected-redirect-valid? r)) (redirect-matches? rs rs))
          (or (not m) (not (expected-redirect-valid? r)) (expected-redirect-valid? q))
          ;; equal text always matches; different text only for loopback with another port
          (or (not m) (equal? rs qs)
              (and (equal? (uri-parts-scheme r) "http") (equal? (uri-parts-scheme q) "http")
                   (equal? (uri-parts-host r) (uri-parts-host q))
                   (equal? (uri-parts-path r) (uri-parts-path q))
                   (member (uri-parts-host r) '("127.0.0.1" "[::1]" "localhost"))))
          ;; completeness: both valid loopback URIs that differ at most in the port
          (or (not (and (expected-redirect-valid? r) (expected-redirect-valid? q)
                        (equal? (uri-parts-scheme r) "http") (equal? (uri-parts-scheme q) "http")
                        (equal? (uri-parts-host r) (uri-parts-host q))
                        (equal? (uri-parts-path r) (uri-parts-path q))))
              m)))))

(test-case "a client-metadata URL is accepted only if it is https on a DNS name with a clean path"
  ;; valid URLs (2), valid URLs with a troublemaker inserted (3), plain generated URIs (1), a valid
  ;; host with a fixed path (1)
  (check-property
   (prop-config 3000)
   (property ([s (gen:frequency (list (cons 2 gen:cimd-url) (cons 3 (gen:mutated gen:cimd-url)) (cons 1 gen:uri-string)
                                      (cons 1 (gen:map gen:cimd-host (λ (h) (string-append "https://" h "/c.json"))))))])
     (define parts (cimd-url-parts s))
     (and
      (equal? (cimd-url? s) (and parts #t))
      (or (not parts)
         (let ([host (car parts)] [path (cdr parts)])
           (and (equal? (string-append "https://" host path) s)
                (printable-ascii? s) (<= (string-length s) 2048)
                (let ([labels (string-split host "." #:trim? #f)])
                  (and (>= (length labels) 2) (andmap (λ (l) (regexp-match? #px"^[A-Za-z0-9-]+$" l)) labels)))
                (not (regexp-match? #px"^[0-9.]+$" host))
                (char=? (string-ref path 0) #\/)
                (not (regexp-match? #rx"[?#\\\\]" s))
                (not (member ".." (string-split path "/")))
                (not (member "." (string-split path "/"))))))))))

;; completeness: without it, a validator that refuses everything would pass the test above
(test-case "a plain https URL on a DNS name is accepted as a client-metadata URL"
  (check-property
   (prop-config 300)
   (property ([s gen:cimd-url])
     (cimd-url? s))))

(test-case "a client name is cleaned into 1 to 100 visible characters, or replaced by the fallback"
  ;; mostly junk (3); long names with a double space (1); runs of spaces before a letter (1); names
  ;; around 100 characters with an invisible character in the middle (1); any JSON value (1)
  (define gen:name
    (gen:frequency
     (list (cons 3 (gen:bad-string 30))
           (cons 1 (gen:map (gen:integer-in 80 130) (λ (n) (string-append (make-string n #\a) "  " (make-string 10 #\b)))))
           (cons 1 (gen:map (gen:integer-in 95 105) (λ (n) (string-append (make-string n #\space) "x"))))
           (cons 1 (gen:map (gen:integer-in 96 102) (λ (n) (string-append (make-string (- n 1) #\a) " " (string (integer->char #x200B)) " b"))))
           (cons 1 gen:jsexpr))))
  (check-property
   (prop-config 2000)
   (property ([v gen:name])
     (define r (clean-name v "fallback"))
     (or (equal? r "fallback")
         (and (string? v)
              (<= 1 (string-length r) 100)
              (not (regexp-match? #px"\\p{Cc}|\\p{Cf}|\\p{Zl}|\\p{Zp}" r))
              (equal? (string-trim r) r))))))

(test-case "a logo or home page link is kept only if it is https on exactly the client's own host"
  ;; a host with a tail that is fine ("/logo.png", "?x=1") or tries to leave the host (".evil.com",
  ;; "@evil.com", a port, a backslash...) behind a scheme that is usually https
  (define gen:uri-on
    (gen:let ([host gen:cimd-host]
              [tail (gen:one-of '("" "/" "/logo.png" "?x=1" ".evil.com" "@evil.com" ":8443" ":80/x" "\\@evil.com" "#f" " " "/a b"
                                  ".evil.com/x" "-x.evil.com" "/@evil.com" "?@evil.com" "x" "/é"))]
              [scheme (gen:one-of '("https://" "https://" "https://" "http://" "HTTPS://" "https:/"))])
      (list host (string-append scheme host tail))))
  (check-property
   (prop-config 3000)
   (property ([hv gen:uri-on])
     (define host (car hv))
     (define v (cadr hv))
     (define r (same-origin-uri-or-false v host))
     (and (or (not r) (and (equal? r v) (starts-with? v "https://") (equal? (authority-host r) host)))
          ;; completeness for the plain shapes
          (or (not (regexp-match? (pregexp (string-append "^https://" (regexp-quote host) "(/[A-Za-z0-9._~-]*|\\?[a-z0-9=]*)?$")) v))
              r)))))
