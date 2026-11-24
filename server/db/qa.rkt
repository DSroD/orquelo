#lang racket/base
;; Q&A persistence. Locking the session serializes submissions, moderation and session closure.
(require racket/contract/base racket/match db db/util/postgresql "query.rkt" "../domain.rkt" "../qa.rkt")
(provide (contract-out
          [deck-qa-enabled? (-> connection? id/c boolean?)]
          [decks-qa-enabled (-> connection? (listof id/c) (hash/c id/c boolean?))]
          [set-deck-qa! (-> connection? id/c boolean? void?)]
          [get-qa (-> connection? id/c (or/c qa-state? #f))]
          [set-qa-open! (-> connection? id/c boolean? (or/c qa-state? 'not-found 'ended 'disabled))]
          [submit-question! (-> connection? id/c string? question-text?
                                (or/c qa-question? 'not-found 'ended 'disabled 'closed 'too-fast 'limit))]
          [set-question-status! (-> connection? id/c id/c qa-status/c (or/c qa-state? 'not-found 'ended))]
          [show-qa! (-> connection? id/c (or/c id/c #f) (or/c qa-state? 'not-found 'ended 'disabled 'not-pending))]
          [hide-qa! (-> connection? id/c void?)]))

;; An Availability is an (availability Boolean Boolean Boolean (or Id #f) Boolean Boolean).
;; interp. Q&A controls of one session, and whether that session has ended.
(struct availability (enabled? open? on-screen? selected-id started? ended?) #:transparent)

;; A StateRow is a (state-row Availability (or QaQuestion #f)).
;; interp. one joined SQL row; an empty inbox has one row with no question.
(struct state-row (availability question) #:transparent)

;; Any -> Any
;; SQL NULL as #f.
(define (nullable v) (if (sql-null? v) #f v))

;; Vector -> Availability
;; converts the session control columns at the SQL boundary.
(define (row->availability row)
  (match-define (vector enabled? open? on-screen? selected-id started? ended?) row)
  (availability enabled? open? on-screen? (nullable selected-id) started? ended?))

;; Vector -> QaQuestion
;; converts a stored question, retaining its participant only for private filtering.
(define (row->question row)
  (match-define (vector id body status created updated participant) row)
  (qa-question id body status created updated participant))

;; String: columns decoded by row->question.
(define question-cols "id, body, status, iso(created_at), iso(updated_at), participant_id::text")
;; String: columns decoded by row->availability.
(define availability-cols "qa_enabled, qa_open, qa_on_screen, qa_selected, qa_started, ended_at IS NOT NULL")

;; Connection Id -> Boolean
;; whether the deck permits Q&A in its next session.
(define-query (deck-qa-enabled? c pid) #:value
  "SELECT qa_enabled FROM presentations WHERE id=$1")

;; Connection (Listof Id) -> (Hashof Id Boolean)
;; the Q&A setting of each given deck in one query; ids that match no deck are absent.
(define (decks-qa-enabled c pids)
  (for/hash ([row (in-list (qa-enabled-rows c (list->pg-array pids)))])
    (values (vector-ref row 0) (vector-ref row 1))))

(define-query (qa-enabled-rows c pids) #:rows values
  "SELECT id, qa_enabled FROM presentations WHERE id = ANY($1::bigint[])")

;; Connection Id Boolean -> Void
;; changes only the setting copied by future sessions.
(define-query (set-deck-qa! c pid enabled?) #:exec
  "UPDATE presentations SET qa_enabled=$2 WHERE id=$1")

;; Connection Id -> (or Availability #f)
;; locks the session before any Q&A mutation.
(define-query (lock-availability c sid) #:maybe-row row->availability
  "SELECT " availability-cols " FROM lecture_sessions WHERE id=$1 FOR UPDATE")

;; Vector -> StateRow
;; decodes controls and an optional question from the same database snapshot.
(define (row->state-row row)
  (match-define (vector enabled? open? on-screen? selected-id started? ended?
                        id body status created updated participant) row)
  (state-row (availability enabled? open? on-screen? (nullable selected-id) started? ended?)
             (and (not (sql-null? id)) (qa-question id body status created updated participant))))

;; Connection Id -> [Listof StateRow]
;; reads controls and the inbox atomically; left join preserves an empty inbox.
(define-query (state-rows c sid) #:rows row->state-row
  "SELECT s.qa_enabled, s.qa_open, s.qa_on_screen, s.qa_selected, s.qa_started, s.ended_at IS NOT NULL,
          q.id, q.body, q.status, iso(q.created_at), iso(q.updated_at), q.participant_id::text
   FROM lecture_sessions s LEFT JOIN qa_questions q ON q.session_id=s.id
   WHERE s.id=$1 ORDER BY q.id")

;; Availability [Listof QaQuestion] -> QaState
;; combines session controls and its questions.
(define (availability->state a questions)
  (qa-state (availability-enabled? a) (availability-open? a) (availability-on-screen? a)
            (availability-selected-id a) questions (availability-started? a)))

;; Connection Id -> (or QaState #f)
;; the persisted Q&A state, including every private submission.
(define (get-qa c sid)
  (match (state-rows c sid)
    ['() #f]
    [(cons first rest)
     (availability->state (state-row-availability first)
                          (for/list ([row (in-list (cons first rest))]
                                     #:when (state-row-question row))
                            (state-row-question row)))]))

;; Connection Id Boolean -> Void
;; changes whether the session accepts submissions.
(define-query (write-open! c sid open?) #:exec
  "UPDATE lecture_sessions SET qa_open=$2, qa_started=qa_started OR $2 WHERE id=$1")

;; Connection Id Boolean -> (or QaState 'not-found 'ended 'disabled)
;; opens or closes submissions without changing polling or the projector.
(define (set-qa-open! c sid open?)
  (call-with-transaction c
    (λ ()
      (match (lock-availability c sid)
        [#f 'not-found]
        [(availability _ _ _ _ _ #t) 'ended]
        [(availability #f _ _ _ _ _) 'disabled]
        [_ (write-open! c sid open?) (get-qa c sid)]))))

;; Connection Id String -> (or 'too-fast 'limit #f)
;; submission limits for a browser participant; the caller holds the session lock.
(define (submission-limit c sid participant)
  (match-define (vector count too-fast?)
    (query-row c
               "SELECT count(*), coalesce(max(created_at) > clock_timestamp() - interval '10 seconds', false)
                FROM qa_questions WHERE session_id=$1 AND participant_id=$2::uuid"
               sid participant))
  (cond [(>= count 20) 'limit] [too-fast? 'too-fast] [else #f]))

;; Connection Id String String -> QaQuestion
;; inserts a validated submission and returns its stored representation.
(define-query (insert-question! c sid participant body) #:row row->question
  "INSERT INTO qa_questions (session_id, participant_id, body) VALUES ($1, $2::uuid, $3) RETURNING " question-cols)

;; Connection Id String QuestionText -> (or QaQuestion Symbol)
;; records trusted question text only while the session accepts submissions
(define (submit-question! c sid participant text)
  (call-with-transaction c
    (λ ()
      (match (lock-availability c sid)
        [#f 'not-found]
        [(availability _ _ _ _ _ #t) 'ended]
        [(availability #f _ _ _ _ _) 'disabled]
        [(availability _ #f _ _ _ _) 'closed]
        [_ (or (submission-limit c sid participant)
               (insert-question! c sid participant (question-text-value text)))]))))

;; Connection Id Id -> (or QaQuestion #f)
;; finds a question only within its owning session.
(define-query (find-question c sid qid) #:maybe-row row->question
  "SELECT " question-cols " FROM qa_questions WHERE session_id=$1 AND id=$2")

;; Connection Id Id QaStatus -> Void
;; changes a question's disposition.
(define-query (write-status! c sid qid status) #:exec
  "UPDATE qa_questions SET status=$3, updated_at=clock_timestamp() WHERE session_id=$1 AND id=$2")

;; Connection Id Id -> Void
;; returns a selected question to the generic Q&A screen without hiding that screen.
(define-query (clear-selected! c sid qid) #:exec
  "UPDATE lecture_sessions SET qa_selected=NULL WHERE id=$1 AND qa_selected=$2")

;; Connection Id Id QaStatus -> (or QaState 'not-found 'ended)
;; answers, dismisses or restores a question; restoring never displays it.
(define (set-question-status! c sid qid status)
  (call-with-transaction c
    (λ ()
      (match (lock-availability c sid)
        [#f 'not-found]
        [(availability _ _ _ _ _ #t) 'ended]
        [_
         (cond
           [(not (find-question c sid qid)) 'not-found]
           [else
            (write-status! c sid qid status)
            (unless (equal? status "pending") (clear-selected! c sid qid))
            (get-qa c sid)])]))))

;; Connection Id (or Id #f) -> Void
;; records Q&A projector selection, including the generic screen.
(define-query (write-screen! c sid [qid #:nullable]) #:exec
  "UPDATE lecture_sessions SET qa_on_screen=true, qa_selected=$2 WHERE id=$1")

;; Connection Id (or Id #f) -> (or QaState 'not-found 'ended 'disabled 'not-pending)
;; shows the generic screen or one pending question belonging to the session.
(define (show-qa! c sid qid)
  (call-with-transaction c
    (λ ()
      (match (lock-availability c sid)
        [#f 'not-found]
        [(availability _ _ _ _ _ #t) 'ended]
        [(availability #f _ _ _ _ _) 'disabled]
        [_
         (define question (and qid (find-question c sid qid)))
         (cond
           [(and qid (not question)) 'not-found]
           [(and question (not (equal? (qa-question-status question) "pending"))) 'not-pending]
           [else (write-screen! c sid qid) (get-qa c sid)])]))))

;; Connection Id -> Void
;; records that another projector overlay replaced Q&A, retaining the last selection.
(define-query (hide-qa! c sid) #:exec
  "UPDATE lecture_sessions SET qa_on_screen=false WHERE id=$1")
