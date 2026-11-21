#lang racket/base
;; Signed-in handlers (the route table guards them with the session and Origin checks).
;; Each is (name deps request me path-arg ...) -> response, declared with define-endpoint; `me` is the
;; logged-in user.
(require racket/contract/base racket/match racket/string db/base web-server/http
         "../qa.rkt" "../db/qa.rkt" "../auth/access.rkt" "../config.rkt" "../db/repo.rkt" "../domain.rkt" "../export.rkt" "../live/codes.rkt" "../live/hub.rkt"
         "../live/load.rkt" "../live/state.rkt" "../metrics/app.rkt" "../results.rkt" "../storage/store.rkt" "../uploads.rkt"
         "deps.rkt" "endpoint.rkt" "inputs.rkt" "json.rkt" "lookup.rkt" "sse.rkt" "validate.rkt")
(provide (contract-out
          [list-presentations* user-handler/c]
          [create-presentation user-handler/c]
          [get-presentation* user-handler/id/c]
          [patch-presentation user-handler/id/c]
          [delete-presentation* user-handler/id/c]
          [copy-presentation* user-handler/id/c]
          [list-shares* user-handler/id/c]
          [put-share* user-handler/id-string/c]
          [delete-share* user-handler/id-string/c]
          [presentation-pdf user-handler/id/c]
          [archive-presentation user-handler/id/c]
          [unarchive-presentation user-handler/id/c]
          [create-poll* user-handler/id/c]
          [update-poll* user-handler/id/c]
          [delete-poll* user-handler/id/c]
          [duplicate-poll* user-handler/id/c]
          [archive-poll* user-handler/id/c]
          [unarchive-poll* user-handler/id/c]
          [create-session user-handler/id/c]
          [patch-poll* user-handler/id/c]
          [end-session* user-handler/code/c]
          [set-slide user-handler/code/c]
          [show-overlay user-handler/code/c]
          [open-poll user-handler/code/c]
          [close-poll user-handler/code/c]
          [resume-poll user-handler/code/c]
          [reveal-poll user-handler/code/c]
          [hide-poll user-handler/code/c]
          [rotate-poll* user-handler/code/c]
          [stream-moderator user-handler/code/c]
          [export-csv user-handler/code/c]
          [session-results* user-handler/code/c]
          [results-csv user-handler/code/c]
          [set-deck-qa* user-handler/id/c]
          [set-qa-open* user-handler/code/c]
          [set-qa-question-status* (-> deps? request? user? string? exact-integer? response?)]
          [append-run-option* user-handler/code/c]
          [qa-csv user-handler/code/c]))

;; Deps -> Connection
(define (db d) (deps-db d))
;; Deps -> Config
(define (cfg d) (deps-cfg d))
;; Deps String Event -> Void
;; applies a live-state event to the session
(define (apply-event! d code ev) (after-db d (λ () (hub-apply! (deps-hub d) code ev))) (void))

