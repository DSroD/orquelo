#lang racket/base
;; Properties of client registration and of resolving a client from a fetched metadata document.
(require rackcheck rackunit racket/list racket/string json
         "../dcr.rkt" "../cimd.rkt" "../data.rkt" "../store.rkt" "../uri.rkt" "../clean.rkt"
         "prop.rkt" "gen.rkt")

(define now 50)

;; Any -> Boolean
(define (valid-name? s) (and (string? s) (<= 1 (string-length s) 100) (equal? (string-trim s) s)))
;; Client -> Boolean
(define (sane-client? c)
  (and (valid-name? (client-name c))
       (<= 1 (length (client-redirect-uris c)) 20)
       (andmap valid-redirect-uri? (client-redirect-uris c))))

;; -> Gen
;; any JSON (2), a valid registration (4), or a valid one with one field made invalid (3)
(define gen:request
  (gen:frequency
   (list (cons 2 gen:jsexpr)
         (cons 4 (gen:client-metadata))
         (cons 3 (gen:bind (gen:client-metadata) gen:bad-metadata)))))

(test-case "registration, whatever it is sent, yields a well-formed new client or a 400"
  ;; a client has a trimmed 1..100 character name, 1..20 valid redirect URIs, the given id and the
  ;; time, never expires and has no logo; anything else is a 400
  (check-property
   (prop-config 2000)
   (property ([req gen:request])
     (define r (register req now #:new-id (λ () "id1")))
     (cond [(client? r) (and (sane-client? r) (equal? (client-id r) "id1") (eq? (client-kind r) 'registered)
                             (equal? (client-created r) now) (not (client-expires r)) (not (client-logo-uri r)))]
           [else (and (oauth-error? r) (= (oauth-error-status r) 400))]))))

(test-case "registration keeps what a valid request says and refuses a request with a bad field"
  ;; a valid request keeps its redirect URIs and refresh right, and gets a cleaned name
  (check-property
   (prop-config 1500)
   (property ([meta (gen:client-metadata)])
     (define r (register meta now #:new-id (λ () "id1")))
     (and (client? r)
          (equal? (client-redirect-uris r) (hash-ref meta 'redirect_uris))
          (equal? (client-refresh? r) (and (member "refresh_token" (hash-ref meta 'grant_types '())) #t))
          (equal? (client-name r) (clean-name (hash-ref meta 'client_name #f) "Unnamed application")))))
  ;; a valid request with one field replaced by an invalid value is a 400
  (check-property
   (prop-config 1500)
   (property ([bad (gen:bind (gen:client-metadata) gen:bad-metadata)])
     (define r (register bad now))
     (and (oauth-error? r) (= (oauth-error-status r) 400)))))

;; ---- resolve-client against generated fetch results

(define id "https://app.example/client.json")
(define content-types '("application/json" "application/json" "application/json" "application/json; charset=utf-8"
                        "  Application/JSON  " "text/html" "application/jsonx" "application/json5" #f ""))
(define cache-controls '(#f #f "max-age=0" "max-age=99999999" "max-age=600" "no-store" "public, max-age=3600" "MAX-AGE=5"
                         "max-age=-1" "max-age=abc" "s-maxage=10" "no-cache, max-age=9000" "max-age=86400" "max-age=300"))

(define (doc-bytes h) (jsexpr->bytes h))

;; -> Gen
;; a fetch result: mostly a 200 JSON document, with odd content types and cache headers; the body
;; is a valid document for this id (6), one for another id (1), one with a bad field (2), one that
;; carries a client secret (1), random bytes (1), 6000 spaces, too big (1), or any JSON (1)
(define gen:fetched
  (gen:let ([status (gen:frequency (list (cons 8 (gen:const 200)) (cons 1 (gen:const 404)) (cons 1 (gen:const 302)) (cons 1 (gen:const 500))))]
            [ct (gen:one-of content-types)]
            [cc (gen:one-of cache-controls)]
            [body (gen:frequency
                   (list (cons 6 (gen:map (gen:client-metadata id) doc-bytes))
                         (cons 1 (gen:map (gen:client-metadata "https://other.example/c.json") doc-bytes))
                         (cons 2 (gen:map (gen:bind (gen:client-metadata id) gen:bad-metadata) doc-bytes))
                         (cons 1 (gen:map (gen:client-metadata id) (λ (h) (doc-bytes (hash-set h 'client_secret "shh")))))
                         (cons 1 (gen:bytes #:max-length 40))
                         (cons 1 (gen:const (make-bytes 6000 32)))
                         (cons 1 (gen:map gen:jsexpr doc-bytes))))])
    (fetched status ct cc body)))

;; (-> Fetched) -> (values (-> Integer (or Client #f)) (-> Natural))
;; a stage for resolve-client: the stub fetch returns `reply`, `at` resolves at a given time and
;; fetches counts the fetches
(define (make-stage reply)
  (define clock (box now))
  (define fetches (box 0))
  (define app (oauth-app "https://orq.example" "https://orq.example/mcp" '(("decks" . "d")) values (λ (s e) #t)
                         (λ (url) (set-box! fetches (add1 (unbox fetches))) (reply))
                         (λ () (unbox clock))))
  (define store (make-memory-store))
  (define nc (make-negative-cache))
  (values (λ (t) (set-box! clock t) (resolve-client app store nc id))
          (λ () (unbox fetches))))

;; String -> Boolean
(define (on-host? u) (or (not u) (regexp-match? #rx"^https://app[.]example([/?]|$)" u)))

(test-case "a client is taken from a fetched document only if the fetch and the document are sound"
  ;; the answer is none, or a client whose fetch was a 200 JSON response, whose id is the URL it
  ;; was fetched from, which is well-formed, valid for between 5 minutes and a day, and whose
  ;; own links stay on the document's host
  (check-property
   (prop-config 2000)
   (property ([f gen:fetched])
     (define-values (at fetches) (make-stage (λ () f)))
     (define c (at now))
     (or (not c)
         (and (= (fetched-status f) 200)
              (regexp-match? #px"^\\s*application/json\\s*(;.*)?$" (string-downcase (fetched-content-type f)))
              (equal? (client-id c) id) (eq? (client-kind c) 'metadata-document)
              (sane-client? c)
              (<= 300 (- (client-expires c) now) 86400)
              (on-host? (client-uri c)) (on-host? (client-logo-uri c)))))))

(test-case "a valid document is accepted, and a fetch that raises just means no client"
  ;; completeness: a valid document served as JSON with any cache header gives a client
  (check-property
   (prop-config 800)
   (property ([meta (gen:client-metadata id)] [cc (gen:one-of cache-controls)])
     (define-values (at fetches) (make-stage (λ () (fetched 200 "application/json" cc (doc-bytes meta)))))
     (client? (at now))))
  (let-values ([(at fetches) (make-stage (λ () (raise (exn:fail "boom" (current-continuation-marks)))))])
    (check-false (at now))))

(test-case "a failed lookup is not retried for 300 seconds, a successful one until it goes stale"
  ;; no fetch happens before the deadline, and exactly one at it
  (check-property
   (prop-config 1500)
   (property ([f gen:fetched])
     (define-values (at fetches) (make-stage (λ () f)))
     (define c (at now))
     (define n1 (fetches))
     (cond
       [c (define expires (client-expires c))
          (and (equal? (at (sub1 expires)) c) (= (fetches) n1)
               (client? (at expires)) (= (fetches) (add1 n1)))]
       [else (and (not (at (+ now 299))) (= (fetches) n1)
                  (not (at (+ now 300))) (= (fetches) (add1 n1)))]))))
