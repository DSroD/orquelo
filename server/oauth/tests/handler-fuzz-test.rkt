#lang racket/base
;; The HTTP handlers on arbitrary requests (any method, content type, body, query, header): they never
;; raise, answer only with the statuses they document, and what they answer is well formed. Requests
;; mix junk with the real values of a stage that holds one live grant, so that the interesting
;; paths (a real code, a real token, a valid authorization request) are reached too.
(require rackunit rackcheck racket/list racket/string json net/uri-codec web-server/http
         "../data.rkt" "../server.rkt" "driver.rkt" "prop.rkt")

;; A Live is a (hash Symbol String): the stage's real code, access and refresh tokens
;; (A Value is a String, or a Symbol naming one of the Live values)

;; -> (values Stage Live)
;; a stage with one connected app and a second, unused code
(define (live-stage)
  (define st (make-stage #:max-unused-clients 2))
  (define j (json-of (exchange-code st (connect! st "client-a" 7 '("decks" "results") '("decks" "results")))))
  (values st (hasheq 'code (connect! st "client-a" 7 '("decks") '("decks"))
                     'access (hash-ref j 'access_token) 'refresh (hash-ref j 'refresh_token))))

;; Value Live -> String
(define (resolve v live) (if (symbol? v) (hash-ref live v) v))

;; ---------------------------------------------------------------------------------------------
;; Generators

