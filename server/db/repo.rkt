#lang racket/base
;; Deck, poll, session and vote persistence. Each define-query is one statement; functions take a connection first and
;; return domain structs (never hashes). Timestamps are formatted in SQL with iso(); SQL NULL becomes #f.
(require racket/contract/base racket/list racket/match racket/vector db "accounts.rkt" "query.rkt" "../live/codes.rkt" "../auth/access.rkt" "../domain.rkt")
(provide limit-refusal/c limits-of/c
         (contract-out
          [add-presentation! (-> connection? limits-of/c id/c string? id/c natural-number/c (or/c id/c limit-refusal/c))]
          [copy-presentation! (-> connection? limits-of/c id/c id/c (or/c id/c limit-refusal/c #f))]
          [get-deck (-> connection? id/c id/c (or/c deck? #f))]
          [list-shares (-> connection? id/c (listof share?))]
          [put-share! (-> connection? id/c share? share?)]
          [delete-share! (-> connection? id/c string? boolean?)]
          [set-pdf-key! (-> connection? id/c string? void?)]
          [get-presentation (-> connection? id/c (or/c presentation? #f))]
          [presentation-pdf-key (-> connection? id/c (or/c string? #f))]
          [list-presentations (-> connection? id/c boolean? (listof presentation-listing?))]
          [rename-presentation! (-> connection? id/c string? (or/c presentation? #f))]
          [set-archived! (-> connection? id/c boolean? (or/c presentation? #f))]
          [remove-owner-presentation! (-> connection? id/c id/c (-> connection? id/c void?) (or/c string? 'session-live #f))]
          [delete-presentation! (-> connection? id/c (or/c string? 'session-live #f))]
          [get-poll (-> connection? id/c (or/c poll? #f))]
          [list-polls (-> connection? id/c (listof poll?))]
          [create-poll! (-> connection? id/c poll-draft? poll?)]
          [update-poll! (-> connection? id/c poll-draft? (or/c poll? 'has-runs #f))]
          [set-show-results! (-> connection? id/c boolean? (or/c poll? #f))]
          [delete-poll! (-> connection? id/c (or/c 'ok 'has-runs #f))]
          [duplicate-poll! (-> connection? id/c (or/c poll? #f))]
          [set-poll-archived! (-> connection? id/c boolean? (or/c poll? 'has-no-runs #f))]
          [insert-session-retrying! (-> connection? id/c string? session?)]
          [insert-session! (-> connection? id/c string? string? string? session?)]
          [get-session (-> connection? string? (or/c session? #f))]
          [get-session-by-screen-code (-> connection? string? (or/c session? #f))]
          [list-sessions (-> connection? id/c (listof session?))]
          [set-slide! (-> connection? id/c id/c void?)]
          [end-session! (-> connection? id/c time/c)]
          [open-run! (->* (connection? id/c id/c) (#:only-if-idle? boolean?) (or/c poll-run? #f))]
          [close-run! (-> connection? id/c (or/c time/c #f))]
          [resume-run! (-> connection? id/c boolean?)]
          [reveal-run! (-> connection? id/c void?)]
          [run-results-shown? (-> connection? id/c boolean?)]
          [get-run (-> connection? id/c (or/c poll-run? #f))]
          [current-run (-> connection? id/c (or/c poll-run? #f))]
          [session-runs (-> connection? id/c (listof poll-run?))]
          [run-votes (-> connection? id/c (listof vote?))]
          [append-run-option! (-> connection? id/c id/c option-draft? (or/c option? 'poll-not-open 'not-allowed 'too-many 'invalid))]
          [cast-vote! (-> connection? id/c string? id/c string? (listof id/c) (or/c 'ok 'poll-not-open 'invalid))]
          [run-poll-kind (-> connection? id/c (or/c kind/c #f))]
          [participant-option-ids (-> connection? id/c string? (listof id/c))]
          [record-peaks! (-> connection? string? natural-number/c (or/c id/c #f) natural-number/c void?)]
          [results-totals-row (-> connection? id/c results-totals?)]
          [run-results (-> connection? id/c (listof run-result?))]))

;; ---------------------------------------------------------------- helpers
;; Any -> Any
;; SQL NULL as #f
(define (nul v) (if (sql-null? v) #f v))

;; Exception -> String
(define (sqlstate e) (format "~a" (exn:fail:sql-sqlstate e)))

;; (on-fk-violation handler-expr body ...): the value of handler-expr if body breaks a foreign key
(define-syntax-rule (on-fk-violation handler body ...)
  (with-handlers ([(λ (e) (and (exn:fail:sql? e) (equal? (sqlstate e) "23503"))) (λ (_) handler)])
    body ...))

;; ---------------------------------------------------------------- presentations
(define pres-cols "id, title, page_count, iso(created_at), iso(archived_at)")

;; Vector -> Presentation
(define (row->presentation r)
  (match-define (vector id title page-count created archived) r)
  (presentation id title page-count created (nul archived)))

;; A LimitsOf is a (Connection Id -> Limits): the limits that apply to a user, read inside the caller's transaction
(define limits-of/c (-> connection? id/c limits?))

;; A LimitRefusal is 'too-large (over the per-deck cap) or 'quota-exceeded (over its storage quota)
(define limit-refusal/c (or/c 'too-large 'quota-exceeded))

;; the decks a user can see: their own and the ones shared with their verified email. The first
;; column is the asking user's id, from which the access is worked out.
(define deck-cols
  "p.id, p.title, p.page_count, iso(p.created_at), iso(p.archived_at), $1::bigint, p.owner_id, o.email, o.name,
   s.email, s.can_edit, s.can_moderate, s.can_copy, s.can_results")
;; Natural: the number of columns in deck-cols
(define deck-col-count 14)
(define deck-from
  " FROM presentations p JOIN users o ON o.id = p.owner_id
    LEFT JOIN deck_shares s ON s.presentation_id = p.id
         AND s.email = (SELECT lower(email) FROM users WHERE id=$1 AND email_verified)
    WHERE (p.owner_id = $1 OR s.presentation_id IS NOT NULL)")

;; Vector -> Deck
;; the first deck-col-count columns of a row: exactly deck-cols
(define (row->deck r)
  (match-define (vector id title page-count created archived uid owner-id owner-email owner-name
                        share-email edit? moderate? copy? results?) r)
  (define share* (and (not (sql-null? share-email)) (share share-email edit? moderate? copy? results?)))
  (deck (presentation id title page-count created (nul archived))
        (owner (nul* owner-email) owner-name)
        (access-for uid owner-id share*)))

;; Any -> String
;; SQL NULL as the empty string
(define (nul* v) (if (sql-null? v) "" v))

;; Vector -> PresentationListing
(define (row->listing r)
  (presentation-listing (row->deck (vector-take r deck-col-count)) (vector-ref r deck-col-count)))

(define-query (get-deck c uid id) #:maybe-row row->deck
  "SELECT " deck-cols deck-from " AND p.id=$2")

;; the storage key is known only once the row has an id: a new row holds 'pending' until set-pdf-key!.
;; The size is known up front: it is reserved against the owner's quota (see add-presentation!)
(define-query (insert-sized-presentation c owner-id title page-count bytes) #:value
  "INSERT INTO presentations (owner_id, title, pdf_key, page_count, pdf_bytes) VALUES ($1, $2, 'pending', $3, $4) RETURNING id")

(define-query (lock-user! c uid) #:exec "SELECT 1 FROM users WHERE id=$1 FOR UPDATE")

;; Connection Id Natural -> (or 'ok LimitRefusal)
;; inside a transaction: whether `bytes` more fit the user's limits. The user's row stays locked until the
;; transaction ends, so concurrent uploads of one user queue up and cannot overshoot the quota together.
(define (limits-verdict c limits-of uid bytes)
  (lock-user! c uid)
  (match-define (limits max-upload quota _) (limits-of c uid))
  (cond [(> bytes max-upload) 'too-large]
        [(and quota (> (+ (storage-used c uid) bytes) quota)) 'quota-exceeded]
        [else 'ok]))

;; Connection LimitsOf Id String Id Natural -> (or Id LimitRefusal)
;; inserts a presentation of `bytes` bytes owned by the user unless it breaks their limits.
;; Its key is still 'pending': set-pdf-key! follows once the file is stored.
(define (add-presentation! c limits-of uid title page-count bytes)
  (call-with-transaction c
    (λ ()
      (match (limits-verdict c limits-of uid bytes)
        ['ok (insert-sized-presentation c uid title page-count bytes)]
        [refusal refusal]))))

(define-query (presentation-pdf-bytes c id) #:value "SELECT pdf_bytes FROM presentations WHERE id=$1")

;; Connection Id Id -> Void
;; copies the deck's Q&A configuration without any session-owned questions
(define-query (copy-qa-setting! c id src-id) #:exec
  "UPDATE presentations SET qa_enabled=(SELECT qa_enabled FROM presentations WHERE id=$2) WHERE id=$1")

;; Connection LimitsOf Id Id -> (or Id LimitRefusal #f)
;; a new presentation owned by the user: the source's title and page count plus its non-archived polls
;; (no sessions, no votes). Counts against the user's limits like an upload; #f for an unknown source.
;; The PDF is copied by the caller afterwards.
(define (copy-presentation! c limits-of uid src-id)
  (call-with-transaction c
    (λ ()
      (match (get-presentation c src-id)
        [#f #f]
        [src
         (define pdf-bytes (presentation-pdf-bytes c src-id))
         (match (limits-verdict c limits-of uid pdf-bytes)
           ['ok
            (define id (insert-sized-presentation c uid (presentation-title src) (presentation-page-count src) pdf-bytes))
            (copy-qa-setting! c id src-id)
            (for ([p (list-polls c src-id)] #:unless (poll-archived-at p))
              (create-poll! c id (poll->draft p)))
            id]
           [refusal refusal])]))))

;; Connection Id String -> Void
;; records where the stored PDF lives; its size was reserved at insert
(define-query (set-pdf-key! c id key) #:exec "UPDATE presentations SET pdf_key=$2 WHERE id=$1")

(define-query (get-presentation c id) #:maybe-row row->presentation
  "SELECT " pres-cols " FROM presentations WHERE id=$1")

(define-query (presentation-pdf-key c id) #:maybe-value "SELECT pdf_key FROM presentations WHERE id=$1")

(define-query (list-presentations c uid archived?) #:rows row->listing
  "SELECT " deck-cols ", (SELECT count(*) FROM lecture_sessions l WHERE l.presentation_id=p.id AND l.ended_at IS NULL)"
  deck-from " AND (p.archived_at IS NOT NULL) = $2 ORDER BY p.id DESC")

(define-query (rename-presentation! c id title) #:maybe-row row->presentation
  "UPDATE presentations SET title=$2 WHERE id=$1 RETURNING " pres-cols)

(define-query (set-archived! c id archived?) #:maybe-row row->presentation
  "UPDATE presentations SET archived_at = CASE WHEN $2 THEN coalesce(archived_at, now()) END WHERE id=$1 RETURNING "
  pres-cols)

;; the row lock queues out a session being created meanwhile (its insert needs a share lock on the row)
(define-query (lock-presentation c id) #:maybe-value "SELECT id FROM presentations WHERE id=$1 FOR UPDATE")

(define-query (live-session? c id) #:value
  "SELECT EXISTS (SELECT 1 FROM lecture_sessions WHERE presentation_id=$1 AND ended_at IS NULL)")

;; the sessions go first, taking their runs and votes along: polls with runs are RESTRICTed on purpose
;; (see delete-poll!), so the cascade from the presentation must not reach them while runs remain
(define-query (delete-sessions! c id) #:exec "DELETE FROM lecture_sessions WHERE presentation_id=$1")

(define-query (delete-presentation-row c id) #:maybe-value "DELETE FROM presentations WHERE id=$1 RETURNING pdf_key")

;; Connection Id -> (or String 'session-live #f)
;; deletes the presentation with its sessions, runs, votes, polls and shares; the pdf storage key to
;; delete, 'session-live while any session has not ended, #f when unknown
(define (delete-presentation! c id)
  (call-with-transaction c
    (λ ()
      (cond [(not (lock-presentation c id)) #f]
            [(live-session? c id) 'session-live]
            [else (delete-sessions! c id) (delete-presentation-row c id)]))))

;; Connection Id Id (Connection Id -> Void) -> (or String 'session-live #f)
;; serializes an authorized removal and its capacity update with uploads by the same owner
(define (remove-owner-presentation! c owner id removed!)
  (call-with-transaction c
    (λ ()
      (lock-user! c owner)
      (define key (delete-presentation! c id))
      (when (string? key) (removed! c owner))
      key)))

;; ---------------------------------------------------------------- polls
(define poll-select
  "SELECT id, presentation_id, slide, position, question, kind,
          EXISTS (SELECT 1 FROM poll_runs r WHERE r.poll_id = p.id), show_results, iso(archived_at), allow_additional_answers FROM polls p")

;; Vector -> Poll
;; options are attached separately (see with-options)
(define (row->poll r)
  (match-define (vector id pid slide position question kind has-runs? show-results? archived allow-additional?) r)
  (poll id pid (nul slide) position question kind '() has-runs? show-results? (nul archived) allow-additional?))

;; Vector -> Option
(define (row->option r) (match-define (vector id idx label exclusive?) r) (option id idx label exclusive?))

;; Vector -> (Pair Id Option)
;; an option tagged with its poll's id
(define (row->owned-option r) (cons (vector-ref r 0) (row->option (vector-drop r 1))))

(define-query (poll-options c poll-id) #:rows row->option
  "SELECT id, idx, label, exclusive FROM poll_options WHERE poll_id=$1 ORDER BY idx")

(define-query (presentation-options c pid) #:rows row->owned-option
  "SELECT poll_id, id, idx, label, exclusive FROM poll_options
   WHERE poll_id IN (SELECT id FROM polls WHERE presentation_id=$1) ORDER BY poll_id, idx")

(define-query (poll-row c id) #:maybe-row row->poll poll-select " WHERE id=$1")

(define-query (poll-rows c pid) #:rows row->poll
  poll-select " WHERE presentation_id=$1 ORDER BY slide NULLS LAST, position, id")

;; Poll [Listof Option] -> Poll
(define (with-options p options) (struct-copy poll p [options options]))

;; Connection Id -> (or Poll #f)
(define (get-poll c id)
  (define p (poll-row c id))
  (and p (with-options p (poll-options c id))))

;; Connection Id -> [Listof Poll]
;; a presentation's polls in slide order, polls without a slide last
(define (list-polls c pid)
  (define options-by-poll
    (for/hash ([g (group-by car (presentation-options c pid))])
      (values (car (car g)) (map cdr g))))
  (for/list ([p (poll-rows c pid)])
    (with-options p (hash-ref options-by-poll (poll-id p) '()))))

(define-query (next-position c pid [slide #:nullable]) #:value
  "SELECT coalesce(max(position), 0) + 1 FROM polls WHERE presentation_id=$1 AND slide IS NOT DISTINCT FROM $2::int")

(define-query (insert-poll-row c pid [slide #:nullable] position question kind show-results? allow-additional?) #:value
  "INSERT INTO polls (presentation_id, slide, position, question, kind, show_results, allow_additional_answers) VALUES ($1, $2::int, $3, $4, $5, $6, $7) RETURNING id")

(define-query (insert-option! c poll-id idx label exclusive?) #:exec
  "INSERT INTO poll_options (poll_id, idx, label, exclusive) VALUES ($1, $2, $3, $4)")

(define-query (delete-options! c poll-id) #:exec "DELETE FROM poll_options WHERE poll_id=$1")

;; Connection Id [Listof OptionDraft] -> Void
;; stores the answer definitions in display order
(define (insert-options! c poll-id labels)
  (for ([draft labels] [i (in-naturals)])
    (insert-option! c poll-id i (option-draft-label draft) (option-draft-exclusive? draft))))

;; Connection Id PollDraft -> Poll
;; stores the poll at the end of its slide's positions
(define (create-poll! c pid draft)
  (match-define (poll-draft slide question kind labels show-results? allow-additional?) draft)
  (define id
    (call-with-transaction c
      (λ ()
        (define id (insert-poll-row c pid slide (next-position c pid slide) question kind show-results? allow-additional?))
        (insert-options! c id labels)
        id)))
  (get-poll c id))

(define-query (lock-poll c id) #:maybe-row (λ (r) (cons (vector-ref r 0) (nul (vector-ref r 1))))
  "SELECT presentation_id, slide FROM polls WHERE id=$1 FOR UPDATE")

(define-query (poll-ever-run? c id) #:value "SELECT EXISTS (SELECT 1 FROM poll_runs WHERE poll_id=$1)")

(define-query (poll-position c id) #:value "SELECT position FROM polls WHERE id=$1")

(define-query (update-poll-row! c id [slide #:nullable] position question kind show-results? allow-additional?) #:exec
  "UPDATE polls SET slide=$2::int, position=$3, question=$4, kind=$5, show_results=$6, allow_additional_answers=$7 WHERE id=$1")

(define-query (update-show-results! c id show-results?) #:maybe-value
  "UPDATE polls SET show_results=$2 WHERE id=$1 RETURNING id")

;; Connection Id Boolean -> (or Poll #f)
;; the display setting, which stays editable after the poll has runs
(define (set-show-results! c id show-results?)
  (and (update-show-results! c id show-results?) (get-poll c id)))

;; Connection Id PollDraft -> (or Poll 'has-runs #f)
;; replaces the poll's content; it keeps its position unless it moves to another slide
(define (update-poll! c id draft)
  (match-define (poll-draft slide question kind labels show-results? allow-additional?) draft)
  (define result
    (call-with-transaction c
      (λ ()
        (match (lock-poll c id)
          [#f #f]
          [_ #:when (poll-ever-run? c id) 'has-runs]
          [(cons pid old-slide)
           (define pos (if (equal? old-slide slide) (poll-position c id) (next-position c pid slide)))
           (update-poll-row! c id slide pos question kind show-results? allow-additional?)
           (delete-options! c id)
           (insert-options! c id labels)
           'ok]))))
  (if (eq? result 'ok) (get-poll c id) result))

(define-query (delete-poll-row c id) #:maybe-value "DELETE FROM polls WHERE id=$1 RETURNING id")

;; Connection Id -> (or 'ok 'has-runs #f)
(define (delete-poll! c id)
  (on-fk-violation 'has-runs (if (delete-poll-row c id) 'ok #f)))

;; Poll -> PollDraft
(define (poll->draft p)
  (match-define (poll _ _ slide _ question kind options _ show-results? _ allow-additional?) p)
  (poll-draft slide question kind
              (for/list ([o options]) (option-draft (option-label o) (option-exclusive? o)))
              show-results? allow-additional?))

;; Connection Id -> (or Poll #f)
;; a copy of the poll, placed last on its slide
(define (duplicate-poll! c id)
  (match (get-poll c id)
    [#f #f]
    [p (create-poll! c (poll-presentation-id p) (poll->draft p))]))

(define-query (update-poll-archived! c id archived?) #:exec
  "UPDATE polls SET archived_at = CASE WHEN $2 THEN coalesce(archived_at, now()) END WHERE id=$1")

;; Connection Id Boolean -> (or Poll 'has-no-runs #f)
;; archives (#t) or unarchives the poll; only a poll with runs can be archived. Archiving twice
;; keeps the first timestamp
(define (set-poll-archived! c id archived?)
  (match (get-poll c id)
    [#f #f]
    [(? (λ (p) (and archived? (not (poll-has-runs? p))))) 'has-no-runs]
    [_ (update-poll-archived! c id archived?) (get-poll c id)]))

;; ---------------------------------------------------------------- shares
;; Vector -> Share
(define (row->share r)
  (match-define (vector email edit? moderate? copy? results?) r)
  (share email edit? moderate? copy? results?))

(define-query (list-shares c pid) #:rows row->share
  "SELECT email, can_edit, can_moderate, can_copy, can_results FROM deck_shares WHERE presentation_id=$1 ORDER BY email")

(define-query (upsert-share! c pid email edit? moderate? copy? results?) #:row row->share
  "INSERT INTO deck_shares (presentation_id, email, can_edit, can_moderate, can_copy, can_results)
   VALUES ($1, lower($2), $3, $4, $5, $6)
   ON CONFLICT (presentation_id, email)
   DO UPDATE SET can_edit=$3, can_moderate=$4, can_copy=$5, can_results=$6
   RETURNING email, can_edit, can_moderate, can_copy, can_results")

;; Connection Id Share -> Share
;; grants (or replaces the grant of) the share's email on the presentation; the share as stored, with
;; its email lowercased by the database
(define (put-share! c pid sh)
  (match-define (share email edit? moderate? copy? results?) sh)
  (upsert-share! c pid email edit? moderate? copy? results?))

(define-query (delete-share-rows! c pid email) #:count
  "DELETE FROM deck_shares WHERE presentation_id=$1 AND email=lower($2)")

;; Connection Id String -> Boolean
;; revokes the email's share; #f when there was none
(define (delete-share! c pid email) (positive? (delete-share-rows! c pid email)))

;; ---------------------------------------------------------------- sessions
(define session-cols "id, presentation_id, code, screen_code, label, current_slide, iso(started_at), iso(ended_at)")

;; Vector -> Session
(define (row->session r)
  (match-define (vector id pid code screen-code label slide started ended) r)
  (session id pid code screen-code label slide started (nul ended)))

(define-query (insert-session! c pid label code screen-code) #:row row->session
  "INSERT INTO lecture_sessions (presentation_id, label, code, screen_code, qa_enabled) SELECT id, $2, $3, $4, qa_enabled FROM presentations WHERE id=$1 RETURNING " session-cols)

;; Connection Id String -> Session
;; inserts a session under a fresh random code, retrying on a code collision
(define (insert-session-retrying! c pid label)
  (let loop ([attempts 5])
    (with-handlers ([(λ (e) (and (exn:fail:sql? e) (> attempts 1) (equal? (sqlstate e) "23505")))
                     (λ (_) (loop (sub1 attempts)))])
      (insert-session! c pid label (random-code) (random-code)))))

(define-query (get-session c code) #:maybe-row row->session
  "SELECT " session-cols " FROM lecture_sessions WHERE code=$1")

(define-query (get-session-by-screen-code c screen-code) #:maybe-row row->session
  "SELECT " session-cols " FROM lecture_sessions WHERE screen_code=$1")

(define-query (list-sessions c pid) #:rows row->session
  "SELECT " session-cols " FROM lecture_sessions WHERE presentation_id=$1 ORDER BY id DESC")

(define-query (set-slide! c session-id slide) #:exec "UPDATE lecture_sessions SET current_slide=$2 WHERE id=$1")

(define-query (close-open-runs! c session-id) #:exec
  "UPDATE poll_runs SET closed_at = clock_timestamp() WHERE session_id=$1 AND closed_at IS NULL")

(define-query (mark-ended! c session-id) #:value
  "UPDATE lecture_sessions SET qa_open=false, ended_at = clock_timestamp() WHERE id=$1 RETURNING iso(ended_at)")

;; Connection Id -> Time
;; ends the session and closes its open run; the end time
(define (end-session! c session-id)
  (call-with-transaction c (λ () (lock-session-for-run c session-id) (close-open-runs! c session-id) (mark-ended! c session-id))))

;; ---------------------------------------------------------------- runs
(define run-select
  "SELECT r.id, r.poll_id, pl.question, pl.kind, iso(r.opened_at), iso(r.closed_at), r.allow_additional_answers
   FROM poll_runs r JOIN polls pl ON pl.id = r.poll_id")

;; Vector -> PollRun
;; options and votes are attached separately (see complete-run)
(define (row->run r)
  (match-define (vector id poll-id question kind opened closed allow-additional?) r)
  (poll-run id poll-id question kind opened (nul closed) '() empty-ballots allow-additional?))

(define-query (insert-run! c session-id poll-id) #:maybe-value
  "INSERT INTO poll_runs (session_id, poll_id, opened_at, allow_additional_answers)
   SELECT $1, id, clock_timestamp(), allow_additional_answers FROM polls WHERE id=$2
   ON CONFLICT (session_id) WHERE closed_at IS NULL DO NOTHING RETURNING id")

(define-query (run-row c run-id) #:maybe-row row->run run-select " WHERE r.id=$1")

(define-query (latest-run-row c session-id) #:maybe-row row->run
  run-select " WHERE r.session_id=$1 ORDER BY r.opened_at DESC, r.id DESC LIMIT 1")

(define-query (session-run-rows c session-id) #:rows row->run
  run-select " WHERE r.session_id=$1 ORDER BY r.opened_at DESC, r.id DESC")

(define-query (close-run! c run-id) #:maybe-value
  "UPDATE poll_runs SET closed_at = clock_timestamp() WHERE id=$1 AND closed_at IS NULL RETURNING iso(closed_at)")

;; reopens the run, votes kept, iff it is closed and the newest of its session; #f otherwise.
;; One statement, so it cannot interleave with open-run!; poll_runs_one_open backs it up.
(define-query (resume-run! c run-id) #:maybe-value
  "UPDATE poll_runs SET closed_at = NULL
   WHERE id=$1 AND closed_at IS NOT NULL
     AND id = (SELECT l.id FROM poll_runs l WHERE l.session_id = poll_runs.session_id
               ORDER BY l.opened_at DESC, l.id DESC LIMIT 1)
   RETURNING true")

(define-query (reveal-run! c run-id) #:exec
  "UPDATE poll_runs SET revealed_at = coalesce(revealed_at, now()) WHERE id=$1")

(define-query (run-results-shown? c run-id) #:value
  "SELECT revealed_at IS NOT NULL FROM poll_runs WHERE id=$1")

(define-query (vote-option-rows c run-id) #:rows (λ (r) (cons (vector-ref r 0) (vector-ref r 1)))
  "SELECT participant_id::text, option_id FROM vote_options WHERE poll_run_id=$1 ORDER BY option_id")

;; Connection Id -> [Listof Vote]
(define (run-votes c run-id)
  (for/list ([g (group-by car (vote-option-rows c run-id))])
    (vote (car (car g)) (map cdr g))))

;; Connection Id -> [Listof Option]
;; the run's own immutable-order answer snapshots
(define-query (run-options c run-id) #:rows row->option
  "SELECT id, idx, label, exclusive FROM run_options WHERE poll_run_id=$1 ORDER BY idx")

;; Connection Id Id -> Void
;; copies the definition answers once when a run opens
(define-query (snapshot-options! c run-id poll-id) #:exec
  "INSERT INTO run_options (poll_run_id, idx, label, exclusive)
   SELECT $1, idx, label, exclusive FROM poll_options WHERE poll_id=$2 ORDER BY idx")

;; Connection Id -> Id
;; holds the active session while starting or ending its runs
(define-query (lock-session-for-run c session-id) #:value
  "SELECT id FROM lecture_sessions WHERE id=$1 AND ended_at IS NULL FOR UPDATE")

;; Connection (or PollRun #f) -> (or PollRun #f)
;; adds the run's snapshot options and the votes cast so far
(define (complete-run c r)
  (and r (struct-copy poll-run r [options (run-options c (poll-run-id r))] [votes (votes->ballots (run-votes c (poll-run-id r)))])))

;; Connection Id -> (or PollRun #f)
(define (get-run c run-id) (complete-run c (run-row c run-id)))

;; Connection Id -> (or PollRun #f)
;; the run most recently opened in the session
(define (current-run c session-id) (complete-run c (latest-run-row c session-id)))

;; Connection Id -> [Listof PollRun]
;; every run of the session with its votes, newest first
(define (session-runs c session-id)
  (for/list ([r (session-run-rows c session-id)]) (complete-run c r)))

;; Connection Id Id [#:only-if-idle? Boolean] -> (or PollRun #f)
;; opens a run, optionally refusing to replace an open vote
(define (open-run! c session-id poll-id #:only-if-idle? [only-if-idle? #f])
  (define id
    (call-with-transaction c
      (λ ()
        (lock-session-for-run c session-id)
        (lock-poll c poll-id)
        (unless only-if-idle? (close-open-runs! c session-id))
        (define id (insert-run! c session-id poll-id))
        (when id (snapshot-options! c id poll-id))
        id)))
  (and id (get-run c id)))

;; ---------------------------------------------------------------- votes
(struct reject exn:fail (reason))
;; Symbol -> Nothing
(define (reject! reason) (raise (reject "vote rejected" (current-continuation-marks) reason)))

(define-query (lock-open-run c run-id code pid) #:maybe-value
  "SELECT p.kind FROM poll_runs r JOIN polls p ON p.id=r.poll_id JOIN lecture_sessions s ON s.id = r.session_id
   WHERE r.id=$1 AND s.code=$2 AND s.presentation_id=$3 AND r.closed_at IS NULL AND s.ended_at IS NULL FOR SHARE OF r")

;; Connection String Id -> (or Id #f)
;; holds the active session before taking its run lock
(define-query (lock-vote-session c code pid) #:maybe-value
  "SELECT id FROM lecture_sessions WHERE code=$1 AND presentation_id=$2 AND ended_at IS NULL FOR SHARE")

(define-query (participant-option-ids c run-id participant) #:list
  "SELECT option_id FROM vote_options WHERE poll_run_id=$1 AND participant_id=$2::uuid ORDER BY option_id")

;; a revote counts as a change only when its option set differs (changed?); first_voted_at never moves
(define-query (upsert-vote! c run-id participant changed?) #:exec
  "INSERT INTO votes (poll_run_id, participant_id) VALUES ($1, $2::uuid)
   ON CONFLICT (poll_run_id, participant_id)
   DO UPDATE SET voted_at = now(), changes = votes.changes + CASE WHEN $3 THEN 1 ELSE 0 END")

(define-query (clear-vote-options! c run-id participant) #:exec
  "DELETE FROM vote_options WHERE poll_run_id=$1 AND participant_id=$2::uuid")

(define-query (insert-vote-option! c run-id participant option-id) #:count
  "INSERT INTO vote_options SELECT $1::bigint, $2::uuid, o.id FROM run_options o WHERE o.id=$3 AND o.poll_run_id=$1")

;; Connection Id String Id String [Listof Id] -> (or 'ok 'poll-not-open 'invalid)
;; replaces the participant's vote in one transaction; rolled back when any option is foreign to the poll
(define (cast-vote! c run-id code pid participant option-ids)
  (with-handlers ([reject? reject-reason])
    (call-with-transaction c
      (λ ()
        (unless (lock-vote-session c code pid) (reject! 'poll-not-open))
        (define kind (or (lock-open-run c run-id code pid) (reject! 'poll-not-open)))
        (define opts (run-options c run-id))
        (when (ballot-refusal kind opts option-ids) (reject! 'invalid))
        (define previous (participant-option-ids c run-id participant))
        (upsert-vote! c run-id participant (and (pair? previous) (not (equal? previous (sort option-ids <)))))
        (clear-vote-options! c run-id participant)
        (for ([o option-ids])
          (unless (= 1 (insert-vote-option! c run-id participant o)) (reject! 'invalid)))
        'ok))))

(define-query (run-poll-kind c run-id) #:maybe-value
  "SELECT pl.kind FROM poll_runs r JOIN polls pl ON pl.id=r.poll_id WHERE r.id=$1")

;; Connection Id -> (or Id #f)
;; holds the session against ending before taking the run lock
(define-query (lock-session-for-addition c session-id) #:maybe-value
  "SELECT id FROM lecture_sessions WHERE id=$1 AND ended_at IS NULL FOR SHARE")

;; Connection Id Id -> (or Vector #f)
;; locks the open run so an option cannot arrive after closure
(define-query (lock-run-for-addition c session-id run-id) #:maybe-row values
  "SELECT r.allow_additional_answers, pl.kind FROM poll_runs r
   JOIN polls pl ON pl.id=r.poll_id JOIN lecture_sessions s ON s.id=r.session_id
   WHERE r.id=$2 AND r.session_id=$1 AND r.closed_at IS NULL AND s.ended_at IS NULL FOR UPDATE OF r")

;; Connection Id Natural String Boolean -> Option
;; stores an additional answer belonging only to this run
(define-query (insert-run-option! c run-id idx label exclusive?) #:row row->option
  "INSERT INTO run_options (poll_run_id, idx, label, exclusive) VALUES ($1, $2, $3, $4)
   RETURNING id, idx, label, exclusive")

;; Connection Id Id OptionDraft -> (or Option Symbol)
;; appends one option to the open run; row locks serialize additions with voting and closure
(define (append-run-option! c session-id run-id draft)
  (call-with-transaction c
    (λ ()
      (lock-session-for-addition c session-id)
      (match (lock-run-for-addition c session-id run-id)
        [#f 'poll-not-open]
        [(vector #f _) 'not-allowed]
        [(vector _ kind)
         (define options (run-options c run-id))
         (cond [(>= (length options) 30) 'too-many]
               [(or (not (<= 1 (string-length (option-draft-label draft)) 200))
                    (and (equal? kind "single") (option-draft-exclusive? draft))) 'invalid]
               [else (insert-run-option! c run-id (length options)
                                        (option-draft-label draft) (option-draft-exclusive? draft))])]))))

;; ---------------------------------------------------------------- engagement
(define-query (update-session-peak! c code peak) #:exec
  "UPDATE lecture_sessions SET peak_audience = GREATEST(coalesce(peak_audience, 0), $2) WHERE code=$1")

(define-query (update-run-peak! c run-id peak) #:exec
  "UPDATE poll_runs SET peak_audience = GREATEST(coalesce(peak_audience, 0), $2) WHERE id=$1")

;; Connection String Natural (or Id #f) Natural -> Void
;; raises the stored peak audience of the session (by code) and of the run, if any; never lowers it
(define (record-peaks! c code session-peak run-id run-peak)
  (call-with-transaction c
    (λ ()
      (update-session-peak! c code session-peak)
      (when run-id (update-run-peak! c run-id run-peak)))))

;; Vector -> ResultsTotals
(define (row->totals r)
  (match-define (vector unique peak median changed-votes changed-voters) r)
  (results-totals unique (nul peak) (nul median) (nul changed-votes) (nul changed-voters)))

;; Counts and medians are NULL-safe: votes from before engagement tracking have no first_voted_at or
;; changes, and a session or run without votes has no median.
(define-query (results-totals-row c session-id) #:row row->totals
  "SELECT count(DISTINCT v.participant_id), s.peak_audience,
          round(percentile_cont(0.5) WITHIN GROUP
                (ORDER BY extract(epoch FROM v.first_voted_at - r.opened_at)::float8)::numeric, 1)::float8,
          CASE WHEN count(v.changes) > 0 THEN coalesce(sum(v.changes), 0)::bigint END,
          CASE WHEN count(v.changes) > 0 THEN count(*) FILTER (WHERE v.changes > 0) END
   FROM lecture_sessions s
   LEFT JOIN poll_runs r ON r.session_id = s.id
   LEFT JOIN votes v ON v.poll_run_id = r.id
   WHERE s.id=$1
   GROUP BY s.id")

;; Vector -> (Pair Id RunResult)
;; a run's statistics, options attached separately; keyed by run id
(define (row->run-result r)
  (match-define (vector id poll-id slide question kind opened closed peak voters median changed) r)
  (cons id (run-result id poll-id (nul slide) question kind opened (nul closed) voters (nul peak) (nul median) (nul changed) '())))

(define-query (run-result-rows c session-id) #:rows row->run-result
  "SELECT r.id, r.poll_id, pl.slide, pl.question, pl.kind, iso(r.opened_at), iso(r.closed_at), r.peak_audience,
          (SELECT count(*) FROM votes v WHERE v.poll_run_id = r.id),
          (SELECT round(percentile_cont(0.5) WITHIN GROUP
                        (ORDER BY extract(epoch FROM v.first_voted_at - r.opened_at)::float8)::numeric, 1)::float8
           FROM votes v WHERE v.poll_run_id = r.id),
          (SELECT CASE WHEN count(v.changes) > 0 THEN count(*) FILTER (WHERE v.changes > 0) END
           FROM votes v WHERE v.poll_run_id = r.id)
   FROM poll_runs r JOIN polls pl ON pl.id = r.poll_id
   WHERE r.session_id=$1 ORDER BY r.opened_at, r.id")

;; Vector -> (Pair Id OptionCount)
;; an option's count in a run, keyed by run id
(define (row->option-count r)
  (match-define (vector run-id id idx label count) r)
  (cons run-id (option-count id idx label count)))

;; the LEFT JOIN keeps options nobody chose, with count 0
(define-query (option-count-rows c session-id) #:rows row->option-count
  "SELECT r.id, o.id, o.idx, o.label, count(vo.option_id)
   FROM poll_runs r
   JOIN run_options o ON o.poll_run_id = r.id
   LEFT JOIN vote_options vo ON vo.poll_run_id = r.id AND vo.option_id = o.id
   WHERE r.session_id=$1
   GROUP BY r.id, r.opened_at, o.id, o.idx, o.label
   ORDER BY r.opened_at, r.id, o.idx")

;; Connection Id -> [Listof RunResult]
;; the session's runs, oldest first, each with all its options counted
(define (run-results c session-id)
  (define options-by-run
    (for/hash ([g (group-by car (option-count-rows c session-id))])
      (values (car (car g)) (map cdr g))))
  (for/list ([p (run-result-rows c session-id)])
    (struct-copy run-result (cdr p) [options (hash-ref options-by-run (car p) '())])))
