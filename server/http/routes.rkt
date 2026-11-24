#lang racket/base
;; Route table plus the signed-in (session + Origin) guard and the top-level error handler.
(require racket/contract/base racket/string net/url db/base web-server/http web-server/dispatch
         "../config.rkt" "../auth/session.rkt" "../auth/users.rkt" "../db/accounts.rkt" "../db/conn.rkt" "../domain.rkt" "../edition.rkt"
         "../oauth/cimd.rkt" "../oauth/data.rkt"
         "decks.rkt" "deps.rkt" "instrument.rkt" "json.rkt" "oauth-routes.rkt" "public.rkt" "static.rkt")
(provide (contract-out
          [make-handler (->* (deps? plugin?) (#:oauth-fetch (-> string? fetched?)) (-> request? response?))]
          [make-route-kit (-> deps? route-kit?)]
          [check-origin! (-> config? request? void?)]
          [mutating? (-> request? boolean?)]))

;; Request -> String
;; the upper-cased HTTP method
(define (method-of req) (string-upcase (bytes->string/utf-8 (request-method req) #\?)))
;; Request -> Boolean
;; does the method change state?
(define (mutating? req) (and (member (method-of req) '("POST" "PUT" "PATCH" "DELETE")) #t))

;; Request Bytes -> (or String #f)
(define (header-string req name)
  (define h (headers-assq* name (request-headers/raw req)))
  (and h (bytes->string/utf-8 (header-value h) #\?)))

;; Config Request -> Void
;; CSRF guard: mutating requests must carry the configured Origin, else 403
(define (check-origin! cfg req)
  (when (mutating? req)
    (unless (equal? (header-string req #"Origin") (config-public-base-url cfg))
      (api-error! 403 "bad_origin" "Origin does not match"))))

;; Deps Request -> User
;; the logged-in user: 401 unless logged in, 403 when suspended; then the Origin guard
(define (require-user! d req)
  (define u (or (request-user (deps-db d) (deps-cfg d) req) (api-error! 401 "unauthorized" "login required")))
  (when (equal? (user-status u) "suspended") (api-error! 403 "suspended" "account suspended"))
  (check-origin! (deps-cfg d) req)
  u)

;; Natural String -> Response
(define (text-response status body)
  (response/full status (if (= status 200) #"OK" #"Not Found") (current-seconds) #"text/plain; charset=utf-8" '() (list (string->bytes/utf-8 body))))

;; Request -> [Listof String]
(define (path-segments req) (map path/param-path (url-path (request-uri req))))

;; [Listof String] -> Boolean
;; does the path belong to the API (so unknown ones are JSON 404s, not the SPA)?
(define (api-path? segs) (and (pair? segs) (member (car segs) '("api" "auth" "healthz" "oauth" ".well-known" "mcp")) #t))

;; Natural: the largest id Postgres can hold
(define max-id 9223372036854775807)
;; [Listof Any] -> Void
;; 404 for integer path arguments that are negative or beyond bigint
(define (check-ids! args)
  (for ([a args]) (when (and (integer? a) (or (< a 0) (> a max-id))) (api-error! 404 "not_found" "not found"))))

;; -> Response
;; 503: the database pool stayed full; the client should retry shortly
(define (busy-response)
  (define r (error-response 503 "busy" "the server is busy, try again"))
  (struct-copy response r [headers (cons (header #"Retry-After" #"1") (response-headers r))]))

;; Connection Handler -> Handler
;; maps API errors to JSON responses, a full pool to a 503 and anything else to a logged 500.
;; Releases the thread's database connection once the handler returns: streaming responses are
;; written after that, so a stream or an idle keep-alive thread never pins a pooled connection.
(define (guarded db handler)
  (λ (req)
    (dynamic-wind
     void
     (λ ()
       (with-handlers ([exn:api? (λ (e) (error-response (exn:api-status e) (exn:api-code e) (exn-message e) (exn:api-field e)))]
                       [exn:fail:pool-timeout? (λ (e) (busy-response))]
                       [exn:fail? (λ (e)
                                    (log-error "request failed: ~a" (exn-message e))
                                    (error-response 500 "internal" "internal error"))])
         (handler req)))
     (λ () (disconnect db)))))

;; Deps -> RouteKit
;; the wrappers that run a route's handler behind the guards, recording the request under its route template
(define (make-route-kit d)
  ;; (signed-in route f) -> route handler running (f d req me arg ...) behind the guard, `me` being the
  ;; logged-in user; `route` is the template the request's metrics are recorded under
  (define ((signed-in route f) req . args)
    (set-route! route)
    (define me (require-user! d req))
    (check-ids! args)
    (apply f d req me args))
  (define ((public route f) req . args) (set-route! route) (check-ids! args) (apply f d req args))
  ;; (named route f) -> route handler (f req ...) recorded under `route`
  (define ((named route f) req . args) (set-route! route) (apply f req args))
  (route-kit d signed-in public named (λ (req) (check-origin! (deps-cfg d) req))))

;; Response -> Response
;; the SPA page of a consent request: never framed (clickjacking) and never leaking its URL as a referrer
(define (consent-page r)
  (struct-copy response r [headers (list* (header #"Content-Security-Policy" #"frame-ancestors 'none'")
                                          (header #"Referrer-Policy" #"no-referrer")
                                          (response-headers r))]))

;; Deps Plugin [#:oauth-fetch (String -> Fetched)] -> Handler
;; the dispatching request handler; every request is recorded under its route template. Requests no core
;; route matches go to the OAuth routes (when the base URL allows them), then to the plugin's routes, whose
;; own fallback is the 404/static one. `oauth-fetch` retrieves client metadata documents.
(define (make-handler d p #:oauth-fetch [oauth-fetch cimd-fetch])
  (define cfg (deps-cfg d))
  (define kit (make-route-kit d))
  (define signed-in (route-kit-signed-in kit))
  (define public (route-kit-public kit))
  (define named (route-kit-named kit))

  (define (with-audience-limit handler)
    (if (audience-plugin? p)
        (λ (d req pid code) (handler d req pid code #:audience-limit (audience-plugin-limit p)))
        handler))

  (define (me req)
    (define u (require-user! d req))
    (json-response (me->jsexpr u ((deps-limits d) (deps-db d) (user-id u)) (storage-used (deps-db d) (user-id u)))))

  (define (logout req)
    (check-origin! cfg req)
    (no-content #:headers (list (clear-user-cookie))))

  (define (fallback req)
    (define segs (path-segments req))
    (cond [(or (api-path? segs) (not (equal? (method-of req) "GET")))
           (set-route! "not_found")
           (api-error! 404 "not_found" "no such endpoint")]
          [else (set-route! "static")
                (define page (static-response (config-static-dir cfg) segs))
                (if (and (pair? segs) (equal? (car segs) "connect")) (consent-page page) page)]))

  (define dispatch-plugin ((plugin-routes p) kit fallback))
  (define oauth-routes (make-oauth-routes d oauth-fetch))
  (define dispatch-rest (if oauth-routes ((oauth-routes-routes oauth-routes) kit dispatch-plugin) dispatch-plugin))
  (define-values (dispatch _url)
    (dispatch-rules
     [("healthz") #:method "get" (named "/healthz" (λ (req) (text-response 200 "ok")))]
     [("api" "me") #:method "get" (named "/api/me" me)]
     [("auth" "logout") #:method "post" (named "/auth/logout" logout)]
     ;; public
     [("api" "s" "cookies") #:method "get" (public "/api/s/cookies" get-participant-choice)]
     [("api" "s" "cookies") #:method "post"
      (named "/api/s/cookies" (λ (req) (check-origin! cfg req) (set-participant-choice d req)))]
     [("api" "s" (integer-arg) (string-arg)) #:method "get" (public "/api/s/:pid/:code" session-info)]
     [("api" "s" (integer-arg) (string-arg) "stream") #:method "get" (public "/api/s/:pid/:code/stream" (with-audience-limit stream-public))]
     [("api" "s" (integer-arg) (string-arg) "vote") #:method "post" (public "/api/s/:pid/:code/vote" (with-audience-limit cast-vote*))]
     [("api" "s" (integer-arg) (string-arg) "qa") #:method "post" (public "/api/s/:pid/:code/qa" (with-audience-limit submit-question*))]
     ;; public, behind the presenter-only screen code
     [("api" "screen" (integer-arg) (string-arg)) #:method "get" (public "/api/screen/:pid/:screen_code" screen-info)]
     [("api" "screen" (integer-arg) (string-arg) "stream") #:method "get" (public "/api/screen/:pid/:screen_code/stream" stream-screen)]
     [("api" "screen" (integer-arg) (string-arg) "page") #:method "post"
      (public "/api/screen/:pid/:screen_code/page"
              (λ (d req pid code) (check-origin! cfg req) (report-screen-page d req pid code)))]
     [("api" "screen" (integer-arg) (string-arg) "slides.pdf") #:method "get" (public "/api/screen/:pid/:screen_code/slides.pdf" slides-pdf)]
     ;; decks
     [("api" "decks") #:method "get" (signed-in "/api/decks" list-presentations*)]
     [("api" "decks") #:method "post" (signed-in "/api/decks" create-presentation)]
     [("api" "decks" (integer-arg)) #:method "get" (signed-in "/api/decks/:id" get-presentation*)]
     [("api" "decks" (integer-arg)) #:method "patch" (signed-in "/api/decks/:id" patch-presentation)]
     [("api" "decks" (integer-arg)) #:method "delete" (signed-in "/api/decks/:id" delete-presentation*)]
     [("api" "decks" (integer-arg) "pdf") #:method "get" (signed-in "/api/decks/:id/pdf" presentation-pdf)]
     [("api" "decks" (integer-arg) "copy") #:method "post" (signed-in "/api/decks/:id/copy" copy-presentation*)]
     [("api" "decks" (integer-arg) "shares") #:method "get" (signed-in "/api/decks/:id/shares" list-shares*)]
     [("api" "decks" (integer-arg) "shares" (string-arg)) #:method "put" (signed-in "/api/decks/:id/shares/:email" put-share*)]
     [("api" "decks" (integer-arg) "shares" (string-arg)) #:method "delete" (signed-in "/api/decks/:id/shares/:email" delete-share*)]
     [("api" "decks" (integer-arg) "polls") #:method "post" (signed-in "/api/decks/:id/polls" create-poll*)]
     [("api" "decks" (integer-arg) "sessions") #:method "post" (signed-in "/api/decks/:id/sessions" create-session)]
     [("api" "decks" (integer-arg) "archive") #:method "post" (signed-in "/api/decks/:id/archive" archive-presentation)]
     [("api" "decks" (integer-arg) "unarchive") #:method "post" (signed-in "/api/decks/:id/unarchive" unarchive-presentation)]
     [("api" "decks" (integer-arg) "qa") #:method "put" (signed-in "/api/decks/:id/qa" set-deck-qa*)]
     ;; polls
     [("api" "polls" (integer-arg)) #:method "put" (signed-in "/api/polls/:id" update-poll*)]
     [("api" "polls" (integer-arg)) #:method "patch" (signed-in "/api/polls/:id" patch-poll*)]
     [("api" "polls" (integer-arg)) #:method "delete" (signed-in "/api/polls/:id" delete-poll*)]
     [("api" "polls" (integer-arg) "duplicate") #:method "post" (signed-in "/api/polls/:id/duplicate" duplicate-poll*)]
     [("api" "polls" (integer-arg) "archive") #:method "post" (signed-in "/api/polls/:id/archive" archive-poll*)]
     [("api" "polls" (integer-arg) "unarchive") #:method "post" (signed-in "/api/polls/:id/unarchive" unarchive-poll*)]
     ;; live sessions
     [("api" "sessions" (string-arg) "qa") #:method "post" (signed-in "/api/sessions/:code/qa" set-qa-open*)]
     [("api" "sessions" (string-arg) "qa" "questions" (integer-arg)) #:method "patch" (signed-in "/api/sessions/:code/qa/questions/:id" set-qa-question-status*)]
     [("api" "sessions" (string-arg) "qa.csv") #:method "get" (signed-in "/api/sessions/:code/qa.csv" qa-csv)]
     [("api" "sessions" (string-arg) "poll" "options") #:method "post" (signed-in "/api/sessions/:code/poll/options" append-run-option*)]
     [("api" "sessions" (string-arg) "end") #:method "post" (signed-in "/api/sessions/:code/end" end-session*)]
     [("api" "sessions" (string-arg) "slide") #:method "post" (signed-in "/api/sessions/:code/slide" set-slide)]
     [("api" "sessions" (string-arg) "overlay") #:method "post" (signed-in "/api/sessions/:code/overlay" show-overlay)]
     [("api" "sessions" (string-arg) "poll" "open") #:method "post" (signed-in "/api/sessions/:code/poll/open" open-poll)]
     [("api" "sessions" (string-arg) "poll" "close") #:method "post" (signed-in "/api/sessions/:code/poll/close" close-poll)]
     [("api" "sessions" (string-arg) "poll" "resume") #:method "post" (signed-in "/api/sessions/:code/poll/resume" resume-poll)]
     [("api" "sessions" (string-arg) "poll" "reveal") #:method "post" (signed-in "/api/sessions/:code/poll/reveal" reveal-poll)]
     [("api" "sessions" (string-arg) "poll" "hide") #:method "post" (signed-in "/api/sessions/:code/poll/hide" hide-poll)]
     [("api" "sessions" (string-arg) "poll" "rotation") #:method "post" (signed-in "/api/sessions/:code/poll/rotation" rotate-poll*)]
     [("api" "sessions" (string-arg) "stream") #:method "get" (signed-in "/api/sessions/:code/stream" stream-moderator)]
     [("api" "sessions" (string-arg) "export.csv") #:method "get" (signed-in "/api/sessions/:code/export.csv" export-csv)]
     [("api" "sessions" (string-arg) "results") #:method "get" (signed-in "/api/sessions/:code/results" session-results*)]
     [("api" "sessions" (string-arg) "results.csv") #:method "get" (signed-in "/api/sessions/:code/results.csv" results-csv)]
     [else dispatch-rest]))
  (define (dispatch-with-storage req)
    (parameterize ([current-deck-disabled? (if (storage-plugin? p)
                                               (storage-plugin-disabled? p)
                                               (current-deck-disabled?))]
                   [current-deck-removed! (if (storage-plugin? p)
                                             (storage-plugin-deck-removed! p)
                                             (current-deck-removed!))])
      (dispatch req)))
  (instrumented (deps-metrics d) (guarded (deps-db d) dispatch-with-storage)))

(module+ test
  (require rackunit racket/promise)
  (define cfg (load-config minimal-env))
  (define (req method [origin #f])
    (make-request method (string->url "/api/decks/x") (if origin (list (make-header #"Origin" origin)) '())
                  (delay '()) #f "127.0.0.1" 80 "127.0.0.1"))
  (define (rejected? thunk) (with-handlers ([exn:api? (λ (e) (exn:api-code e))]) (thunk) #f))

  (test-case "origin guard on mutating requests"
    (check-equal? (rejected? (λ () (check-origin! cfg (req #"POST")))) "bad_origin")
    (check-equal? (rejected? (λ () (check-origin! cfg (req #"DELETE" #"http://evil.com")))) "bad_origin")
    (check-equal? (rejected? (λ () (check-origin! cfg (req #"PUT" #"http://localhost:8080/")))) "bad_origin")
    (check-false (rejected? (λ () (check-origin! cfg (req #"POST" #"http://localhost:8080")))))
    (check-false (rejected? (λ () (check-origin! cfg (req #"PATCH" #"http://localhost:8080"))))))
  (test-case "origin not required for GET"
    (check-false (rejected? (λ () (check-origin! cfg (req #"GET"))))))
  (test-case "mutating methods"
    (check-true (mutating? (req #"post")))
    (check-false (mutating? (req #"GET")))))
