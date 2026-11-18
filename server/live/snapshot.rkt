#lang racket/base
;; What each role sees of a live session. Pure data; http/json.rkt turns it into JSON.
(require racket/contract/base "../domain.rkt" "../qa.rkt")
(provide (contract-out
          [snapshot? (-> any/c boolean?)]
          [struct connections ([audience natural-number/c] [screen natural-number/c])]
          [struct session-brief ([code string?] [label string?])]
          [struct deck-brief ([id id/c] [title string?])]
          [struct deck-info ([id id/c] [title string?] [page-count id/c])]
          [struct choice ([id id/c] [label string?] [exclusive? boolean?])]
          [struct tally ([id id/c] [label string?] [count natural-number/c] [exclusive? boolean?])]
          [struct audience-poll ([run-id id/c] [question string?] [kind kind/c] [open? boolean?] [choices (listof choice?)])]
          [struct screen-option ([id id/c] [label string?] [count (or/c natural-number/c #f)])]
          [struct screen-poll ([run-id id/c] [question string?] [kind kind/c] [open? boolean?] [revealed? boolean?]
                               [options (listof screen-option?)] [total-voters natural-number/c])]
          [struct audience-snapshot ([session session-brief?] [presentation deck-brief?]
                                     [poll (or/c audience-poll? #f)] [my-vote (or/c (listof id/c) #f)] [qa qa-state?])]
          [struct screen-stage ([slide id/c] [overlay (or/c qr-overlay? screen-poll? screen-qa? #f)])]
          [struct screen-snapshot ([session session-brief?] [presentation deck-info?] [join-url string?]
                                   [stage screen-stage?])]
          [struct moderator-session ([code string?] [screen-code string?] [label string?] [started-at time/c] [ended-at (or/c time/c #f)])]
          [struct moderator-open-run ([run-id id/c] [poll-id id/c] [question string?] [kind kind/c] [opened-at time/c]
                                  [tallies (listof tally?)] [total-voters natural-number/c] [allow-additional? boolean?])]
          [struct run-summary ([run-id id/c] [poll-id id/c] [question string?] [kind kind/c] [opened-at time/c]
                               [closed-at (or/c time/c #f)] [total-voters natural-number/c])]
          [struct moderator-snapshot ([session moderator-session?] [presentation deck-info?]
                                  [audience-url string?] [screen-url string?] [connections connections?]
                                  [stage stage?] [open-run (or/c moderator-open-run? #f)] [runs (listof run-summary?)] [qa qa-state?])]
          [struct screen-qa ([question (or/c qa-question? #f)] [open? boolean?])]
          [struct editor-snapshot ([session session-brief?] [started-at time/c] [ended-at (or/c time/c #f)]
                                   [presentation deck-info?] [audience-url string?] [open-run (or/c moderator-open-run? #f)])]))

;; A Snapshot is an AudienceSnapshot, ScreenSnapshot, ModeratorSnapshot or EditorSnapshot.
;; interp. the full view one subscriber receives; equal? snapshots need not be re-sent.

;; Any -> Boolean
;; is x a Snapshot?
(define (snapshot? x) (or (audience-snapshot? x) (screen-snapshot? x) (moderator-snapshot? x) (editor-snapshot? x)))

;; A Connections is a (connections Natural Natural): subscribers per role (audience, screen).
(struct connections (audience screen) #:transparent)
;; A SessionBrief is a (session-brief String String): code and label.
(struct session-brief (code label) #:transparent)
;; A DeckBrief is a (deck-brief Id String): the presentation without its page count (audience).
(struct deck-brief (id title) #:transparent)
;; A DeckInfo is a (deck-info Id String Id): the presentation with its page count.
(struct deck-info (id title page-count) #:transparent)
;; A Choice is a (choice Id String Boolean): label and exclusive-selection rule, without counts.
(struct choice (id label exclusive?) #:transparent)
;; A Tally is a (tally Id String Natural Boolean): votes received and exclusive-selection rule.
(struct tally (id label count exclusive?) #:transparent)
;; An AudiencePoll is an (audience-poll Id String Kind Boolean [Listof Choice])
(struct audience-poll (run-id question kind open? choices) #:transparent)
;; A ScreenOption is a (screen-option Id String (or Natural #f)): an option with its count, #f until revealed.
(struct screen-option (id label count) #:transparent)
;; A ScreenPoll is a (screen-poll Id String Kind Boolean Boolean [Listof ScreenOption] Natural)
;; interp. the poll overlay as the screen sees it; total-voters is always present, the counts only once revealed.
(struct screen-poll (run-id question kind open? revealed? options total-voters) #:transparent)
;; An AudienceSnapshot is an (audience-snapshot SessionBrief DeckBrief (or AudiencePoll #f) (or [Listof Id] #f) QaState)
;; interp. my-vote and Q&A questions belong only to this participant.
(struct audience-snapshot (session presentation poll my-vote qa) #:transparent)
;; A ScreenOverlay is one of: (qr-overlay), a ScreenPoll or a ScreenQa.
;; A ScreenStage is a (screen-stage Id (or ScreenOverlay #f)): the slide and the overlay on top of it, if any.
(struct screen-stage (slide overlay) #:transparent)
;; A ScreenSnapshot is a (screen-snapshot SessionBrief DeckInfo String ScreenStage)
(struct screen-snapshot (session presentation join-url stage) #:transparent)
;; An ModeratorSession is an (moderator-session String String String Time (or Time #f))
;; interp. screen-code is the presenter-only code: no other role ever receives it.
(struct moderator-session (code screen-code label started-at ended-at) #:transparent)
;; A ModeratorOpenRun is a (moderator-open-run Id Id String Kind Time [Listof Tally] Natural Boolean).
;; interp. the run accepting votes and whether editors may append options.
(struct moderator-open-run (run-id poll-id question kind opened-at tallies total-voters allow-additional?) #:transparent)
;; A RunSummary is a (run-summary Id Id String Kind Time (or Time #f) Natural): one entry of the session's run history.
(struct run-summary (run-id poll-id question kind opened-at closed-at total-voters) #:transparent)
;; An ModeratorSnapshot is an (moderator-snapshot ModeratorSession DeckInfo String String Connections Stage
;;                                         (or ModeratorOpenRun #f) [Listof RunSummary] QaState)
;; interp. runs is the session's history, newest first.
(struct moderator-snapshot (session presentation audience-url screen-url connections stage open-run runs qa) #:transparent)

;; A ScreenQa is a (screen-qa (or QaQuestion #f) Boolean): only the selected question is public.
(struct screen-qa (question open?) #:transparent)
;; An EditorSnapshot is an (editor-snapshot SessionBrief Time (or Time #f) DeckInfo String (or ModeratorOpenRun #f)).
;; interp. live editing context without projector credentials or the private Q&A inbox.
(struct editor-snapshot (session started-at ended-at presentation audience-url open-run) #:transparent)