;; ------------------------------------------------------------------ presentations
;; Deps User Id [#:status Natural] -> Response
;; the deck as `me` sees it; 404 when it is not visible to them
(define (deck-response d me id #:status [status 200])
  (json-response (hash-set (deck->jsexpr (need-deck d me id 'view)) 'qa_enabled (deck-qa-enabled? (db d) id)) #:status status))

(define-endpoint (list-presentations* d req me)
  (json-response (for/list ([listing (list-presentations (db d) (user-id me) (equal? (query-param req 'archived) "1"))])
                   (hash-set (presentation-listing->jsexpr listing) 'qa_enabled
                             (deck-qa-enabled? (db d) (presentation-id (deck-presentation (presentation-listing-deck listing))))))))

;; (-> X) (-> Void) -> X
;; runs body; if it escapes by exception, break or jump, runs undo
(define (with-undo undo body)
  (define done? #f)
  (dynamic-wind void (λ () (begin0 (body) (set! done? #t))) (λ () (unless done? (undo)))))

;; LimitRefusal -> Nothing
;; 413: the deck breaks the user's limits
(define (limit-refused! why)
  (match why
    ['too-large (api-error! 413 "too_large" "this PDF is larger than the per-deck size limit")]
    ['quota-exceeded (api-error! 413 "quota_exceeded" "this would exceed your storage quota")]))

;; Deps InputPort -> Path
;; the upload in a temporary file; 422 when it is not a PDF or is too large
(define (stage-pdf! d in)
  (define tmp (save-tmp-pdf! (config-upload-dir (cfg d)) in))
  (when (string? tmp) (invalid! 'pdf tmp))
  tmp)

;; Deps User UploadInput Path -> Id
;; inserts the presentation (owned by `me`, within their limits) and stores the PDF; leaves neither
;; a row nor a file if anything fails. The store runs after-db: the thread's pooled connection is
;; released while the (possibly slow, S3) transfer is in flight.
(define (store-presentation! d me in tmp)
  (define id
    (with-undo (λ () (delete-file tmp))
      (λ ()
        (match (add-presentation! (db d) (deps-limits d) (user-id me) (upload-input-title in) (upload-input-page-count in) (file-size tmp))
          [(? symbol? why) (limit-refused! why)]
          [id id]))))
  (define key (new-pdf-key id))
  (with-undo (λ () (delete-presentation! (db d) id) (after-db d (λ () (store-delete! (deps-store d) key)))
                 (when (file-exists? tmp) (delete-file tmp)))
    (λ () (after-db d (λ () (store-put! (deps-store d) key tmp))) (set-pdf-key! (db d) id key)))
  id)

(define-endpoint (create-presentation d req me)
  #:form [in (upload-input [title (text 1 200)] [page-count (count 1 100000)] [pdf (file)])]
  (deck-response d me (store-presentation! d me in (stage-pdf! d (upload-input-pdf in))) #:status 201))

;; Deps Deck -> [Listof SessionView]
;; the deck's sessions, newest first; only for a user who may moderate, since they carry the codes
;; that run a lecture (`screen_code`) and are no business of a viewer
(define (visible-sessions d dk)
  (if (or (access-allows? (deck-access dk) 'moderate) (access-allows? (deck-access dk) 'edit))
      (map (λ (s) (make-session-view (cfg d) s)) (list-sessions (db d) (presentation-id (deck-presentation dk))))
      '()))

(define-endpoint (get-presentation* d req me id)
  #:need [dk (deck me id #:can view)]
  (define detail (hash-set (presentation-detail->jsexpr dk (list-polls (db d) id) (visible-sessions d dk))
                           'qa_enabled (deck-qa-enabled? (db d) id)))
  (json-response
   (if (access-allows? (deck-access dk) 'moderate) detail
       (hash-update detail 'sessions (λ (sessions)
                                      (for/list ([s sessions]) (hash-set* s 'screen_code 'null 'screen_url 'null)))))))

(define-endpoint (patch-presentation d req me id)
  #:need [dk (deck me id #:can edit)]
  #:json [in (title-input [title (string 1 200)])]
  (rename-presentation! (db d) id (title-input-title in))
  (deck-response d me id))

(define-endpoint (delete-presentation* d req me id)
  #:need [dk (deck me id #:can owner)]
  (match (delete-presentation! (db d) id)
    [#f (not-found! "presentation not found")]
    ['session-live (api-error! 409 "session_live" "a lecture is live; end it before deleting the presentation")]
    [key (when (pdf-key? key) (after-db d (λ () (store-delete! (deps-store d) key)))) (no-content)]))

(define-endpoint (presentation-pdf d req me id)
  #:need [dk (deck me id #:can view)]
  (pdf-response (need-pdf d id) '()))

(define-endpoint (copy-presentation* d req me id)
  #:need [dk (deck me id #:can copy)]
  (define from (found (presentation-pdf-key (db d) id) "presentation not found"))
  (unless (pdf-key? from) (api-error! 409 "pdf_pending" "the PDF is still being uploaded; try again shortly"))
  (define new-id
    (match (copy-presentation! (db d) (deps-limits d) (user-id me) id)
      [#f (not-found! "presentation not found")]
      [(? symbol? why) (limit-refused! why)]
      [new-id new-id]))
  (define key (new-pdf-key new-id))
  (with-undo (λ () (delete-presentation! (db d) new-id) (after-db d (λ () (store-delete! (deps-store d) key))))
    (λ ()
      (after-db d (λ () (store-copy! (deps-store d) from key)))
      (set-pdf-key! (db d) new-id key)))
  (deck-response d me new-id #:status 201))

;; ------------------------------------------------------------------ shares
;; String -> String
;; the email trimmed; 422 when it does not look like one. The database lowercases it.
(define (share-email! raw)
  (define email (string-trim raw))
  (unless (and (<= (string-length email) 254) (regexp-match? #px"^[^@\\s]+@[^@\\s]+$" email))
    (invalid! 'email "not an email address"))
  email)

(define-endpoint (list-shares* d req me id)
  #:need [dk (deck me id #:can owner)]
  (json-response (map share->jsexpr (list-shares (db d) id))))

(define-endpoint (put-share* d req me id email)
  #:need [dk (deck me id #:can owner)]
  #:json [in (share-input [edit (boolean)] [moderate (boolean)] [copy (boolean)] [results (boolean)])]
  (match-define (share-input edit? moderate? copy? results?) in)
  (json-response (share->jsexpr (put-share! (db d) id (share (share-email! email) edit? moderate? copy? results?)))))

(define-endpoint (delete-share* d req me id email)
  #:need [dk (deck me id #:can owner)]
  (if (delete-share! (db d) id (share-email! email)) (no-content) (not-found! "share not found")))

;; Deps User Id Boolean -> Response
;; sets the deck's archived state and answers with the deck
(define (archive-response d me id archived?)
  (set-archived! (db d) id archived?)
  (deck-response d me id))

(define-endpoint (archive-presentation d req me id)
  #:need [dk (deck me id #:can owner)]
  (archive-response d me id #t))
(define-endpoint (unarchive-presentation d req me id)
  #:need [dk (deck me id #:can owner)]
  (archive-response d me id #f))

;; ------------------------------------------------------------------ polls
;; -> Nothing
(define (poll-has-runs!) (api-error! 409 "poll_has_runs" "poll has runs; duplicate it to edit"))

;; Request Natural -> PollDraft
;; the poll in the request body, shared by create and update; 422 naming the first bad field
(define (request-poll-draft req page-count)
  (define h (request-json req))
  (poll-draft (body-slide-or-null h 'slide page-count) (body-string h 'question 1 500)
              (body-one-of h 'kind "single" "multi") (request-poll-options h)
              (body-bool-or-default h 'show_results #f) (body-bool-or-default h 'allow_additional_answers #f)))

;; JSObject -> [Listof OptionDraft]
;; validates structured options at the request edge.
(define (request-poll-options h)
  (define raw (hash-ref h 'options #f))
  (unless (and (list? raw) (<= 2 (length raw) 30)) (invalid! 'options "options must have 2 to 30 items"))
  (define options
    (for/list ([o raw])
      (unless (hash? o) (invalid! 'options "each option must be an object"))
      (option-draft (string-trim (body-string o 'label 1 200)) (body-bool-or-default o 'exclusive #f))))
  (when (ormap (λ (o) (string=? "" (option-draft-label o))) options) (invalid! 'options "option labels must not be blank"))
  (when (and (not (equal? (hash-ref h 'kind #f) "multi")) (ormap option-draft-exclusive? options))
    (invalid! 'options "exclusive options require multiple choice"))
  options)

(define-endpoint (create-poll* d req me pid)
  #:need [dk (deck me pid #:can edit)]
  (define draft (request-poll-draft req (presentation-page-count (deck-presentation dk))))
  (json-response (poll->jsexpr (create-poll! (db d) pid draft)) #:status 201))

(define-endpoint (update-poll* d req me id)
  #:need [existing (poll me id #:can edit)] [p (presentation-of existing)]
  (define draft (request-poll-draft req (presentation-page-count p)))
  (match (update-poll! (db d) id draft)
    [#f (not-found! "poll not found")]
    ['has-runs (poll-has-runs!)]
    [updated (json-response (poll->jsexpr updated))]))

;; the display setting stays editable after runs, unlike the poll's content
(define-endpoint (patch-poll* d req me id)
  #:need [pl (poll me id #:can edit)]
  #:json [in (show-results-input [show-results (boolean)])]
  (json-response (poll->jsexpr (found (set-show-results! (db d) id (show-results-input-show-results? in)) "poll not found"))))

(define-endpoint (delete-poll* d req me id)
  #:need [pl (poll me id #:can edit)]
  (match (delete-poll! (db d) id)
    ['ok (no-content)]
    ['has-runs (poll-has-runs!)]
    [#f (not-found! "poll not found")]))

(define-endpoint (duplicate-poll* d req me id)
  #:need [pl (poll me id #:can edit)]
  (json-response (poll->jsexpr (found (duplicate-poll! (db d) id) "poll not found")) #:status 201))

;; Deps Id Boolean -> Response
(define (poll-archive-response d id archived?)
  (match (set-poll-archived! (db d) id archived?)
    [#f (not-found! "poll not found")]
    ['has-no-runs (api-error! 409 "poll_has_no_runs" "poll has no runs; delete it instead")]
    [p (json-response (poll->jsexpr p))]))

(define-endpoint (archive-poll* d req me id)
  #:need [pl (poll me id #:can edit)]
  (poll-archive-response d id #t))
(define-endpoint (unarchive-poll* d req me id)
  #:need [pl (poll me id #:can edit)]
  (poll-archive-response d id #f))

;; ------------------------------------------------------------------ sessions
;; Connection Id String -> Session
;; inserts a session under a fresh random code, retrying on a code collision
(define (insert-session-retrying! c pid label)
  (let loop ([attempts 5])
    (with-handlers ([(λ (e) (and (exn:fail:sql? e) (> attempts 1) (equal? (format "~a" (exn:fail:sql-sqlstate e)) "23505")))
                     (λ (_) (loop (sub1 attempts)))])
      (insert-session! c pid label (random-code) (random-code)))))

(define-endpoint (create-session d req me pid)
  #:need [dk (deck me pid #:can moderate)]
  #:json [in (label-input [label (optional-string 0 100 "")])]
  (define s (insert-session-retrying! (db d) pid (label-input-label in)))
  (json-response (session-view->jsexpr (make-session-view (cfg d) s)) #:status 201))

(define-endpoint (end-session* d req me code)
  #:need [s (session me code #:can moderate #:mutation)]
  (apply-event! d code (lecture-ended (end-session! (db d) (session-id s))))
  (no-content))

(define-endpoint (set-slide d req me code)
  #:need [s (session me code #:can moderate #:mutation)] [p (presentation-of s)]
  #:json [in (slide-input [slide (slide (presentation-page-count p))])]
  (set-slide! (db d) (session-id s) (slide-input-slide in))
  (apply-event! d code (slide-set (slide-input-slide in)))
  (no-content))

(define-endpoint (open-poll d req me code)
  #:need [s (session me code #:can moderate #:mutation)]
  #:json [in (open-input [poll-id (id)] [only-if-idle (optional-boolean #f)])]
  #:need [pl (poll (open-input-poll-id in))]
  (unless (= (poll-presentation-id pl) (session-presentation-id s)) (not-found! "poll not found"))
  (when (poll-archived-at pl) (api-error! 409 "poll_archived" "poll is archived; unarchive it to open it"))
  (define run (open-run! (db d) (session-id s) (poll-id pl) #:only-if-idle? (open-input-only-if-idle? in)))
  (unless run (api-error! 409 "poll_already_open" "Close the current vote before opening another poll."))
  (hide-qa! (db d) (session-id s))
  (when (poll-show-results? pl) (reveal-run! (db d) (poll-run-id run)))
  (apply-event! d code (run-opened run (poll-show-results? pl)))
  (json-response (hasheq 'run_id (poll-run-id run) 'options (map option->jsexpr (poll-run-options run)))))

(define-endpoint (close-poll d req me code)
  #:need [s (session me code #:can moderate #:mutation)] [st (live code)]
  (define open (live-open-run st))
  (when open (check-expected-run! req (poll-run-id open) "The current vote changed. Review it before closing voting."))
  (define closed-at (and open (close-run! (db d) (poll-run-id open))))
  (unless closed-at (api-error! 409 "poll_not_open" "no poll is open"))
  ;; the hub gets the run as the database has it now, with every vote committed so far
  (apply-event! d code (run-closed (found (get-run (db d) (poll-run-id open)) "poll not found")))
  (no-content))

;; Deps Live Id -> Void
;; 409 unless the run is the session's newest and closed; 404 for a run that is not the session's
(define (reopen-run! d st run-id)
  (unless (findf (λ (r) (= (poll-run-id r) run-id)) (live-runs st)) (not-found! "run not found"))
  (unless (resume-run! (db d) run-id)
    (api-error! 409 "run_not_resumable" "only the newest run, once closed, can be resumed")))

(define-endpoint (resume-poll d req me code)
  #:need [s (session me code #:can moderate #:mutation)] [st (live code)]
  #:json [in (resume-input [run-id (id)])]
  (define run-id (resume-input-run-id in))
  (reopen-run! d st run-id)
  (hide-qa! (db d) (session-id s))
  ;; the hub gets the run as the database has it now, with its votes
  (apply-event! d code (run-resumed (found (get-run (db d) run-id) "run not found")
                                    (run-results-shown? (db d) run-id)))
  (json-response (hasheq 'run_id run-id 'options (map option->jsexpr (poll-run-options (get-run (db d) run-id))))))

;; Live -> PollOverlay
;; the poll overlay that is up; 409 when there is none: results are shown and hidden inside it
(define (need-poll-overlay! st)
  (define o (live-overlay st))
  (if (poll-overlay? o) o (api-error! 409 "no_poll_overlay" "the poll is not on the screen")))

;; Request Id String -> Void
;; rejects a command whose optional run_id names a run other than the one it would affect
(define (check-expected-run! req run-id message)
  (define raw (request-post-data/raw req))
  (when (and raw (positive? (bytes-length raw)))
    (define body (request-json req))
    (when (and (hash-has-key? body 'run_id) (not (= (body-id body 'run_id) run-id)))
      (api-error! 409 "poll_run_changed" message))))

;; Deps Request String Live Boolean -> Response
;; changes visibility on the requested overlay, if it is still on screen
(define (set-poll-visibility! d req code st revealed?)
  (define id (poll-overlay-run-id (need-poll-overlay! st)))
  (check-expected-run! req id "The poll on screen changed. Review it before changing result visibility.")
  (when revealed? (reveal-run! (db d) id))
  (apply-event! d code (run-visibility-set id revealed?))
  (no-content))

(define-endpoint (reveal-poll d req me code)
  #:need [s (session me code #:can moderate #:mutation)] [st (live code)]
  (set-poll-visibility! d req code st #t))

(define-endpoint (hide-poll d req me code)
  #:need [s (session me code #:can moderate #:mutation)] [st (live code)]
  (set-poll-visibility! d req code st #f))

(define-endpoint (rotate-poll* d req me code)
  #:need [s (session me code #:can moderate #:mutation)] [st (live code)]
  #:json [in (rotation-input [run-id (id)] [revealed (boolean)] [action (one-of "pause" "resume" "next")])]
  (match-define (poll-overlay id revealed?) (need-poll-overlay! st))
  (unless (and (= id (rotation-input-run-id in)) (eq? revealed? (rotation-input-revealed? in)))
    (api-error! 409 "poll_run_changed" "The poll on screen changed. Review it before moving to another page."))
  (apply-event! d code (poll-rotation-command id revealed? (string->symbol (rotation-input-action in))))
  (no-content))

;; Deps Live (or QrOverlay Id #f) -> (or Overlay #f)
;; the overlay a request asks for; 404 for a run that is not one of this session's. A poll overlay
;; starts revealed iff the run's results were ever shown.
(define (requested-overlay d st req)
  (match req
    [#f #f]
    [(qr-overlay) (qr-overlay)]
    [run-id
     (unless (findf (λ (r) (= (poll-run-id r) run-id)) (live-runs st)) (not-found! "run not found"))
     (poll-overlay run-id (run-results-shown? (db d) run-id))]))

(define-endpoint (show-overlay d req me code)
  #:need [s (session me code #:can moderate #:mutation)] [st (live code)]
  #:json [in (overlay-input [overlay (overlay-request)])]
  (define requested (overlay-input-overlay in))
  (cond [(qa-overlay? requested)
         (qa-result! (show-qa! (db d) (session-id s) (qa-overlay-question-id requested)))
         (apply-event! d code (qa-synced (get-qa (db d) (session-id s))))]
        [else
         (define overlay (requested-overlay d st requested))
         (hide-qa! (db d) (session-id s))
         (apply-event! d code (overlay-set overlay))])
  (no-content))

(define-endpoint (stream-moderator d req me code)
  (define s (need-user-session d me code 'view))
  (define dk (need-deck d me (session-presentation-id s) 'view))
  (define role
    (cond [(access-allows? (deck-access dk) 'moderate) 'moderator]
          [(access-allows? (deck-access dk) 'edit) 'editor]
          [else (api-error! 403 "forbidden" "edit or moderate permission required")]))
  (define h (deps-hub d))
  (sse-response (λ () (hub-subscribe! h code role "moderator"))
                (λ (sb) (hub-unsubscribe! h code sb))
                #:on-delivery (λ (secs) (observe-delivery! (deps-metrics d) 'moderator secs))))

;; String String -> Response
;; the CSV text as a download under the file name
(define (csv-download filename csv)
  (response/full 200 #"OK" (current-seconds) #"text/csv; charset=utf-8"
                 (list (make-header #"Content-Disposition" (string->bytes/utf-8 (format "attachment; filename=\"~a\"" filename))))
                 (list (string->bytes/utf-8 csv))))

(define-endpoint (export-csv d req me code)
  #:need [s (session me code #:can results)]
  (csv-download (format "orquelo-~a.csv" code) (render-csv export-header (export-rows (db d) (session-id s)))))

;; Deps Session Presentation -> SessionResults
(define (results-of d s p)
  (session-results s p (results-totals-row (db d) (session-id s)) (run-results (db d) (session-id s))))

(define-endpoint (session-results* d req me code)
  #:need [s (session me code #:can results)] [p (presentation-of s)]
  (json-response (hash-set (session-results->jsexpr (results-of d s p)) 'qa
                           (qa-results->jsexpr (get-qa (db d) (session-id s))))))

(define-endpoint (results-csv d req me code)
  #:need [s (session me code #:can results)] [p (presentation-of s)]
  (csv-download (format "orquelo-~a-results.csv" code)
                (render-csv results-csv-header (results-csv-rows (results-of d s p)))))

;; Any -> Void
;; maps Q&A repository refusals to public API errors.
(define (qa-result! value)
  (case value
    [(not-found) (not-found! "question not found")]
    [(ended) (api-error! 410 "session_ended" "this session has ended")]
    [(disabled) (api-error! 409 "qa_disabled" "Q&A is not enabled for this session")]
    [(closed) (api-error! 409 "qa_not_open" "Q&A submissions are closed")]
    [(not-pending) (api-error! 409 "question_not_pending" "restore this question before showing it")]
    [else (void)]))

;; Deps Request User Id -> Response
;; configures Q&A availability for future sessions.
(define-endpoint (set-deck-qa* d req me id)
  #:need [dk (deck me id #:can edit)]
  #:json [in (qa-enabled-input [enabled (boolean)])]
  (set-deck-qa! (db d) id (qa-enabled-input-enabled? in))
  (no-content))

;; Deps Request User String -> Response
;; opens or closes submissions without changing the projector.
(define-endpoint (set-qa-open* d req me code)
  #:need [s (session me code #:can moderate #:mutation)]
  #:json [in (qa-open-input [open (boolean)])]
  (qa-result! (set-qa-open! (db d) (session-id s) (qa-open-input-open? in)))
  (apply-event! d code (qa-synced (get-qa (db d) (session-id s))))
  (no-content))

;; Deps Request User String Id -> Response
;; changes a private question disposition and clears it from the projector if needed.
(define-endpoint (set-qa-question-status* d req me code id)
  #:need [s (session me code #:can moderate #:mutation)]
  #:json [in (qa-status-input [status (one-of "pending" "answered" "dismissed")])]
  (qa-result! (set-question-status! (db d) (session-id s) id (qa-status-input-status in)))
  (apply-event! d code (qa-synced (get-qa (db d) (session-id s))))
  (no-content))

;; Deps Request User String -> Response
;; appends one answer to an opted-in open run, without changing its definition.
(define-endpoint (append-run-option* d req me code)
  #:need [s (session me code #:can edit #:mutation)]
  #:json [in (run-option-input [run-id (id)] [label (string 1 200)] [exclusive (boolean)])]
  (define label (string-trim (run-option-input-label in)))
  (when (string=? label "") (invalid! 'label "label must not be blank"))
  (define result (append-run-option! (db d) (session-id s) (run-option-input-run-id in)
                                    (option-draft label (run-option-input-exclusive? in))))
  (match result
    ['poll-not-open (api-error! 409 "poll_not_open" "this poll is not open")]
    ['not-allowed (api-error! 409 "additional_answers_disabled" "this poll does not allow additional answers")]
    ['too-many (invalid! 'label "a poll may have at most 30 options")]
    ['invalid (invalid! 'exclusive "exclusive options require multiple choice")]
    [o
     (apply-event! d code (run-updated (get-run (db d) (run-option-input-run-id in))))
     (json-response (option->jsexpr o) #:status 201)]))

;; Deps Request User String -> Response
;; exports session questions for a user with results access, excluding browser identities.
(define-endpoint (qa-csv d req me code)
  #:need [s (session me code #:can results)]
  (csv-download (format "orquelo-~a-qa.csv" code)
                (render-csv '("question_id" "question" "status" "created_at" "updated_at")
                            (for/list ([q (qa-state-questions (get-qa (db d) (session-id s)))])
                              (list (qa-question-id q) (qa-csv-text (qa-question-body q)) (qa-question-status q)
                                    (qa-question-created-at q) (qa-question-updated-at q))))))

;; String -> String
;; keeps untrusted question text from being interpreted as a spreadsheet formula.
(define (qa-csv-text text)
  (if (regexp-match? #px"^(?:\\s*[=+@-]|[\t\r\n])" text) (string-append "'" text) text))

(module+ test
  (require rackunit)
  (test-case "Q&A CSV treats audience text as spreadsheet data"
    (for ([text '("=HYPERLINK(\"https://example.org\")" "+1" "-1" "@SUM(A1:A2)" "  =1" "\tplain")])
      (check-equal? (qa-csv-text text) (string-append "'" text)))
    (check-equal? (qa-csv-text "Why is this pure?") "Why is this pure?")
    (check-equal? (render-csv '("question") (list (list (qa-csv-text "=SUM(1,2)"))))
                  "question\r\n\"'=SUM(1,2)\"\r\n")))
