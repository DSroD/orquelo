#lang racket/base
;; Client ID Metadata Documents: the client_id is an https URL and the document served there says
;; who the client is. We fetch it, so the fetch is the dangerous part: https on port 443 only, the
;; peer address checked before any byte is sent, no redirects, five seconds in all, five KiB at most.
(require racket/contract/base racket/match racket/list racket/string json
         "../http-client/main.rkt" "data.rkt" "store.rkt" "uri.rkt" "ip.rkt" "clean.rkt")
(provide (contract-out
          [cimd-fetch (-> string? fetched?)]
          [make-negative-cache (-> negative-cache?)]
          [negative-cache-sweep! (-> negative-cache? exact-integer? void?)]
          [resolve-client (-> oauth-app? oauth-store? negative-cache? string? (or/c client? #f))]))

(define fetch-seconds 5)
(define max-document-bytes (* 5 1024))
(define min-ttl 300)
(define max-ttl (* 24 60 60))
(define negative-ttl 300)
(define max-negative-entries 1000)
(define max-redirect-uris 20)

;; String -> Fetched
;; GETs a metadata document. A reply that is not 200 carries no body; a body over 5 KiB raises
;; exn:fail:http:protocol. A 3xx is not followed.
(define (cimd-fetch url)
  (match-define (cons host target) (cimd-url-parts url))
  (define r
    (http-request #t host 443 "GET" target
                  (list (cons "Host" host) (cons "Accept" "application/json") (cons "User-Agent" "orquelo-oauth"))
                  #:connect-timeout fetch-seconds #:idle-timeout fetch-seconds
                  #:check-peer public-address?
                  #:deadline (+ (current-inexact-monotonic-milliseconds) (* fetch-seconds 1000))))
  (define ok? (= (response-status r) 200))
  (define body (if ok? (response-body-bytes! r max-document-bytes #:overflow 'error) #""))
  (close-input-port (response-body r))
  (fetched (response-status r) (response-header r "content-type") (response-header r "cache-control") body))

;; A NegativeCache is a (negative-cache (MutableHash String Integer) Semaphore)
;; client ids whose fetch failed, with the time until which we do not try again
(struct negative-cache (table lock))

(define (make-negative-cache) (negative-cache (make-hash) (make-semaphore 1)))

;; NegativeCache Real -> Void
;; forgets the entries that have run out
(define (negative-cache-sweep! nc now)
  (call-with-semaphore (negative-cache-lock nc)
    (λ () (for ([(k until) (in-hash (hash-copy (negative-cache-table nc)))] #:when (<= until now))
            (hash-remove! (negative-cache-table nc) k)))))

;; NegativeCache String Integer -> Boolean
(define (recently-failed? nc id now)
  (call-with-semaphore (negative-cache-lock nc)
    (λ () (> (hash-ref (negative-cache-table nc) id 0) now))))

;; (MutableHash String Integer) -> Void
;; drops the entry that runs out first (the oldest, as every entry lasts as long)
(define (evict-oldest! table)
  (define-values (oldest _)
    (for/fold ([oldest #f] [until +inf.0]) ([(k v) (in-hash table)])
      (if (< v until) (values k v) (values oldest until))))
  (when oldest (hash-remove! table oldest)))

;; NegativeCache String Integer -> Void
(define (remember-failure! nc id now)
  (call-with-semaphore (negative-cache-lock nc)
    (λ ()
      (when (>= (hash-count (negative-cache-table nc)) max-negative-entries)
        (evict-oldest! (negative-cache-table nc)))
      (hash-set! (negative-cache-table nc) id (+ now negative-ttl)))))

;; OAuthApp OAuthStore NegativeCache String -> (or Client #f)
;; the client for a client_id: a registered one from the store, or a metadata-document one from
;; the cache or, when stale, from a fresh fetch. #f for an unknown client or a failed or invalid
;; document (remembered for a few minutes, so a bad URL cannot make us fetch again and again).
(define (resolve-client app store nc id)
  (define now ((oauth-app-clock app)))
  (define cached (store-client-ref store id))
  (cond
    [(not (cimd-url? id)) cached]
    [(and cached (client-expires cached) (> (client-expires cached) now)) cached]
    [(recently-failed? nc id now) #f]
    [else
     (define fresh (fetch-client app id now))
     (cond [fresh (store-client-put! store fresh) fresh]
           [else (remember-failure! nc id now) #f])]))

;; OAuthApp String Integer -> (or Client #f)
;; fetches and validates the document; any failure to do so is #f
(define (fetch-client app id now)
  (with-handlers ([exn:fail? (λ (e) #f)])
    (define f ((oauth-app-fetch-document app) id))
    (and (= (fetched-status f) 200)
         (json-content-type? (fetched-content-type f))
         (<= (bytes-length (fetched-body f)) max-document-bytes)
         (document->client id (bytes->jsexpr (fetched-body f)) now (cache-ttl (fetched-cache-control f))))))

;; (or String #f) -> Boolean
(define (json-content-type? ct)
  (and ct (regexp-match? #px"^\\s*application/json\\s*(;.*)?$" (string-downcase ct))))

;; (or String #f) -> Natural
;; seconds to cache a document: Cache-Control max-age, clamped to 5 minutes to 24 hours
(define (cache-ttl cache-control)
  (define max-age
    (match (and cache-control (regexp-match #px"(?i:(?:^|[,\\s])max-age=([0-9]{1,9}))" cache-control))
      [(list _ n) (string->number n)]
      [_ 0]))
  (define no-cache? (and cache-control (regexp-match? #px"(?i:no-store|no-cache)" cache-control)))
  (if no-cache? min-ttl (max min-ttl (min max-ttl max-age))))

;; String JSExpr Integer Natural -> (or Client #f)
;; the Client a metadata document describes, when it names this very URL as its client_id, has
;; valid redirect URIs, and asks for no client authentication. The name is the client's own
;; claim; the client and logo URIs are kept only when on the client_id's host, since the host of
;; the client_id is the only identity we have verified.
(define (document->client id doc now ttl)
  (define (field key [default #f]) (and (hash? doc) (hash-ref doc key default)))
  (define uris (field 'redirect_uris))
  (define host (car (cimd-url-parts id)))
  (define grant-types (field 'grant_types '("authorization_code" "refresh_token")))
  (and (hash? doc)
       (equal? (field 'client_id) id)
       (list? uris) (pair? uris) (<= (length uris) max-redirect-uris)
       (andmap valid-redirect-uri? uris)
       (equal? (field 'token_endpoint_auth_method "none") "none")
       (not (hash-has-key? doc 'client_secret))
       (list? grant-types) (member "authorization_code" grant-types)
       (client id 'metadata-document (clean-name (field 'client_name) host)
               (same-origin-uri-or-false (field 'client_uri) host)
               (same-origin-uri-or-false (field 'logo_uri) host)
               uris (and (member "refresh_token" grant-types) #t) now (+ now ttl))))

(module+ test
  (require rackunit)
  (define id "https://app.example/client.json")
  (define (doc . kvs) (apply hasheq 'client_id id 'redirect_uris '("https://app.example/cb") 'client_name "App" kvs))
  (define (reply d #:status [status 200] #:type [type "application/json"] #:cc [cc #f])
    (fetched status type cc (if (bytes? d) d (jsexpr->bytes d))))

  ;; the app under test fetches through a box so each case picks the reply and counts the fetches
  (define now (box 1000))
  (define next (box (reply (doc))))
  (define fetches (box 0))
  (define (fetch-stub url)
    (set-box! fetches (add1 (unbox fetches)))
    (define r (unbox next))
    (if (exn? r) (raise r) r))
  (define app (oauth-app "https://orq.example" "https://orq.example/mcp" '(("decks" . "d"))
                         values (λ (s e) #t) fetch-stub (λ () (unbox now))))
  (define (fresh!) (values (make-memory-store) (make-negative-cache)))
  (define (resolve-with reply-value)
    (define-values (store nc) (fresh!))
    (set-box! next reply-value)
    (resolve-client app store nc id))

  (test-case "a valid document gives a verified client"
    (define c (resolve-with (reply (doc 'client_uri "https://app.example" 'logo_uri "http://insecure"))))
    (check-equal? (client-id c) id)
    (check-equal? (client-kind c) 'metadata-document)
    (check-equal? (client-name c) "App")
    (check-equal? (client-uri c) "https://app.example")
    (check-false (client-logo-uri c) "an http logo is dropped")
    (check-true (client-refresh? c))
    (check-equal? (client-redirect-uris c) '("https://app.example/cb")))

  (test-case "self-asserted names stay display text and foreign URIs are dropped"
    (define c (resolve-with (reply (doc 'client_name "Cla\u202Eude\u200B" 'client_uri "https://claude.ai"
                                        'logo_uri "https://claude.ai/logo.png"))))
    (check-equal? (client-name c) "Claude")
    (check-false (client-uri c))
    (check-false (client-logo-uri c))
    (check-equal? (client-uri (resolve-with (reply (doc 'client_uri "https://app.example/about")))) "https://app.example/about")
    (check-equal? (client-name (resolve-with (reply (hasheq 'client_id id 'redirect_uris '("https://app.example/cb") 'client_name "\u200B"))))
                  "app.example"))

  (test-case "grant_types decide whether refresh tokens are allowed"
    (check-false (client-refresh? (resolve-with (reply (doc 'grant_types '("authorization_code"))))))
    (check-true (client-refresh? (resolve-with (reply (doc 'grant_types '("authorization_code" "refresh_token"))))))
    (check-false (resolve-with (reply (doc 'grant_types '("refresh_token")))))
    (check-false (resolve-with (reply (doc 'grant_types "authorization_code")))))

  (test-case "a document that does not check out is refused"
    (for ([bad (list (reply (doc 'client_id "https://other.example/c.json"))
                     (reply (hasheq 'client_id id))
                     (reply (hasheq 'client_id id 'redirect_uris '()))
                     (reply (hasheq 'client_id id 'redirect_uris '("http://app.example/cb")))
                     (reply (hasheq 'client_id id 'redirect_uris '("myapp://cb")))
                     (reply (doc 'token_endpoint_auth_method "client_secret_basic"))
                     (reply (doc 'client_secret "shh"))
                     (reply '(1 2 3))
                     (reply #"not json")
                     (reply (make-bytes 6000 32))
                     (reply (doc) #:type "text/html")
                     (reply (doc) #:type #f)
                     (reply (doc) #:status 302)
                     (reply (doc) #:status 404)
                     (exn:fail "boom" (current-continuation-marks)))])
      (check-false (resolve-with bad))))

  (test-case "content type may carry parameters"
    (check-true (client? (resolve-with (reply (doc) #:type "Application/JSON; charset=utf-8")))))

  (test-case "a non-URL client id is looked up in the store, never fetched"
    (define-values (store nc) (fresh!))
    (set-box! fetches 0)
    (store-client-put! store (client "abc" 'registered "R" #f #f '("https://r.example/cb") #f 0 #f))
    (check-equal? (client-name (resolve-client app store nc "abc")) "R")
    (check-false (resolve-client app store nc "nope"))
    (check-equal? (unbox fetches) 0))

  (test-case "fetched clients are cached for max-age clamped to 5 minutes .. 24 hours"
    (for ([cc '(#f "max-age=10" "max-age=300" "private, max-age=3600" "max-age=999999999" "no-store")]
          [ttl (list 300 300 300 3600 86400 300)])
      (define-values (store nc) (fresh!))
      (set-box! now 1000)
      (set-box! next (reply (doc) #:cc cc))
      (set-box! fetches 0)
      (check-true (client? (resolve-client app store nc id)))
      (check-equal? (client-expires (store-client-ref store id)) (+ 1000 ttl) cc)
      (set-box! now (+ 1000 ttl -1))
      (resolve-client app store nc id)
      (check-equal? (unbox fetches) 1 "still cached")
      (set-box! now (+ 1000 ttl))
      (resolve-client app store nc id)
      (check-equal? (unbox fetches) 2 "refetched when stale")))

  (test-case "failures are remembered for five minutes"
    (define-values (store nc) (fresh!))
    (set-box! now 1000)
    (set-box! next (reply (doc) #:status 500))
    (set-box! fetches 0)
    (check-false (resolve-client app store nc id))
    (check-false (resolve-client app store nc id))
    (check-equal? (unbox fetches) 1)
    (set-box! now 1300)
    (set-box! next (reply (doc)))
    (check-true (client? (resolve-client app store nc id)))
    (check-equal? (unbox fetches) 2))

  (test-case "swept negative entries are forgotten"
    (define-values (store nc) (fresh!))
    (set-box! now 1000)
    (set-box! next (reply (doc) #:status 500))
    (resolve-client app store nc id)
    (negative-cache-sweep! nc 1100)
    (check-true (recently-failed? nc id 1100))
    (negative-cache-sweep! nc 1300)
    (check-false (recently-failed? nc id 1300)))

  (test-case "a full negative cache evicts the oldest entry, not everything"
    (define-values (store nc) (fresh!))
    (for ([i (in-range max-negative-entries)])
      (remember-failure! nc (format "id~a" i) (+ 1000 i)))
    (remember-failure! nc "newest" 5000)
    (check-false (recently-failed? nc "id0" 1000))
    (check-true (recently-failed? nc "id1" 1000))
    (check-true (recently-failed? nc "newest" 1000))))
