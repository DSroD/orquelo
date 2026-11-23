#lang racket/base
;; Deck and poll operations shared by the REST handlers and other front ends (MCP tools).
;; Each does its own lookup and access check, mutates, and returns domain structs, or raises
;; exn:api (404/403/409/422). make-poll-draft may also raise exn:domain; callers map it.
;; Callers may validate the body before calling an op (no leak: validation never inspects the resource).
(require racket/contract/base racket/match
         "../db/qa.rkt" "../db/repo.rkt" "../domain.rkt"
         "deps.rkt" "json.rkt" "lookup.rkt" "validate.rkt")
(provide (contract-out
          [jsexpr->poll-draft (-> hash? natural-number/c poll-draft?)]
          [op-create-poll (-> deps? user? id/c hash? poll?)]
          [op-replace-poll (-> deps? user? id/c hash? poll?)]
          [op-set-show-results (-> deps? user? id/c boolean? poll?)]
          [op-delete-poll (-> deps? user? id/c void?)]
          [op-duplicate-poll (-> deps? user? id/c poll?)]
          [op-rename-deck (-> deps? user? id/c string? void?)]
          [op-set-qa-enabled (-> deps? user? id/c boolean? void?)]
          [session-results-of (-> deps? session? presentation? session-results?)]))

;; -> Nothing
(define (poll-has-runs!) (api-error! 409 "poll_has_runs" "poll has runs; duplicate it to edit"))

;; JSObject Natural -> PollDraft
;; the poll in a request body, shared by create and replace; 422 naming the first bad field
(define (jsexpr->poll-draft h page-count)
  (make-poll-draft (body-slide-or-null h 'slide page-count) (hash-ref h 'question #f)
                   (hash-ref h 'kind #f) (jsexpr->option-drafts h)
                   (body-bool-or-default h 'show_results #f) (body-bool-or-default h 'allow_additional_answers #f)))

;; JSObject -> [Listof OptionDraft]
;; parses option objects into trusted answer definitions
(define (jsexpr->option-drafts h)
  (define raw (hash-ref h 'options #f))
  (unless (list? raw) (invalid! 'options "options must have 2 to 30 items"))
  (for/list ([o raw])
    (unless (hash? o) (invalid! 'options "each option must be an object"))
    (make-option-draft (hash-ref o 'label #f) (body-bool-or-default o 'exclusive #f))))

;; Deps User Id JSObject -> Poll
;; adds the poll described by `body` to the deck
(define (op-create-poll d me pid body)
  (define dk (need-deck d me pid 'edit))
  (define draft (jsexpr->poll-draft body (presentation-page-count (deck-presentation dk))))
  (create-poll! (deps-db d) pid draft))

;; Deps User Id JSObject -> Poll
;; replaces the content of poll `id`; 409 once it has runs
(define (op-replace-poll d me id body)
  (define existing (need-user-poll d me id 'edit))
  (define p (need-presentation-of d existing))
  (define draft (jsexpr->poll-draft body (presentation-page-count p)))
  (match (update-poll! (deps-db d) id draft)
    [#f (not-found! "poll not found")]
    ['has-runs (poll-has-runs!)]
    [updated updated]))

;; Deps User Id Boolean -> Poll
;; the display setting stays editable after runs, unlike the poll's content
(define (op-set-show-results d me id show?)
  (need-user-poll d me id 'edit)
  (found (set-show-results! (deps-db d) id show?) "poll not found"))

;; Deps User Id -> Void
(define (op-delete-poll d me id)
  (need-user-poll d me id 'edit)
  (match (delete-poll! (deps-db d) id)
    ['ok (void)]
    ['has-runs (poll-has-runs!)]
    [#f (not-found! "poll not found")]))

;; Deps User Id -> Poll
(define (op-duplicate-poll d me id)
  (need-user-poll d me id 'edit)
  (found (duplicate-poll! (deps-db d) id) "poll not found"))

;; Deps User Id String -> Void
(define (op-rename-deck d me id title)
  (need-deck d me id 'edit)
  (found (rename-presentation! (deps-db d) id title) "presentation not found")
  (void))

;; Deps User Id Boolean -> Void
;; configures Q&A availability for future sessions
(define (op-set-qa-enabled d me id enabled?)
  (need-deck d me id 'edit)
  (set-deck-qa! (deps-db d) id enabled?))

;; Deps Session Presentation -> SessionResults
(define (session-results-of d s p)
  (session-results s p (results-totals-row (deps-db d) (session-id s)) (run-results (deps-db d) (session-id s))))

(module+ test
  (require rackunit "../domain/parse.rkt")
  (define (field-of thunk) (with-handlers ([exn:api? exn:api-field]) (thunk) #f))
  (define ok (hasheq 'slide 2 'question "Q?" 'kind "single" 'show_results #t
                     'options (list (hasheq 'label "a") (hasheq 'label "b" 'exclusive #f))))
  (test-case "a poll body becomes a trusted draft"
    (define draft (jsexpr->poll-draft ok 3))
    (check-equal? (poll-draft-slide draft) 2)
    (check-equal? (map option-draft-label (poll-draft-options draft)) '("a" "b"))
    (check-true (poll-draft-show-results? draft)))
  (test-case "bad poll bodies name the field"
    (check-equal? (field-of (λ () (jsexpr->poll-draft (hash-remove ok 'options) 3))) "options")
    (check-equal? (field-of (λ () (jsexpr->poll-draft (hash-set ok 'options '("a" "b")) 3))) "options")
    (check-equal? (field-of (λ () (jsexpr->poll-draft (hash-set ok 'slide 9) 3))) "slide")
    (check-exn exn:domain? (λ () (jsexpr->poll-draft (hash-set ok 'kind "bogus") 3)))))
