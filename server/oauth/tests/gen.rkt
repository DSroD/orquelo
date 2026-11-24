#lang racket/base
;; Generators for the property tests: URI parts (with adversarial pieces), JSON values and client
;; metadata (test-only: never required from main.rkt).
(require racket/list racket/string rackcheck)
(provide (struct-out uri-parts)
         gen:uri-parts gen:uri-string gen:mutated gen:mutated-uri-string gen:loopback-parts parts->string
         expected-redirect-valid? gen:cimd-host gen:cimd-url gen:jsexpr gen:bad-string
         gen:client-metadata gen:redirect-uri gen:bad-metadata)

;; A UriParts is a (uri-parts String Boolean (or String #f) String (or String #f) String (or String #f))
;; scheme, whether "//" follows it, userinfo, host, port text (without ":"), path and query text
;; and fragment (without "#"); each may be adversarial
(struct uri-parts (scheme slashes? userinfo host port path fragment) #:transparent)

;; UriParts -> String
(define (parts->string p)
  (string-append (uri-parts-scheme p) ":" (if (uri-parts-slashes? p) "//" "")
                 (if (uri-parts-userinfo p) (string-append (uri-parts-userinfo p) "@") "")
                 (uri-parts-host p)
                 (if (uri-parts-port p) (string-append ":" (uri-parts-port p)) "")
                 (uri-parts-path p)
                 (if (uri-parts-fragment p) (string-append "#" (uri-parts-fragment p)) "")))

;; (listof Any) -> Gen
;; a generator that favours the listed values but sometimes makes up a short string without the
;; `strip` characters, which would blur where one URI component ends and the next begins
(define (gen:from-list vals #:strip [strip #rx"[/?#]"])
  (gen:frequency (list (cons 9 (gen:one-of vals))
                       (cons 1 (gen:map (gen:bad-string 8) (λ (s) (regexp-replace* strip s "x")))))))

;; Natural -> Gen
;; short strings over an alphabet of troublemakers: URI delimiters, space, backslash, non-ASCII,
;; control and format characters
(define (gen:bad-string max-len)
  (gen:string (gen:frequency
               (list (cons 6 (gen:one-of (string->list "ab9.-:/?#@[]%\\ ~_")))
                     (cons 1 (gen:one-of (map integer->char '(#xE9 #x200B #x202E 7 #x85 #x3000 #xA0 #xFF0E 10 0))))
                     (cons 1 (gen:char-in 32 126))))
              #:max-length max-len))

(define schemes '("https" "https" "https" "http" "http" "HTTPS" "Http" "myapp" "javascript" "ftp" "https+x" "" "h ttps"))
(define userinfos '(#f #f #f #f "user" "user:pw" "" ":" "a@b"))
(define https-hosts '("app.example" "a-b.c.example" "app.example." "-x-" "127.0.0.1" "localhost" "[::1]" "[2001:db8::1]"
                      "[]" "[::1" "127.0.0.1.evil.com" "0.0.0.0" "" "ex ample" "é.example" "app_example" "APP.Example"
                      "a..b" "127.1" "[::ffff:127.0.0.1]" "[g::1]" "x.y@z"))
(define loopback-hosts '("127.0.0.1" "[::1]" "localhost" "127.0.0.1" "[::1]" "localhost" "LOCALHOST" "127.0.0.2" "::1" "[::2]"))
(define ports '(#f #f #f "" "80" "8765" "443" "0" "1" "65535" "65536" "99999" "0080" "123456" "1e3" "-1" "+1" " 80" "٨٠"))
(define paths '("" "" "/" "/cb" "/a/b" "/a/b?q=1&r=%20" "?x=1" "/?" "/é" "/a b" "/a\\b" "/a#b" "#" "//x" "/a@b" "/%zz"
                "/./../x" "/\u200B" "/\n"))
(define fragments '(#f #f #f #f "" "frag"))

;; -> Gen
;; URI parts of every shape, mostly close to a valid redirect URI
(define gen:uri-parts
  (gen:let ([scheme (gen:from-list schemes)]
            [slashes? (gen:frequency (list (cons 9 (gen:const #t)) (cons 1 (gen:const #f))))]
            [userinfo (gen:from-list userinfos)]
            [host (gen:from-list (append https-hosts loopback-hosts) #:strip #rx"[/?#:]")]
            [port (gen:from-list ports)]
            [path (gen:frequency (list (cons 12 (gen:frequency (list (cons 9 (gen:one-of paths))
                                                                (cons 1 (gen:map (gen:bad-string 8) (λ (s) (string-append "/" s)))))))
                                       (cons 1 (gen:map (gen:integer-in 2030 2060) (λ (n) (string-append "/" (make-string n #\a)))))))]
            [fragment (gen:from-list fragments)])
    ;; without "//", an empty host would let a path starting "//" turn into the authority
    (uri-parts scheme slashes? userinfo (if (and (not slashes?) (string=? host "")) "h" host) port path fragment)))

;; -> Gen
;; the same, but biased toward https or http-on-loopback so that valid URIs are common
(define gen:loopback-parts
  (gen:let ([p gen:uri-parts]
            [scheme (gen:one-of '("http" "https"))]
            [host (gen:one-of '("127.0.0.1" "[::1]" "localhost" "app.example"))]
            [keep? gen:boolean])
    (if keep? (struct-copy uri-parts p [scheme scheme] [host host] [slashes? #t] [userinfo #f] [fragment #f])
        p)))

;; -> Gen
(define gen:uri-string (gen:map gen:uri-parts parts->string))

;; (listof Char) Char -> Boolean
(define (char-in? cs c) (and (memv c cs) #t))

;; String -> Boolean
(define (plain-char-text? s)
  (for/and ([c (in-string s)]) (<= 33 (char->integer c) 126)))

;; String -> Boolean
;; a non-empty host made of letters, digits and the given extra characters
(define (host-chars? s extra)
  (and (positive? (string-length s))
       (for/and ([c (in-string s)])
         (or (and (char<=? #\a c #\z)) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char-in? extra c)))))

;; (or String #f) -> Boolean
(define (port-ok? port)
  (or (not port)
      (and (<= 1 (string-length port) 5)
           (for/and ([c (in-string port)]) (char<=? #\0 c #\9))
           (<= (string->number port) 65535))))

;; UriParts -> Boolean
;; the specification of an acceptable redirect URI, from its parts: https on a DNS name or an
;; IP literal, or http on 127.0.0.1, [::1] or localhost; any port up to 65535; no userinfo, no
;; fragment; printable ASCII without backslash or "#" in the rest; at most 2048 characters
(define (expected-redirect-valid? p)
  (define s (parts->string p))
  (define host (uri-parts-host p))
  (define path (uri-parts-path p))
  (define scheme (uri-parts-scheme p))
  (and (uri-parts-slashes? p)
       (not (uri-parts-userinfo p))
       (not (uri-parts-fragment p))
       (<= (string-length s) 2048)
       (plain-char-text? s)
       (port-ok? (uri-parts-port p))
       (or (zero? (string-length path)) (char-in? '(#\/ #\?) (string-ref path 0)))
       (not (for/or ([c (in-string path)]) (char-in? '(#\\ #\#) c)))
       (cond [(string=? scheme "https")
              (or (host-chars? host (string->list ".-"))
                  (and (> (string-length host) 2) (char=? (string-ref host 0) #\[)
                       (char=? (string-ref host (sub1 (string-length host))) #\])
                       (host-chars? (substring host 1 (sub1 (string-length host))) (string->list ":."))
                       (for/and ([c (in-string host)] #:unless (char-in? '(#\[ #\] #\: #\.) c))
                         (or (char<=? #\0 c #\9) (char<=? #\a c #\f) (char<=? #\A c #\F)))))]
             [(string=? scheme "http") (and (member host '("127.0.0.1" "[::1]" "localhost")) #t)]
             [else #f])))

;; -> Gen
;; a redirect URI that satisfies the specification
(define gen:redirect-uri
  (gen:let ([loopback? gen:boolean]
            [host (gen:one-of '("app.example" "a-b.c.example" "[2001:db8::1]" "127.0.0.1" "[::1]" "localhost"))]
            [port (gen:one-of '(#f "8080" "443" "65535" "1"))]
            [path (gen:one-of '("" "/" "/cb" "/a/b?q=1&r=%20" "?x=1" "/a@b"))])
    (define local? (and (member host '("127.0.0.1" "[::1]" "localhost")) #t))
    (parts->string (uri-parts (if (and local? loopback?) "http" "https") #t #f host port path #f))))

;; Gen -> Gen
;; the strings of `base` with one troublemaker inserted (or one character dropped) at a random place
(define (gen:mutated base)
  (gen:let ([s base]
            [i gen:natural]
            [c (gen:from-list '("#" "\\" " " "@" "\u00E9" "\u200B" "%" "[" "." "/" "?" ":" "\n"))]
            [drop? (gen:frequency (list (cons 1 (gen:const #t)) (cons 3 (gen:const #f))))])
    (define k (if (zero? (string-length s)) 0 (modulo i (add1 (string-length s)))))
    (if (and drop? (< k (string-length s)))
        (string-append (substring s 0 k) (substring s (add1 k)))
        (string-append (substring s 0 k) c (substring s k)))))

;; -> Gen
(define gen:mutated-uri-string (gen:mutated gen:redirect-uri))

;; -> Gen
;; a DNS name with at least two labels, as in a CIMD client id
(define gen:cimd-host
  (gen:let ([labels (gen:list (gen:string (gen:frequency (list (cons 8 gen:char-alphanumeric) (cons 1 (gen:const #\-))))
                                          #:max-length 6)
                              #:max-length 3)]
            [tld (gen:one-of '("example" "com" "io"))])
    (string-join (append (filter (λ (l) (positive? (string-length l))) labels) (list tld)) ".")))

;; -> Gen
;; a valid CIMD client id: https, a DNS name, a path without dot segments
(define gen:cimd-url
  (gen:let ([host (gen:one-of '("app.example" "a-b.example.com" "x.io" "client.example.org"))]
            [segs (gen:list (gen:one-of '("a" "client.json" "oauth" "x-y" "z_1")) #:max-length 3)])
    (string-append "https://" host "/" (string-join segs "/"))))

;; -> Gen
;; any JSON value, with nesting kept shallow
(define (gen:jsexpr-sized depth)
  (define leaf (gen:frequency
                (list (cons 2 (gen:const 'null)) (cons 2 gen:boolean) (cons 2 (gen:integer-in -5 70000))
                      (cons 3 (gen:bad-string 12)))))
  (if (zero? depth)
      leaf
      (gen:frequency
       (list (cons 4 leaf)
             (cons 1 (gen:list (gen:jsexpr-sized (sub1 depth)) #:max-length 3))
             (cons 1 (gen:map (gen:list (gen:tuple (gen:one-of '(redirect_uris client_name client_uri a b))
                                                   (gen:jsexpr-sized (sub1 depth)))
                                        #:max-length 4)
                              (λ (kvs) (for/hasheq ([kv kvs]) (values (car kv) (cadr kv))))))))))

;; -> Gen
(define gen:jsexpr (gen:jsexpr-sized 2))

;; [(or String #f)] -> Gen
;; a valid client metadata document (also a valid registration request); with `client-id` the
;; document names itself
(define (gen:client-metadata [client-id #f])
  (gen:let ([uris (gen:list gen:redirect-uri #:max-length 4)]
            [first-uri gen:redirect-uri]
            [name (gen:frequency (list (cons 3 (gen:bad-string 140)) (cons 1 (gen:const #f))
                                       (cons 1 (gen:map (gen:integer-in 90 130) (λ (n) (string-append (make-string 95 #\a) (make-string (- n 90) #\space) "tail"))))))]
            [client-uri (gen:one-of '(#f "https://app.example" "https://app.example/about" "https://other.example" "http://app.example" 5))]
            [logo-uri (gen:one-of '(#f "https://app.example/l.png" "https://other.example/l.png" "https://app.example@evil.com/"))]
            [grants (gen:one-of '(#f ("authorization_code") ("authorization_code" "refresh_token") ("refresh_token" "authorization_code")))])
    (for/fold ([h (hasheq 'redirect_uris (cons first-uri uris))])
              ([kv (list (cons 'client_name name) (cons 'client_uri client-uri) (cons 'logo_uri logo-uri)
                         (cons 'grant_types grants) (cons 'client_id client-id))])
      (if (cdr kv) (hash-set h (car kv) (cdr kv)) h))))

;; Hash -> Gen
;; `meta` with one field replaced by a value the library must refuse
(define (gen:bad-metadata meta)
  (gen:let ([bad (gen:one-of
                  (list (cons 'redirect_uris '())
                        (cons 'redirect_uris "https://app.example/cb")
                        (cons 'redirect_uris '("myapp://cb"))
                        (cons 'redirect_uris '("https://app.example/cb#f"))
                        (cons 'redirect_uris (make-list 21 "https://a.example/cb"))
                        (cons 'token_endpoint_auth_method "client_secret_basic")
                        (cons 'grant_types '("password"))
                        (cons 'grant_types '())
                        (cons 'grant_types '("authorization_code" "authorization_code"))
                        (cons 'response_types '("token"))
                        (cons 'client_name 5)))])
    (hash-set meta (car bad) (cdr bad))))
