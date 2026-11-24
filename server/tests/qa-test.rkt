#lang racket/base
;; Q&A integration tests against the ephemeral Postgres database.
(require rackunit racket/list db "support.rkt" "../db/conn.rkt" "../db/qa.rkt" "../db/repo.rkt" "../domain.rkt"
         "../live/codes.rkt" "../qa.rkt")

(define participant "11111111-1111-4111-8111-111111111111")
;; Connection Id String String -> (or QaQuestion Symbol)
;; parses test input before passing it to persistence
(define (submit-text! c sid participant raw)
  (submit-question! c sid participant (make-question-text raw)))

(define other-participant "22222222-2222-4222-8222-222222222222")

;; Connection Boolean -> (values Id Session)
;; a fresh deck and session with Q&A availability captured from the deck.
(define (setup-session! c enabled?)
  (define pid (new-deck! c (new-owner! c) "Q&A" 4))
  (set-deck-qa! c pid enabled?)
  (values pid (insert-session! c pid "Questions" (random-code) (random-code))))

;; Connection Id -> Void
;; ages submissions so a subsequent request passes the intentional ten-second cooldown.
(define (age-questions! c sid)
  (query-exec c "UPDATE qa_questions SET created_at=clock_timestamp()-interval '11 seconds' WHERE session_id=$1" sid))

