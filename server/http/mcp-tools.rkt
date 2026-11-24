#lang racket/base
;; The tools Orquelo offers over MCP, as thin front ends to the deck operations the REST handlers use.
;; Failures (exn:api, exn:domain) are mapped to tool errors by mcp-routes.rkt. Results are aggregates
;; only: never join codes, raw votes or Q&A text.
(require racket/contract/base racket/list racket/match json
         "../db/qa.rkt" (except-in "../db/repo.rkt" list-sessions) (only-in "../db/repo.rkt" [list-sessions sessions-of-deck]) "../domain.rkt" "../mcp/main.rkt"
         "deck-ops.rkt" "deps.rkt" "json.rkt" "lookup.rkt")
(provide (contract-out
          [struct mcp-ctx ([deps deps?] [user user?])]
          [mcp-tools (listof tool?)]
          [mcp-results->jsexpr (-> session-results? jsexpr?)]))

;; An McpCtx is an (mcp-ctx Deps User): what every tool call gets, the user being the authenticated one
(struct mcp-ctx (deps user))

;; the largest id Postgres can hold that JSON can carry exactly
(define max-id 9007199254740991)

;; ------------------------------------------------------------------ poll arguments

;; A PollIn is a (poll-in Id PollDraft)
;; interpretation: the deck (create_poll) or the poll (replace_poll) to act on, and the poll's content.
;; The draft's own guard enforces the content rules (it raises exn:domain, a tool error); the deck rules,
;; such as the slide being within the page count, are the ops'
(struct poll-in (id draft))