;; -> Gen
;; mostly printable ASCII, sometimes a nasty character (NUL, newline, accents, zero-width, RTL
;; override, emoji)
(define gen:junk-char
  (gen:frequency (list (cons 6 (gen:char-in 32 126)) (cons 1 (gen:one-of (map integer->char '(0 10 #xE9 #x200B #x202E #xFFFD #x1F600)))))))
(define gen:junk (gen:string gen:junk-char #:max-length 30))
(define gen:long (gen:const (make-string 5000 #\a)))

(define keys '("grant_type" "code" "code_verifier" "client_id" "redirect_uri" "refresh_token" "resource" "scope"
               "state" "response_type" "code_challenge" "code_challenge_method"))
;; -> Gen
;; a form field name: a real one (12) or junk (1)
(define gen:key (gen:frequency (list (cons 12 (gen:one-of keys)) (cons 1 gen:junk))))
;; -> Gen
;; a form field value: the stage's real code or token (6); a plausible string, such as a grant type,
;; scope, client id, redirect or code verifier (12); junk (3); 5000 characters (1)
(define gen:value
  (gen:frequency
   (list (cons 6 (gen:one-of '(code access refresh)))
         (cons 12 (gen:one-of (list "authorization_code" "refresh_token" "password" "code" "S256" "plain" "" "decks"
                                    "decks results" "admin decks" "client-a" "client-b" "nobody" redirect app-resource
                                    verifier challenge "https://evil.example/cb" "http://127.0.0.1:8080/cb"
                                    "https://orq.example/mcp/x" (make-string 43 #\A) (make-string 1025 #\s))))
         (cons 3 gen:junk)
         (cons 1 gen:long))))
(define gen:fields (gen:list (gen:tuple gen:key gen:value) #:max-length 9))

;; -> Gen
;; a request method: mostly POST (8) or GET (4), sometimes another or a misspelt one (1)
(define gen:method (gen:frequency (list (cons 8 (gen:const #"POST")) (cons 4 (gen:const #"GET"))
                                         (cons 1 (gen:one-of '(#"PUT" #"HEAD" #"DELETE" #"OPTIONS" #"post" #""))))))
;; -> Gen
;; a content type: form-encoded (8), the same with odd case and charset (1), another or a near
;; miss (1), or none (1)
(define gen:content-type
  (gen:frequency (list (cons 8 (gen:const "application/x-www-form-urlencoded"))
                       (cons 1 (gen:const "Application/X-WWW-Form-Urlencoded; charset=utf-8"))
                       (cons 1 (gen:one-of '("application/json" "text/plain" "multipart/form-data; boundary=x"
                                             "application/x-www-form-urlencodedx" "")))
                       (cons 1 (gen:const #f)))))
;; -> Gen
(define gen:raw-bytes (gen:bytes (gen:integer-in 0 255) #:max-length 80))

;; -> Gen
;; a request body: the fields form-encoded (8), random bytes (2), or oversized (1)
(define gen:body
  (gen:frequency (list (cons 8 (gen:map gen:fields (λ (fs) (cons 'fields fs))))
                       (cons 2 (gen:map gen:raw-bytes (λ (b) (cons 'raw b))))
                       (cons 1 (gen:const (cons 'raw (make-bytes (* 70 1024) 97)))))))

;; Natural Body Live -> Bytes
(define (render-body body live)
  (case (car body)
    [(raw) (cdr body)]
    [else (string->bytes/utf-8
           (alist->form-urlencoded (for/list ([f (in-list (cdr body))]) (cons (string->symbol (car f)) (resolve (cadr f) live)))))]))

;; ---------------------------------------------------------------------------------------------
;; Checks

;; String Any ... -> Nothing
(define (fail! fmt . args) (error 'fuzz (apply format fmt args)))

;; Response (listof Natural) -> Void
(define (check-status! r allowed)
  (label! (format "status ~a" (response-code r)))
  (unless (memv (response-code r) allowed) (fail! "status ~a is not one of ~a" (response-code r) allowed)))

;; Response -> Void
;; a JSON error body with a string `error`
(define (check-json-error! r)
  (define j (with-handlers ([exn:fail? (λ (e) (fail! "the error body is not JSON: ~a" (body-of r)))]) (json-of r)))
  (unless (and (hash? j) (string? (hash-ref j 'error #f))) (fail! "no `error` in ~a" j))
  (unless (equal? (header-of r "Cache-Control") "no-store") (fail! "an error that may be cached")))

;; Response -> Void
(define (check-token-response! r)
  (check-status! r '(200 400 405))
  (case (response-code r)
    [(200) (unless (string? (hash-ref (json-of r) 'access_token #f)) (fail! "no access token in a 200"))
           (unless (equal? (header-of r "Cache-Control") "no-store") (fail! "a token that may be cached"))]
    [(400) (check-json-error! r)]))

;; ---------------------------------------------------------------------------------------------
;; Properties

(define good-bases
  (list (list (list "grant_type" "authorization_code") (list "code" 'code) (list "code_verifier" verifier)
              (list "client_id" "client-a") (list "redirect_uri" redirect))
        (list (list "grant_type" "refresh_token") (list "refresh_token" 'refresh) (list "client_id" "client-a"))))

;; a valid token request with at most one field dropped, replaced or added
(define gen:near-miss
  (gen:let ([base (gen:one-of good-bases)] [i (gen:integer-in 0 7)] [what (gen:one-of '(drop replace add keep keep))]
            [v gen:value] [k gen:key])
    (cons 'fields
          (cond [(>= i (length base)) base]
                [else (case what
                        [(drop) (append (take base i) (drop base (add1 i)))]
                        [(replace) (append (take base i) (list (list (car (list-ref base i)) v)) (drop base (add1 i)))]
                        [(add) (cons (list k v) base)]
                        [else base])]))))

;; -> Gen
;; a token request: any method, type and body (2), or a POST of a near miss of a valid request (3)
(define gen:token-request
  (gen:frequency
   (list (cons 2 (gen:let ([m gen:method] [type gen:content-type] [body gen:body]) (list m type body)))
         (cons 3 (gen:map gen:near-miss (λ (body) (list #"POST" "application/x-www-form-urlencoded" body)))))))

(test-case "the token endpoint answers 200, 400 or 405 with a well-formed body, whatever it is sent"
  ;; several requests in a row to one stage, so that real codes and tokens get used and replayed
  (check-property
   (prop-config 200 #:deadline-ms 2000)
   (property ([reqs (gen:list gen:token-request #:max-length 6)])
     (define-values (st live) (live-stage))
     (for ([r (in-list reqs)])
       (define headers (if (cadr r) (list (cons "Content-Type" (cadr r))) '()))
       (check-token-response!
        (handle-token (stage-server st) (make-req (car r) "/oauth/token" (render-body (caddr r) live) headers))))
     #t)))

;; -> Gen
;; an authorization request: usually GET (sometimes POST or HEAD), one time in three with all the
;; required parameters, plus random extra fields
(define gen:authorize-request
  (gen:let ([m (gen:frequency (list (cons 12 (gen:const #"GET")) (cons 1 (gen:one-of '(#"POST" #"HEAD")))))]
            [fields gen:fields]
            [good? (gen:one-of '(#t #f #f))])
    (list m good? fields)))

(test-case "the authorization endpoint answers 302 to the consent page, 400 or 405"
  (check-property
   (prop-config 200 #:deadline-ms 1500)
   (property ([reqs (gen:list gen:authorize-request #:max-length 6)])
     (define-values (st live) (live-stage))
     (for ([r (in-list reqs)])
       (define base (if (cadr r)
                        (list (cons 'response_type "code") (cons 'client_id "client-a") (cons 'redirect_uri redirect)
                              (cons 'code_challenge challenge) (cons 'code_challenge_method "S256"))
                        '()))
       (define extra (for/list ([f (in-list (caddr r))]) (cons (string->symbol (car f)) (resolve (cadr f) live))))
       (define resp (handle-authorize (stage-server st)
                                      (make-req (car r) (string-append "/oauth/authorize?" (alist->form-urlencoded (append base extra))))))
       (check-status! resp '(302 400 405))
       (case (response-code resp)
         [(302) (unless (regexp-match? #rx"^/connect/[A-Za-z0-9_-]+$" (header-of resp "Location"))
                  (fail! "a redirect to ~s" (header-of resp "Location")))]
         [(400) (when (header-of resp "Location") (fail! "an error page that redirects"))
                (unless (equal? (header-of resp "Content-Security-Policy") "default-src 'none'") (fail! "an error page without CSP"))]))
     #t)))

;; -> Gen
;; a registration body: random bytes (3), or a JSON document with junk name, doubtful redirect
;; URIs, grant types and authentication method (6)
(define gen:metadata
  (gen:frequency
   (list (cons 3 gen:raw-bytes)
         (cons 6 (gen:let ([name gen:junk]
                           [uris (gen:list (gen:one-of (list redirect redirect "http://127.0.0.1/cb" "javascript:x" "" "https://a.example/cb#f"))
                                           #:max-length 4)]
                           [grants (gen:list (gen:one-of '("authorization_code" "refresh_token" "implicit" "password")) #:max-length 3)]
                           [auth (gen:one-of '("none" "client_secret_basic" "private_key_jwt"))])
                   (jsexpr->bytes (hasheq 'client_name name 'redirect_uris uris 'grant_types grants
                                          'token_endpoint_auth_method auth)))))))

(test-case "the registration endpoint answers 201, 400, 405 or 429"
  (check-property
   (prop-config 200 #:deadline-ms 1500)
   (property ([reqs (gen:list (gen:tuple (gen:frequency (list (cons 9 (gen:const #"POST")) (cons 1 gen:method))) gen:metadata) #:max-length 6)])
     (define-values (st live) (live-stage))
     (for ([r (in-list reqs)])
       (define resp (handle-register (stage-server st) (make-req (car r) "/oauth/register" (cadr r))))
       (check-status! resp '(201 400 405 429))
       (case (response-code resp)
         [(201) (unless (string? (hash-ref (json-of resp) 'client_id #f)) (fail! "no client_id in a 201"))]
         [(400 429) (check-json-error! resp)]))
     #t)))

;; -> Gen
;; an Authorization header: a real token as a bearer (4), "Bearer" plus junk (3), junk (2), or a
;; malformed or missing one (1)
(define gen:authorization-header
  (gen:frequency
   (list (cons 4 (gen:map (gen:one-of '(code access refresh)) (λ (t) (cons 'bearer t))))
         (cons 3 (gen:map gen:junk (λ (s) (cons 'raw (string-append "Bearer " s)))))
         (cons 2 (gen:map gen:junk (λ (s) (cons 'raw s))))
         (cons 1 (gen:one-of (list (cons 'raw "Bearer") (cons 'raw "bearer   ") (cons 'raw "Basic abc") (cons 'none #f)))))))

(test-case "authenticate answers a principal or a 401 challenge"
  (check-property
   (prop-config 300 #:deadline-ms 1500)
   (property ([hs (gen:list gen:authorization-header #:max-length 6)])
     (define-values (st live) (live-stage))
     (for ([h (in-list hs)])
       (define req (case (car h)
                     [(bearer) (bearer-request (hash-ref live (cdr h)))]
                     [(raw) (make-req #"POST" "/mcp" #"" (list (cons "Authorization" (cdr h))))]
                     [else (make-req #"POST" "/mcp")]))
       (define result (authenticate (stage-server st) req))
       (unless (or (principal? result) (and (response? result) (= (response-code result) 401)
                                            (header-of result "WWW-Authenticate")))
         (fail! "authenticate answered ~a" result)))
     #t)))
