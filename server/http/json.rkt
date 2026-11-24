#lang racket/base
;; The HTTP edge: JSON responses, API errors, request-body parsing, and the explicit
;; struct -> jsexpr encoders (the only place domain data becomes hashes).
(require racket/contract/base racket/match racket/list racket/port racket/format json net/url web-server/http
         (prefix-in o: "../oauth/data.rkt") "../domain.rkt" "../qa.rkt" "../live/snapshot.rkt" "../results.rkt")
(provide (contract-out
          [struct (exn:api exn:fail) ([message string?] [continuation-marks continuation-mark-set?] [status natural-number/c] [code string?] [field (or/c string? #f)])]
          [api-error! (->* (natural-number/c string? string?) ((or/c string? #f)) none/c)]
          [not-found! (->* () (string?) none/c)]
          [json-response (->* (jsexpr?) (#:status natural-number/c #:headers (listof header?)) response?)]
          [no-content (->* () (#:headers (listof header?)) response?)]
          [error-response (->* (natural-number/c string? string?) ((or/c string? #f)) response?)]
          [busy-response (-> response?)]
          [request-json (-> request? hash?)]
          [query-param (-> request? symbol? (or/c string? #f))]
          [me->jsexpr (-> user? limits? natural-number/c jsexpr?)]
          [deck->jsexpr (-> deck? boolean? jsexpr?)]
          [share->jsexpr (-> share? jsexpr?)]
          [presentation-listing->jsexpr (-> presentation-listing? boolean? jsexpr?)]
          [presentation-detail->jsexpr (-> deck? boolean? (listof poll?) (listof session-view?) jsexpr?)]
          [poll->jsexpr (-> poll? jsexpr?)]
          [option->jsexpr (-> option? jsexpr?)]
          [qa-question->jsexpr (-> qa-question? jsexpr?)]
          [qa-state->jsexpr (-> qa-state? jsexpr?)]
          [qa-results->jsexpr (-> qa-state? jsexpr?)]
          [session-view->jsexpr (-> session-view? jsexpr?)]
          [session-info->jsexpr (-> presentation? session? jsexpr?)]
          [vote-receipt->jsexpr (-> id/c (listof id/c) jsexpr?)]
          [session-results->jsexpr (-> session-results? jsexpr?)]
          [snapshot->jsexpr (-> snapshot? jsexpr?)]
          [pending-info->jsexpr (-> o:pending-info? (listof (cons/c string? string?)) jsexpr?)]
          [grant-info->jsexpr (-> o:grant-info? jsexpr?)]
          [mcp-deck-list->jsexpr (-> (listof presentation-listing?) hash? jsexpr?)]
          [mcp-deck->jsexpr (-> deck? boolean? (listof poll?) boolean? jsexpr?)]
          [mcp-poll-deleted->jsexpr (-> id/c jsexpr?)]
          [mcp-deck-renamed->jsexpr (-> id/c string? jsexpr?)]
          [mcp-qa-set->jsexpr (-> id/c boolean? jsexpr?)]
          [mcp-session->jsexpr (-> session? jsexpr?)]
          [mcp-sessions->jsexpr (-> id/c (listof session?) jsexpr?)]
          [mcp-session-results->jsexpr (-> session-results? jsexpr?)]
          [mcp-results->jsexpr (-> presentation? natural-number/c boolean? (listof session-results?) jsexpr?)]
          [pdf-response (-> input-port? (listof header?) response?)]))

;; An ApiError is an (exn:api String Marks Natural String (or String #f))
;; interp. a failure with the HTTP status, machine code and (optionally) offending field to report.
(struct exn:api exn:fail (status code field))


;; Natural String String [(or String #f)] -> Nothing
;; raises an ApiError
(define (api-error! status code message [field #f])
  (raise (exn:api message (current-continuation-marks) status code field)))


;; [String] -> Nothing
(define (not-found! [what "not found"]) (api-error! 404 "not_found" what))


;; Natural -> Bytes
;; reason phrases of the statuses the API uses
(define reasons
  (hasheqv 200 #"OK" 201 #"Created" 202 #"Accepted" 204 #"No Content" 302 #"Found" 400 #"Bad Request" 401 #"Unauthorized" 403 #"Forbidden"
           404 #"Not Found" 405 #"Method Not Allowed" 409 #"Conflict" 410 #"Gone" 413 #"Payload Too Large" 422 #"Unprocessable Entity" 429 #"Too Many Requests" 500 #"Internal Server Error" 503 #"Service Unavailable"))


;; Natural Bytes [Listof Header] Bytes -> Response
(define (full status mime headers body)
  (response/full status (hash-ref reasons status #"") (current-seconds) mime headers (list body)))


;; JSExpr [#:status Natural] [#:headers [Listof Header]] -> Response
(define (json-response v #:status [status 200] #:headers [headers '()])
  (full status #"application/json; charset=utf-8" headers (jsexpr->bytes v)))


;; [#:headers [Listof Header]] -> Response
(define (no-content #:headers [headers '()])
  (response/full 204 #"No Content" (current-seconds) #f headers '()))


;; Natural String String [(or String #f)] -> Response
;; the {error, message, field?} body
(define (error-response status code message [field #f])
  (json-response (let ([h (hasheq 'error code 'message message)]) (if field (hash-set h 'field field) h))
                 #:status status))

;; -> Response
;; 503: the database pool stayed full; the client should retry shortly
(define (busy-response)
  (define r (error-response 503 "busy" "the server is busy, try again"))
  (struct-copy response r [headers (cons (header #"Retry-After" #"1") (response-headers r))]))

;; Request -> JSObject
;; the JSON object in the request body, or 400
(define (request-json req)
  (define body (or (request-post-data/raw req) #""))
  (define v (with-handlers ([exn:fail? (λ (_) #f)]) (bytes->jsexpr body)))
  (if (hash? v) v (api-error! 400 "bad_request" "body must be a JSON object")))

;; Request Symbol -> (or String #f)
(define (query-param req key)
  (define p (assq key (url-query (request-uri req))))
  (and p (cdr p)))

;; ------------------------------------------------------------------ encoders
;; Any -> JSExpr
;; #f is JSON null
(define (or-null v) (or v 'null))

;; User Limits Natural -> JSExpr
;; GET /api/me: the user, and their membership with the storage used so far
(define (me->jsexpr u l used)
  (hasheq 'user (hasheq 'id (user-id u) 'email (or (user-email u) 'null) 'name (user-name u))
          'membership (hasheq 'plan (or-null (limits-plan l)) 'status (user-status u) 'storage_used used
                              'storage_quota (or-null (limits-storage-quota-bytes l))
                              'max_upload_bytes (limits-max-upload-bytes l))))

;; Presentation Boolean -> JSExpr
;; qa? is the deck's Q&A setting, which the presentation row does not carry
(define (presentation->jsexpr p qa?)
  (hasheq 'id (presentation-id p) 'title (presentation-title p) 'page_count (presentation-page-count p)
          'qa_enabled qa? 'created_at (presentation-created-at p) 'archived_at (or-null (presentation-archived-at p))))

;; Deck Boolean -> JSExpr
;; the presentation with its owner and what the asking user may do with it
(define (deck->jsexpr dk qa?)
  (match-define (access owner? _ edit? moderate? copy? results?) (deck-access dk))
  (hash-set* (presentation->jsexpr (deck-presentation dk) qa?)
             'owner (hasheq 'email (owner-email (deck-owner dk)) 'name (owner-name (deck-owner dk)))
             'access (hasheq 'owner owner? 'edit edit? 'moderate moderate? 'copy copy? 'results results?)))

;; Share -> JSExpr
(define (share->jsexpr sh)
  (hasheq 'email (share-email sh) 'edit (share-edit? sh) 'moderate (share-moderate? sh)
          'copy (share-copy? sh) 'results (share-results? sh)))

;; PresentationListing Boolean -> JSExpr
(define (presentation-listing->jsexpr l qa?)
  (hash-set (deck->jsexpr (presentation-listing-deck l) qa?) 'live_sessions (presentation-listing-live-sessions l)))

;; Option -> JSExpr
(define (option->jsexpr o) (hasheq 'id (option-id o) 'idx (option-idx o) 'label (option-label o) 'exclusive (option-exclusive? o)))

;; Poll -> JSExpr
(define (poll->jsexpr p)
  (hasheq 'id (poll-id p) 'presentation_id (poll-presentation-id p) 'slide (or-null (poll-slide p))
          'position (poll-position p) 'question (poll-question p) 'kind (poll-kind p)
          'options (map option->jsexpr (poll-options p)) 'has_runs (poll-has-runs? p)
          'allow_additional_answers (poll-allow-additional? p) 'show_results (poll-show-results? p) 'archived_at (or-null (poll-archived-at p))))

;; SessionView -> JSExpr
(define (session-view->jsexpr v)
  (match-define (session-view s audience screen) v)
  (hasheq 'id (session-id s) 'presentation_id (session-presentation-id s) 'code (session-code s) 'screen_code (session-screen-code s)
          'label (session-label s) 'started_at (session-started-at s) 'ended_at (or-null (session-ended-at s))
          'audience_url audience 'screen_url screen))

;; Deck [Listof Poll] [Listof SessionView] -> JSExpr
(define (presentation-detail->jsexpr dk qa? polls views)
  (hash-set* (deck->jsexpr dk qa?) 'polls (map poll->jsexpr polls) 'sessions (map session-view->jsexpr views)))

;; Tally -> JSExpr
(define (tally->jsexpr t) (hasheq 'id (tally-id t) 'label (tally-label t) 'count (tally-count t) 'exclusive (tally-exclusive? t)))
;; Choice -> JSExpr
(define (choice->jsexpr c) (hasheq 'id (choice-id c) 'label (choice-label c) 'exclusive (choice-exclusive? c)))
;; SessionBrief -> JSExpr
(define (session-brief->jsexpr s) (hasheq 'code (session-brief-code s) 'label (session-brief-label s)))
;; DeckBrief -> JSExpr
(define (deck-brief->jsexpr d) (hasheq 'id (deck-brief-id d) 'title (deck-brief-title d)))
;; DeckInfo -> JSExpr
(define (deck-info->jsexpr d)
  (hasheq 'id (deck-info-id d) 'title (deck-info-title d) 'page_count (deck-info-page-count d)))

;; (or AudiencePoll #f) -> JSExpr
(define (audience-poll->jsexpr p)
  (match p
    [#f 'null]
    [(audience-poll id q kind open? choices)
     (hasheq 'run_id id 'question q 'kind kind 'open open? 'options (map choice->jsexpr choices))]))

;; ScreenOption -> JSExpr
;; the count is null until revealed
(define (screen-option->jsexpr o)
  (hasheq 'id (screen-option-id o) 'label (screen-option-label o) 'count (or-null (screen-option-count o))))

;; (or ScreenOverlay #f) -> JSExpr
;; a tagged union on `type`
(define (screen-overlay->jsexpr o)
  (match o
    [#f 'null]
    [(qr-overlay) (hasheq 'type "qr")]
    [(screen-qa question open?)
     (hasheq 'type "qa" 'open open?
             'question (if question (hasheq 'id (qa-question-id question) 'text (qa-question-body question)) 'null))]
    [(screen-poll id q kind open? revealed? options total)
     (hasheq 'type "poll" 'run_id id 'question q 'kind kind 'open open? 'revealed revealed?
             'total_voters total 'options (map screen-option->jsexpr options))]))

;; (or Overlay #f) -> JSExpr
;; a tagged union on `type`
(define (overlay->jsexpr o)
  (match o
    [#f 'null]
    [(qr-overlay) (hasheq 'type "qr")]
    [(qa-overlay id) (hasheq 'type "qa" 'question_id (or-null id))]
    [(poll-overlay run-id revealed?) (hasheq 'type "poll" 'run_id run-id 'revealed revealed?)]))

;; RunSummary -> JSExpr
(define (run-summary->jsexpr r)
  (match-define (run-summary run-id poll-id q kind opened closed total) r)
  (hasheq 'run_id run-id 'poll_id poll-id 'question q 'kind kind 'opened_at opened 'closed_at (or-null closed)
          'total_voters total))

;; (or ModeratorOpenRun #f) -> JSExpr
(define (moderator-open-run->jsexpr c)
  (match c
    [#f 'null]
    [(moderator-open-run run-id poll-id q kind opened tallies total allow-additional?)
     (hasheq 'run_id run-id 'poll_id poll-id 'question q 'kind kind 'opened_at opened
             'options (map tally->jsexpr tallies) 'total_voters total 'allow_additional_answers allow-additional?)]))

;; Id JSExpr (or PollRotation #f) -> JSExpr
;; the projected slide, overlay and optional page commands
(define (stage->jsexpr slide overlay rotation)
  (define base (hasheq 'slide slide 'overlay overlay))
  (match rotation
    [(poll-rotation paused? advance) (hash-set base 'rotation (hasheq 'paused paused? 'advance advance))]
    [#f base]))

;; Snapshot -> JSExpr
;; the SSE `snapshot` payload for each role
(define (snapshot->jsexpr snap)
  (match snap
    [(audience-snapshot session pres poll my-vote qa)
     (hasheq 'session (session-brief->jsexpr session) 'presentation (deck-brief->jsexpr pres)
             'poll (audience-poll->jsexpr poll) 'my_vote (or-null my-vote) 'qa (qa-audience->jsexpr qa))]
    [(screen-snapshot session pres join-url (screen-stage slide overlay rotation))
     (hasheq 'session (session-brief->jsexpr session) 'presentation (deck-info->jsexpr pres) 'join_url join-url
             'stage (stage->jsexpr slide (screen-overlay->jsexpr overlay) rotation))]
    [(moderator-snapshot (moderator-session code screen-code label started ended) pres audience-url screen-url
                     (connections audience screen) (stage slide overlay rotation) open-run runs qa pages)
     (define base
       (hasheq 'session (hasheq 'code code 'screen_code screen-code 'label label 'started_at started 'ended_at (or-null ended))
               'presentation (deck-info->jsexpr pres)
               'audience_url audience-url 'screen_url screen-url
               'connections (hasheq 'audience audience 'screen screen)
               'stage (stage->jsexpr slide (overlay->jsexpr overlay) rotation)
               'open_run (moderator-open-run->jsexpr open-run) 'runs (map run-summary->jsexpr runs) 'qa (qa-state->jsexpr qa)))
     (if (null? pages) base
         (hash-set base 'screen_pages
                   (for/list ([p pages]) (hasheq 'page (screen-page-number p) 'total (screen-page-total p)))))]
    [(editor-snapshot (session-brief code label) started ended pres audience-url open-run)
     (hasheq 'session (hasheq 'code code 'screen_code 'null 'label label 'started_at started 'ended_at (or-null ended))
             'presentation (deck-info->jsexpr pres) 'audience_url audience-url 'screen_url 'null
             'connections 'null 'stage 'null 'qa 'null 'runs '()
             'open_run (moderator-open-run->jsexpr open-run))]))

 ;; QaQuestion -> JSExpr
;; a question without its private participant identity.
(define (qa-question->jsexpr q)
  (hasheq 'id (qa-question-id q) 'text (qa-question-body q) 'status (qa-question-status q)
          'created_at (qa-question-created-at q) 'updated_at (qa-question-updated-at q)))

;; QaState -> JSExpr
;; the author-filtered audience view; projector selection belongs only to moderators.
(define (qa-audience->jsexpr qa)
  (hasheq 'enabled (qa-state-enabled? qa) 'open (qa-state-open? qa) 'started (qa-state-started? qa)
          'questions (map qa-question->jsexpr (qa-state-questions qa))))

;; QaState -> JSExpr
;; the moderator inbox and selected question.
(define (qa-state->jsexpr qa)
  (hash-set (qa-audience->jsexpr qa) 'selected_question_id (or-null (qa-state-selected-id qa))))

;; QaState -> JSExpr
;; session results retain the inbox without live submission controls.
(define (qa-results->jsexpr qa)
  (hasheq 'enabled (qa-state-enabled? qa) 'questions (map qa-question->jsexpr (qa-state-questions qa))))

;; InputPort [Listof Header] -> Response
;; streams a PDF; the port is closed once it has been sent (or the client went away)
(define (pdf-response in headers)
  (response/output #:mime-type #"application/pdf" #:headers headers
                   (λ (out) (dynamic-wind void (λ () (copy-port in out)) (λ () (close-input-port in))))))

;; Presentation Session -> JSExpr
;; the public session-info body
(define (session-info->jsexpr p s)
  (hasheq 'presentation (hasheq 'id (presentation-id p) 'title (presentation-title p) 'page_count (presentation-page-count p))
          'session (hasheq 'code (session-code s) 'label (session-label s))))

;; Id [Listof Id] -> JSExpr
;; the acknowledgement of a recorded vote
(define (vote-receipt->jsexpr run-id option-ids) (hasheq 'run_id run-id 'option_ids option-ids))

;; OptionCount -> JSExpr
(define (option-count->jsexpr o)
  (hasheq 'id (option-count-id o) 'idx (option-count-idx o) 'label (option-count-label o) 'count (option-count-count o)))

;; RunResult -> JSExpr
(define (run-result->jsexpr r)
  (hasheq 'run_id (run-result-run-id r) 'poll_id (run-result-poll-id r) 'slide (or-null (run-result-slide r))
          'question (run-result-question r) 'kind (run-result-kind r)
          'opened_at (run-result-opened-at r) 'closed_at (or-null (run-result-closed-at r))
          'total_voters (run-result-total-voters r) 'peak_audience (or-null (run-result-peak-audience r))
          'participation (or-null (run-participation r)) 'median_seconds_to_vote (or-null (run-result-median-seconds r))
          'changed_voters (or-null (run-result-changed-voters r))
          'options (map option-count->jsexpr (run-result-options r))))

;; SessionResults -> JSExpr
;; the moderator results body
(define (session-results->jsexpr sr)
  (match-define (session-results s p t runs) sr)
  (hasheq 'session (hasheq 'code (session-code s) 'label (session-label s) 'started_at (session-started-at s)
                           'ended_at (or-null (session-ended-at s)))
          'presentation (hasheq 'id (presentation-id p) 'title (presentation-title p))
          'summary (hasheq 'unique_voters (results-totals-unique-voters t)
                           'peak_audience (or-null (results-totals-peak-audience t))
                           'runs (length runs)
                           'avg_participation (or-null (average-participation runs))
                           'median_seconds_to_vote (or-null (results-totals-median-seconds t))
                           'changed_votes (or-null (results-totals-changed-votes t))
                           'changed_voters (or-null (results-totals-changed-voters t)))
          'runs (map run-result->jsexpr runs) 'qa (hasheq 'enabled #f 'questions '())))

;; ------------------------------------------------------------------ MCP encoders
;; What the MCP tools return: aggregates only, never join codes, raw votes or Q&A text.

;; [Listof PresentationListing] (Hash Id Boolean) -> JSExpr
;; list_decks: the listings, each with its deck's Q&A setting (absent from `qa` reads as off)
(define (mcp-deck-list->jsexpr listings qa)
  (hasheq 'decks (for/list ([l (in-list listings)]) (presentation-listing->jsexpr l (hash-ref qa (listing-id l) #f)))))

;; Deck Boolean [Listof Poll] Boolean -> JSExpr
;; get_deck: the deck with its flat list of polls; `disabled` only when the edition switched the deck off
(define (mcp-deck->jsexpr dk qa? polls disabled?)
  (define detail (hash-set (deck->jsexpr dk qa?) 'polls (map poll->jsexpr polls)))
  (if disabled? (hash-set detail 'disabled #t) detail))

;; Id -> JSExpr
(define (mcp-poll-deleted->jsexpr id) (hasheq 'deleted #t 'poll_id id))

;; Id String -> JSExpr
(define (mcp-deck-renamed->jsexpr id title) (hasheq 'id id 'title title))

;; Id Boolean -> JSExpr
(define (mcp-qa-set->jsexpr id enabled?) (hasheq 'id id 'qa_enabled enabled?))

;; Session -> JSExpr
;; a session as list_sessions shows it; never its join codes
(define (mcp-session->jsexpr s)
  (hasheq 'session_id (session-id s) 'label (session-label s) 'started_at (session-started-at s)
          'ended_at (or-null (session-ended-at s))))

;; Id [Listof Session] -> JSExpr
(define (mcp-sessions->jsexpr deck-id sessions)
  (hasheq 'deck_id deck-id 'sessions (map mcp-session->jsexpr sessions)))

;; RunResult -> JSExpr
;; one poll run: its question, times, number of voters and the count of every option
(define (mcp-run->jsexpr r)
  (hasheq 'run_id (run-result-run-id r) 'poll_id (run-result-poll-id r) 'slide (or-null (run-result-slide r))
          'question (run-result-question r) 'kind (run-result-kind r)
          'opened_at (run-result-opened-at r) 'closed_at (or-null (run-result-closed-at r))
          'total_voters (run-result-total-voters r)
          'options (for/list ([o (run-result-options r)]) (hasheq 'label (option-count-label o) 'count (option-count-count o)))))

;; SessionResults -> JSExpr
;; one session as aggregates: label, times and, per poll run, the count of every option and the voters.
;; The join codes, the votes and the Q&A are left out
(define (mcp-session-results->jsexpr sr)
  (match-define (session-results s _ t runs) sr)
  (hash-set* (mcp-session->jsexpr s) 'unique_voters (results-totals-unique-voters t) 'runs (map mcp-run->jsexpr runs)))

;; Presentation Natural Boolean [Listof SessionResults] -> JSExpr
;; get_results: the chosen sessions of a deck out of `total` sessions; `truncated?` when more exist
(define (mcp-results->jsexpr p total truncated? results)
  (hasheq 'deck_id (presentation-id p) 'title (presentation-title p) 'total_sessions total 'truncated truncated?
          'sessions (map mcp-session-results->jsexpr results)))

;; Natural -> String
;; the ISO-8601 UTC timestamp, to the millisecond, of epoch seconds
(define (epoch->iso secs)
  (define d (seconds->date secs #f))
  (define (two n) (~r n #:min-width 2 #:pad-string "0"))
  (format "~a-~a-~aT~a:~a:~a.000Z" (~r (date-year d) #:min-width 4 #:pad-string "0") (two (date-month d)) (two (date-day d))
          (two (date-hour d)) (two (date-minute d)) (two (date-second d))))

;; String (or String #f) (or String #f) Boolean -> JSExpr
;; the {name, host, uri, verified} of an OAuth client
(define (oauth-client->jsexpr name host uri verified?)
  (hasheq 'name name 'host (or-null host) 'uri (or-null uri) 'verified verified?))

;; PendingInfo (Listof (cons String String)) -> JSExpr
;; an OAuth authorization request for the consent page; `descriptions` are the app's scopes by name
(define (pending-info->jsexpr p descriptions)
  (hasheq 'id (o:pending-info-id p)
          'client (oauth-client->jsexpr (o:pending-info-client-name p) (o:pending-info-client-host p)
                                        (o:pending-info-client-uri p) (o:pending-info-verified? p))
          'redirect_host (o:pending-info-redirect-host p)
          'redirect_host_differs (o:pending-info-redirect-host-differs? p)
          'scopes (for/list ([s (in-list (o:pending-info-scopes p))])
                    (hasheq 'name (car s) 'description (cond [(assoc (car s) descriptions) => cdr] [else ""])
                            'requested (cdr s)))))

;; GrantInfo -> JSExpr
;; a connected app
(define (grant-info->jsexpr g)
  (hasheq 'id (o:grant-info-id g)
          'client (oauth-client->jsexpr (o:grant-info-client-name g) (o:grant-info-client-host g)
                                        (o:grant-info-client-uri g) (o:grant-info-verified? g))
          'scopes (o:grant-info-scopes g)
          'created_at (epoch->iso (o:grant-info-created g))
          'last_used_at (let ([t (o:grant-info-last-used g)]) (if t (epoch->iso t) 'null))
          'needs_reconnect (not (o:grant-info-current? g))))

(module+ test
  (require rackunit racket/runtime-path)
  (define-runtime-path fixtures "../../docs/api-fixtures")
  (define (fixture name) (call-with-input-file (build-path fixtures name) read-json))
  (define (body-of r) (let ([o (open-output-bytes)]) ((response-output r) o) (get-output-bytes o)))
  (test-case "error response shape"
    (define r (error-response 422 "invalid" "bad" "title"))
    (check-equal? (response-code r) 422)
    (check-equal? (bytes->jsexpr (body-of r)) (hasheq 'error "invalid" 'message "bad" 'field "title")))
  (test-case "no field when absent"
    (check-equal? (bytes->jsexpr (body-of (error-response 404 "not_found" "x"))) (hasheq 'error "not_found" 'message "x")))
  (test-case "json response and 204"
    (check-equal? (bytes->jsexpr (body-of (json-response (hasheq 'a 1) #:status 201))) (hasheq 'a 1))
    (check-equal? (response-code (no-content)) 204))
  (test-case "api-error! raises exn:api"
    (check-exn exn:api? (λ () (api-error! 409 "x" "y"))))
  (test-case "encoders reproduce the contract fixtures"
    (define shared-deck (deck (presentation 7 "Intro to HtDP" 42 "2026-11-15T09:00:00.000Z" #f)
                              (owner "ada@example.org" "Ada")
                              (access #f #t #f #t #f #f)))
    (check-equal? (deck->jsexpr shared-deck #f) (fixture "presentation.json"))
    (check-equal? (presentation-listing->jsexpr (presentation-listing shared-deck 1) #f) (fixture "presentation-listing.json"))
    (check-equal? (list (share->jsexpr (share "bob@example.org" #f #t #f #f))) (fixture "shares.json"))
    (check-equal? (me->jsexpr (user 3 "teacher@example.org" #t "Ada Teacher" "active") (limits 5242880 33554432 "free") 2097152)
                  (fixture "me.json"))
    (check-equal? (me->jsexpr (user 3 "teacher@example.org" #t "Ada Teacher" "active") (limits 5242880 #f #f) 2097152)
                  (fixture "me-unlimited.json"))
    (check-equal? (poll->jsexpr (poll 3 7 5 1 "Which are pure functions?" "multi"
                                      (list (option 101 0 "square" #f) (option 102 1 "random" #f) (option 103 2 "string-append" #f)) #f #f #f #f))
                  (fixture "poll.json"))
    (check-equal? (session-view->jsexpr
                   (session-view (session 4 7 "abcde23456" "vwxyz76543" "Class A" 1 "2026-11-15T10:00:00.000Z" #f)
                                 "https://orquelo.com/7/abcde23456" "https://orquelo.com/screen/7/vwxyz76543"))
                  (fixture "session.json"))
    (check-equal? (vote-receipt->jsexpr 12 '(101 103)) (fixture "vote-response.json"))
    (check-equal? (session-results->jsexpr
                   (session-results
                    (session 4 7 "abcde23456" "vwxyz76543" "Class A" 1 "2026-11-15T10:00:00.000Z" "2026-11-15T11:30:00.000Z")
                    (presentation 7 "Intro to HtDP" 42 "2026-11-15T09:00:00.000Z" #f)
                    (results-totals 28 31 12.5 5 4)
                    (list (run-result 12 3 5 "Which are pure functions?" "multi" "2026-11-15T10:20:00.000Z" "2026-11-15T10:25:00.000Z"
                                      27 30 14.5 3
                                      (list (option-count 101 0 "square" 21) (option-count 102 1 "random" 3)
                                            (option-count 103 2 "string-append" 18)))
                          (run-result 13 4 8 "Is (random 10) pure?" "single" "2026-11-15T10:40:00.000Z" "2026-11-15T10:43:00.000Z"
                                      24 30 9.5 1
                                      (list (option-count 104 0 "yes" 3) (option-count 105 1 "no" 21))))))
                  (fixture "results.json"))
    (define scopes '(("decks" . "Read and edit your decks, polls and deck settings")
                     ("results" . "Read aggregate poll results of your decks")))
    (check-equal? (pending-info->jsexpr
                   (o:pending-info "Zm9vYmFyYmF6cXV4cXV1eGNvcmdlZ3JhdWx0Z2FycGx" "Example Agent" "agent.example"
                                   "https://agent.example" #t "agent.example" #f '(("decks" . #t) ("results" . #f)))
                   scopes)
                  (fixture "oauth-request.json"))
    (check-equal? (list (grant-info->jsexpr
                         (o:grant-info "q1w2e3r4t5y6u7i8o9p0aa" "Example Agent" "agent.example" "https://agent.example" #t
                                       '("decks" "results") 1794736800 1794737100 #t)))
                  (fixture "oauth-grants.json")))
  (test-case "unverified clients and stale grants encode nulls and needs_reconnect"
    (define g (grant-info->jsexpr (o:grant-info "g" "App" #f #f #f '("decks") 0 #f #f)))
    (check-equal? (hash-ref g 'client) (hasheq 'name "App" 'host 'null 'uri 'null 'verified #f))
    (check-equal? (hash-ref g 'created_at) "1970-01-01T00:00:00.000Z")
    (check-equal? (hash-ref g 'last_used_at) 'null)
    (check-true (hash-ref g 'needs_reconnect))))