;; Id (or Natural #f) String Kind (Listof OptionDraft) Boolean Boolean -> PollIn
(define (poll-args id slide question kind options show-results? allow-additional?)
  (poll-in id (make-poll-draft slide question kind options show-results? allow-additional?)))

;; ------------------------------------------------------------------ reading

(define-tool (list-decks ctx)
  #:title "List decks"
  #:description "Lists your decks (presentations), newest first, including decks shared with you. Each has an id, title, page_count (slides are numbered 1..page_count), qa_enabled and your access to it. Pass archived=true for archived decks."
  #:scope "decks" #:read-only
  #:args [archived? (values [archived (optional-boolean #f)])]
  (match-define (mcp-ctx d me) ctx)
  (define listings (list-presentations (deps-db d) (user-id me) archived?))
  (define qa (decks-qa-enabled (deps-db d) (map listing-id listings)))
  (hasheq 'decks (for/list ([l (in-list listings)])
                   (presentation-listing->jsexpr l (hash-ref qa (listing-id l) #f)))))

(define-tool (get-deck ctx)
  #:title "Get a deck"
  #:description "Shows one deck: title, page_count (slides are numbered 1..page_count), qa_enabled, your access, and a flat list of its polls. Each poll has an id, the slide it is attached to (null = none), question, kind (single or multi), its options and has_runs (a poll that was ever opened cannot be replaced, only duplicated). disabled is true when the deck's edition has switched it off. Live sessions and their join codes are not shown."
  #:scope "decks" #:read-only
  #:args [id (values [deck-id (integer 1 max-id)])]
  (match-define (mcp-ctx d me) ctx)
  (define dk (need-deck d me id 'view))
  (define result
    (hash-set (deck->jsexpr dk (deck-qa-enabled? (deps-db d) id)) 'polls (map poll->jsexpr (list-polls (deps-db d) id))))
  (if ((current-deck-disabled?) (deps-db d) id) (hash-set result 'disabled #t) result))

;; ------------------------------------------------------------------ editing

(define-tool (create-poll ctx)
  #:title "Create a poll"
  #:description "Adds a poll to a deck. slide is the slide number it appears on (1..page_count of the deck), or null for a poll that is not tied to a slide. kind is single (one answer) or multi (several). Give 2 to 30 options; an exclusive option must be chosen alone and needs kind multi. show_results makes the results appear on the screen as soon as the poll is opened. Returns the new poll."
  #:scope "decks"
  #:args [in (poll-args [deck-id (integer 1 max-id)]
                      [slide (nullable (integer 1 100000))]
                      [question (string 1 500)]
                      [kind (one-of "single" "multi")]
                      [options (array (object make-option-draft [label (string 1 200)] [exclusive (optional-boolean #f)]) 2 30)]
                      [show-results (optional-boolean #f)]
                      [allow-additional-answers (optional-boolean #f)])]
  (poll->jsexpr (op-create-poll (mcp-ctx-deps ctx) (mcp-ctx-user ctx) (poll-in-id in) (poll-in-draft in))))

(define-tool (replace-poll ctx)
  #:title "Replace a poll"
  #:description "Replaces the whole content of a poll (same fields as create_poll, plus its poll_id instead of deck_id). It fails with poll_has_runs once the poll was ever opened in a session, because votes belong to the old content: use duplicate_poll and replace the copy instead."
  #:scope "decks" #:destructive #:idempotent
  #:args [in (poll-args [poll-id (integer 1 max-id)]
                      [slide (nullable (integer 1 100000))]
                      [question (string 1 500)]
                      [kind (one-of "single" "multi")]
                      [options (array (object make-option-draft [label (string 1 200)] [exclusive (optional-boolean #f)]) 2 30)]
                      [show-results (optional-boolean #f)]
                      [allow-additional-answers (optional-boolean #f)])]
  (poll->jsexpr (op-replace-poll (mcp-ctx-deps ctx) (mcp-ctx-user ctx) (poll-in-id in) (poll-in-draft in))))

(define-tool (delete-poll ctx)
  #:title "Delete a poll"
  #:description "Permanently deletes a poll. It fails with poll_has_runs once the poll was ever opened in a session."
  #:scope "decks" #:destructive
  #:args [id (values [poll-id (integer 1 max-id)])]
  (op-delete-poll (mcp-ctx-deps ctx) (mcp-ctx-user ctx) id)
  (hasheq 'deleted #t 'poll_id id))

(define-tool (duplicate-poll ctx)
  #:title "Duplicate a poll"
  #:description "Copies a poll, with no runs, so its copy can be edited with replace_poll. Works for polls that already have runs. Returns the copy."
  #:scope "decks"
  #:args [id (values [poll-id (integer 1 max-id)])]
  (poll->jsexpr (op-duplicate-poll (mcp-ctx-deps ctx) (mcp-ctx-user ctx) id)))

(define-tool (set-poll-show-results ctx)
  #:title "Show results when a poll opens"
  #:description "Sets whether opening the poll shows its results on the screen right away. Allowed even when the poll has runs. Returns the poll."
  #:scope "decks" #:idempotent
  #:args [in (cons [poll-id (integer 1 max-id)] [show-results (boolean)])]
  (poll->jsexpr (op-set-show-results (mcp-ctx-deps ctx) (mcp-ctx-user ctx) (car in) (cdr in))))

(define-tool (rename-deck ctx)
  #:title "Rename a deck"
  #:description "Changes the title of a deck."
  #:scope "decks" #:idempotent
  #:args [in (cons [deck-id (integer 1 max-id)] [title (string 1 200)])]
  (op-rename-deck (mcp-ctx-deps ctx) (mcp-ctx-user ctx) (car in) (cdr in))
  (hasheq 'id (car in) 'title (cdr in)))

(define-tool (set-qa-enabled ctx)
  #:title "Enable or disable Q&A"
  #:description "Sets whether audience Q&A is available in future sessions of the deck."
  #:scope "decks" #:idempotent
  #:args [in (cons [deck-id (integer 1 max-id)] [enabled (boolean)])]
  (op-set-qa-enabled (mcp-ctx-deps ctx) (mcp-ctx-user ctx) (car in) (cdr in))
  (hasheq 'id (car in) 'qa_enabled (cdr in)))

;; ------------------------------------------------------------------ results

;; Session -> JSObject
;; a session as list_sessions shows it; never its join codes
(define (session->jsexpr s)
  (hasheq 'session_id (session-id s) 'label (session-label s) 'started_at (session-started-at s)
          'ended_at (or (session-ended-at s) 'null)))

;; SessionResults -> JSObject
;; one session as aggregates: label, times and, per poll run, the count of every option and the voters.
;; The join codes, the votes and the Q&A are left out
(define (mcp-results->jsexpr sr)
  (match-define (session-results s _ t runs) sr)
  (hash-set* (session->jsexpr s) 'unique_voters (results-totals-unique-voters t) 'runs (map run->jsexpr runs)))

;; RunResult -> JSObject
;; one poll run: its question, times, number of voters and the count of every option
(define (run->jsexpr r)
  (hasheq 'run_id (run-result-run-id r) 'poll_id (run-result-poll-id r) 'slide (or (run-result-slide r) 'null)
          'question (run-result-question r) 'kind (run-result-kind r)
          'opened_at (run-result-opened-at r) 'closed_at (or (run-result-closed-at r) 'null)
          'total_voters (run-result-total-voters r)
          'options (for/list ([o (run-result-options r)]) (hasheq 'label (option-count-label o) 'count (option-count-count o)))))

(define-tool (list-sessions ctx)
  #:title "List sessions"
  #:description "Lists the sessions (lecture runs) of a deck, newest first: session_id, label, started_at, ended_at (null while live). Cheap: use it to find the session_id to pass to get_results. Join codes are never returned."
  #:scope "results" #:read-only
  #:args [id (values [deck-id (integer 1 max-id)])]
  (match-define (mcp-ctx d me) ctx)
  (need-deck d me id 'results)
  (hasheq 'deck_id id 'sessions (map session->jsexpr (sessions-of-deck (deps-db d) id))))

;; A ResultsIn is a (results-in Id (or Id #f) Natural): the deck, one session of it if asked, the most sessions to show
(struct results-in (deck session limit))

(define-tool (get-results ctx)
  #:title "Get poll results"
  #:description "Aggregate results of a deck's sessions, newest session first: per session its label, start and end, and per poll run the vote count of every option and the number of voters. Without session_id it returns the newest `limit` sessions (default 10, at most 50); total_sessions and truncated say whether more exist, and list_sessions finds them. Pass session_id for one session. Individual votes, join codes and Q&A text are never returned."
  #:scope "results" #:read-only
  #:args [in (results-in [deck-id (integer 1 max-id)] [session-id (optional (integer 1 max-id))] [limit (optional-integer 1 50 10)])]
  (match-define (mcp-ctx d me) ctx)
  (define dk (need-deck d me (results-in-deck in) 'results))
  (define p (deck-presentation dk))
  (define all (sessions-of-deck (deps-db d) (results-in-deck in)))
  (define wanted (results-in-session in))
  (define chosen
    (cond [wanted (list (or (findf (λ (s) (= (session-id s) wanted)) all) (not-found! "session not found")))]
          [else (take-up-to all (results-in-limit in))]))
  (hasheq 'deck_id (presentation-id p) 'title (presentation-title p)
          'total_sessions (length all) 'truncated (and (not wanted) (< (length chosen) (length all)))
          'sessions (for/list ([s chosen]) (mcp-results->jsexpr (session-results-of d s p)))))

;; (Listof X) Natural -> (Listof X)
;; the first n items, or all when there are fewer
(define (take-up-to xs n) (if (<= (length xs) n) xs (take xs n)))

;; (Listof Tool)
(define mcp-tools
  (list list-decks get-deck create-poll replace-poll delete-poll duplicate-poll set-poll-show-results
        rename-deck set-qa-enabled list-sessions get-results))

(module+ test
  (require rackunit "../domain/parse.rkt")
  (test-case "every tool is scoped; the results tools need results; the names are stable"
    (for ([t mcp-tools])
      (check-equal? (tool-scope t) (if (member (tool-name t) '("get_results" "list_sessions")) "results" "decks") (tool-name t)))
    (check-equal? (map tool-name mcp-tools)
                  '("list_decks" "get_deck" "create_poll" "replace_poll" "delete_poll" "duplicate_poll"
                    "set_poll_show_results" "rename_deck" "set_qa_enabled" "list_sessions" "get_results"))
    (check-true (jsexpr? (map tool->jsexpr mcp-tools))))
  (test-case "poll arguments become a validated draft"
    (define in (poll-args 1 3 "Q" "single" (list (make-option-draft "a" #f) (make-option-draft "b" #f)) #f #f))
    (check-equal? (poll-draft-slide (poll-in-draft in)) 3)
    (check-exn exn:domain? (λ () (poll-args 1 3 "Q" "single" (list (make-option-draft "a" #t) (make-option-draft "b" #f)) #f #f))))
  (test-case "take-up-to"
    (check-equal? (take-up-to '(1 2 3) 2) '(1 2))
    (check-equal? (take-up-to '(1) 2) '(1))))
