#lang racket/base
;; The tools Orquelo offers over MCP, as thin front ends to the deck operations the REST handlers use.
;; Failures (exn:api, exn:domain) are mapped to tool errors by mcp-routes.rkt. Results are aggregates
;; only: never join codes, raw votes or Q&A text.
(require racket/contract/base racket/list racket/match json
         "../db/qa.rkt" (except-in "../db/repo.rkt" list-sessions) (only-in "../db/repo.rkt" [list-sessions sessions-of-deck]) "../domain.rkt" "../mcp/main.rkt"
         "deck-ops.rkt" "deps.rkt" "json.rkt" "lookup.rkt")
(provide (contract-out
          [struct mcp-ctx ([deps deps?] [user user?])]
          [mcp-tools (listof tool?)]))

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
;; the arguments of create_poll and replace_poll, the content validated as a PollDraft
(define (poll-args id slide question kind options show-results? allow-additional?)
  (poll-in id (make-poll-draft slide question kind options show-results? allow-additional?)))

;; A ShowIn is a (show-in Id Boolean): the poll and whether opening it shows its results
(struct show-in (poll-id show?))
;; A TitleIn is a (title-in Id String): the deck and its new title
(struct title-in (deck-id title))
;; A QaIn is a (qa-in Id Boolean): the deck and whether Q&A is available
(struct qa-in (deck-id enabled?))

;; ------------------------------------------------------------------ reading

(define-tool (list-decks ctx)
  #:title "List decks"
  #:description "Lists your decks (presentations), newest first, including decks shared with you. Each has an id, title, page_count (slides are numbered 1..page_count), qa_enabled and your access to it. Pass archived=true for archived decks."
  #:scope "decks" #:read-only
  #:args [archived? (values [archived (optional-boolean #f)])]
  (match-define (mcp-ctx d me) ctx)
  (define listings (list-presentations (deps-db d) (user-id me) archived?))
  (mcp-deck-list->jsexpr listings (decks-qa-enabled (deps-db d) (map listing-id listings))))

(define-tool (get-deck ctx)
  #:title "Get a deck"
  #:description "Shows one deck: title, page_count (slides are numbered 1..page_count), qa_enabled, your access, and a flat list of its polls. Each poll has an id, the slide it is attached to (null = none), question, kind (single or multi), its options and has_runs (a poll that was ever opened cannot be replaced, only duplicated). disabled is true when the deck's edition has switched it off (only its owner can still read it). Live sessions and their join codes are not shown."
  #:scope "decks" #:read-only
  #:args [id (values [deck-id (integer 1 max-id)])]
  (match-define (mcp-ctx d me) ctx)
  (define dk (need-deck d me id 'view))
  (mcp-deck->jsexpr dk (deck-qa-enabled? (deps-db d) id) (list-polls (deps-db d) id) ((current-deck-disabled?) (deps-db d) id)))

;; ------------------------------------------------------------------ editing

(define-tool (create-poll ctx)
  #:title "Create a poll"
  #:description "Adds a poll to a deck. slide is the slide number it appears on (1..page_count of the deck), or null for a poll that is not tied to a slide. kind is single (one answer) or multi (several). Give 2 to 30 options; an exclusive option must be chosen alone and needs kind multi. show_results makes the results appear on the screen as soon as the poll is opened. Returns the new poll."
  #:scope "decks"
  #:args [in (poll-args [deck-id (integer 1 max-id)]
                      [slide (nullable (integer 1 100000))]
                      [question (string 1 max-question-length)]
                      [kind (one-of "single" "multi")]
                      [options (array (object make-option-draft [label (string 1 max-label-length)] [exclusive (optional-boolean #f)]) min-options max-options)]
                      [show-results (optional-boolean #f)]
                      [allow-additional-answers (optional-boolean #f)])]
  (poll->jsexpr (op-create-poll (mcp-ctx-deps ctx) (mcp-ctx-user ctx) (poll-in-id in) (poll-in-draft in))))

(define-tool (replace-poll ctx)
  #:title "Replace a poll"
  #:description "Replaces the whole content of a poll (same fields as create_poll, plus its poll_id instead of deck_id). It fails with poll_has_runs once the poll was ever opened in a session, because votes belong to the old content: use duplicate_poll and replace the copy instead."
  #:scope "decks" #:destructive #:idempotent
  #:args [in (poll-args [poll-id (integer 1 max-id)]
                      [slide (nullable (integer 1 100000))]
                      [question (string 1 max-question-length)]
                      [kind (one-of "single" "multi")]
                      [options (array (object make-option-draft [label (string 1 max-label-length)] [exclusive (optional-boolean #f)]) min-options max-options)]
                      [show-results (optional-boolean #f)]
                      [allow-additional-answers (optional-boolean #f)])]
  (poll->jsexpr (op-replace-poll (mcp-ctx-deps ctx) (mcp-ctx-user ctx) (poll-in-id in) (poll-in-draft in))))

(define-tool (delete-poll ctx)
  #:title "Delete a poll"
  #:description "Permanently deletes a poll. It fails with poll_has_runs once the poll was ever opened in a session."
  #:scope "decks" #:destructive
  #:args [id (values [poll-id (integer 1 max-id)])]
  (op-delete-poll (mcp-ctx-deps ctx) (mcp-ctx-user ctx) id)
  (mcp-poll-deleted->jsexpr id))

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
  #:args [in (show-in [poll-id (integer 1 max-id)] [show-results (boolean)])]
  (match-define (show-in pid show?) in)
  (poll->jsexpr (op-set-show-results (mcp-ctx-deps ctx) (mcp-ctx-user ctx) pid show?)))

(define-tool (rename-deck ctx)
  #:title "Rename a deck"
  #:description "Changes the title of a deck."
  #:scope "decks" #:idempotent
  #:args [in (title-in [deck-id (integer 1 max-id)] [title (string 1 200)])]
  (match-define (title-in id title) in)
  (op-rename-deck (mcp-ctx-deps ctx) (mcp-ctx-user ctx) id title)
  (mcp-deck-renamed->jsexpr id title))

(define-tool (set-qa-enabled ctx)
  #:title "Enable or disable Q&A"
  #:description "Sets whether audience Q&A is available in future sessions of the deck."
  #:scope "decks" #:idempotent
  #:args [in (qa-in [deck-id (integer 1 max-id)] [enabled (boolean)])]
  (match-define (qa-in id enabled?) in)
  (op-set-qa-enabled (mcp-ctx-deps ctx) (mcp-ctx-user ctx) id enabled?)
  (mcp-qa-set->jsexpr id enabled?))

;; ------------------------------------------------------------------ results

(define-tool (list-sessions ctx)
  #:title "List sessions"
  #:description "Lists the sessions (lecture runs) of a deck, newest first: session_id, label, started_at, ended_at (null while live). Cheap: use it to find the session_id to pass to get_results. Join codes are never returned."
  #:scope "results" #:read-only
  #:args [id (values [deck-id (integer 1 max-id)])]
  (match-define (mcp-ctx d me) ctx)
  (need-deck d me id 'results)
  (mcp-sessions->jsexpr id (sessions-of-deck (deps-db d) id)))

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
  (mcp-results->jsexpr p (length all) (and (not wanted) (< (length chosen) (length all)))
                       (for/list ([s chosen]) (session-results-of d s p))))

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