;; Connection -> Void
;; exercises persistence, isolation, moderation and submission limits.
(define (run-tests c)
  (test-case "decks-qa-enabled batches the deck setting"
    (define owner (new-owner! c))
    (define on (new-deck! c owner "On" 1))
    (define off (new-deck! c owner "Off" 1))
    (set-deck-qa! c on #t)
    (check-equal? (decks-qa-enabled c '()) (hash))
    (check-equal? (decks-qa-enabled c (list on off)) (hash on #t off #f))
    (check-equal? (decks-qa-enabled c (list on 999999999)) (hash on #t)))
  (test-case "deck setting is captured at session creation; opening is explicit"
    (define-values (pid s) (setup-session! c #t))
    (define sid (session-id s))
    (check-true (deck-qa-enabled? c pid))
    (check-equal? (get-qa c sid) (qa-state #t #f #f #f '() #f))
    (check-false (qa-state-started? (set-qa-open! c sid #f)))
    (set-deck-qa! c pid #f)
    (check-true (qa-state-enabled? (get-qa c sid)))
    (define next (insert-session! c pid "Next" (random-code) (random-code)))
    (check-false (qa-state-enabled? (get-qa c (session-id next))))
    (check-equal? (set-qa-open! c (session-id next) #t) 'disabled)
    (check-false (get-qa c 999999999)))

  (test-case "only open sessions accept trimmed bounded questions"
    (define-values (_ s) (setup-session! c #t))
    (define sid (session-id s))
    (check-exn exn:fail:contract? (λ () (submit-question! c sid participant "unchecked text")))
    (check-equal? (submit-text! c sid participant "Question?") 'closed)
    (set-qa-open! c sid #t)
    (define q (submit-text! c sid participant " \n  Why this example?  \t"))
    (check-equal? (qa-question-body q) "Why this example?")
    (check-equal? (qa-question-status q) "pending")
    (check-equal? (qa-question-participant q) participant)
    (check-true (string? (qa-question-created-at q)))
    (check-equal? (qa-state-questions (get-qa c sid)) (list q)))

  (test-case "cooldown belongs to the participant and session"
    (define-values (_ a) (setup-session! c #t))
    (define-values (_2 b) (setup-session! c #t))
    (set-qa-open! c (session-id a) #t)
    (set-qa-open! c (session-id b) #t)
    (check-true (qa-question? (submit-text! c (session-id a) participant "One")))
    (check-equal? (submit-text! c (session-id a) participant "Two") 'too-fast)
    (check-true (qa-question? (submit-text! c (session-id a) other-participant "Other browser")))
    (check-true (qa-question? (submit-text! c (session-id b) participant "Other class")))
    (age-questions! c (session-id a))
    (check-true (qa-question? (submit-text! c (session-id a) participant "After cooldown"))))

  (test-case "the twentieth question is accepted, the twenty-first is refused"
    (define-values (_ s) (setup-session! c #t))
    (define sid (session-id s))
    (set-qa-open! c sid #t)
    (for ([i (in-range 20)])
      (age-questions! c sid)
      (check-true (qa-question? (submit-text! c sid participant (format "Question ~a" i)))))
    (age-questions! c sid)
    (check-equal? (submit-text! c sid participant "One more") 'limit)
    (check-equal? (length (qa-state-questions (get-qa c sid))) 20))

  (test-case "concurrent submissions cannot bypass the participant cooldown"
    (define-values (_ s) (setup-session! c #t))
    (define sid (session-id s))
    (set-qa-open! c sid #t)
    (define a (connect-direct (test-db-url)))
    (define b (connect-direct (test-db-url)))
    (define results (make-channel))
    (dynamic-wind
      void
      (λ ()
        (for ([conn (list a b)])
          (thread (λ ()
                    (channel-put results
                                 (with-handlers ([exn:fail? values])
                                   (submit-text! conn sid participant "Concurrent question"))))))
        (define first (sync/timeout 10 results))
        (define second (sync/timeout 10 results))
        (check-equal? (count qa-question? (list first second)) 1)
        (check-equal? (count (λ (v) (eq? v 'too-fast)) (list first second)) 1)
        (check-equal? (length (qa-state-questions (get-qa c sid))) 1))
      (λ () (disconnect a) (disconnect b))))

  (test-case "close/reopen retains private questions and projector state"
    (define-values (_ s) (setup-session! c #t))
    (define sid (session-id s))
    (set-qa-open! c sid #t)
    (define q (submit-text! c sid participant "Keep this"))
    (show-qa! c sid (qa-question-id q))
    (define closed (set-qa-open! c sid #f))
    (check-false (qa-state-open? closed))
    (check-true (qa-state-started? closed))
    (check-true (qa-state-on-screen? closed))
    (check-equal? (qa-state-selected-id closed) (qa-question-id q))
    (check-equal? (submit-text! c sid other-participant "Too late") 'closed)
    (check-equal? (qa-state-questions (set-qa-open! c sid #t)) (list q)))

  (test-case "only an explicitly selected pending question can be projected"
    (define-values (_ a) (setup-session! c #t))
    (define-values (_2 b) (setup-session! c #t))
    (define sid (session-id a))
    (set-qa-open! c sid #t)
    (define q (submit-text! c sid participant "Show me"))
    (define qid (qa-question-id q))
    (check-equal? (show-qa! c (session-id b) qid) 'not-found)
    (check-equal? (set-question-status! c (session-id b) qid "answered") 'not-found)
    (define generic (show-qa! c sid #f))
    (check-true (qa-state-on-screen? generic))
    (check-false (qa-state-selected-id generic))
    (show-qa! c sid qid)
    (check-equal? (qa-state-selected-id (get-qa c sid)) qid)
    (define answered (set-question-status! c sid qid "answered"))
    (check-true (qa-state-on-screen? answered))
    (check-false (qa-state-selected-id answered))
    (check-equal? (show-qa! c sid qid) 'not-pending)
    (check-false (qa-state-selected-id (set-question-status! c sid qid "pending")))
    (show-qa! c sid qid)
    (check-false (qa-state-selected-id (set-question-status! c sid qid "dismissed")))
    (hide-qa! c sid)
    (check-false (qa-state-on-screen? (get-qa c sid))))

  (test-case "ending closes submissions and rejects every further mutation"
    (define-values (_ s) (setup-session! c #t))
    (define sid (session-id s))
    (set-qa-open! c sid #t)
    (define q (submit-text! c sid participant "Last one"))
    (end-session! c sid)
    (check-false (qa-state-open? (get-qa c sid)))
    (check-equal? (submit-text! c sid other-participant "After end") 'ended)
    (check-equal? (set-qa-open! c sid #t) 'ended)
    (check-equal? (show-qa! c sid #f) 'ended)
    (check-equal? (set-question-status! c sid (qa-question-id q) "answered") 'ended))
  (disconnect c))

(module+ test
  (if (test-db-url)
      (run-tests (fresh-db!))
      (eprintf "SKIPPED qa-test: TEST_DATABASE_URL not set (use scripts/with-ephemeral-pg)\n")))
