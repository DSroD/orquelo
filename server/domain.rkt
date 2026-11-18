#lang racket/base
;; Domain data, one struct per concept. SQL rows become these in db/repo.rkt; hashes and JSON
;; exist only at the edges (http/json.rkt). Contracts are enforced on construction.
(require racket/contract/base racket/match "qa.rkt")
(provide id/c kind/c time/c overlay/c status/c
         (contract-out
          [struct limits ([max-upload-bytes natural-number/c] [storage-quota-bytes (or/c natural-number/c #f)]
                          [plan (or/c string? #f)])]
          [struct user ([id id/c] [email (or/c string? #f)] [email-verified? boolean?] [name string?]
                        [status status/c])]
          [struct presentation ([id id/c] [title string?] [page-count id/c]
                                [created-at time/c] [archived-at (or/c time/c #f)])]
          [struct access ([owner? boolean?] [view? boolean?] [edit? boolean?] [moderate? boolean?]
                          [copy? boolean?] [results? boolean?])]
          [struct share ([email string?] [edit? boolean?] [moderate? boolean?] [copy? boolean?] [results? boolean?])]
          [struct owner ([email string?] [name string?])]
          [struct deck ([presentation presentation?] [owner owner?] [access access?])]
          [struct presentation-listing ([deck deck?] [live-sessions natural-number/c])]
          [struct option ([id id/c] [idx natural-number/c] [label string?] [exclusive? boolean?])]
          [struct option-draft ([label string?] [exclusive? boolean?])]
          [struct poll ([id id/c] [presentation-id id/c] [slide (or/c id/c #f)] [position natural-number/c]
                        [question string?] [kind kind/c] [options (listof option?)] [has-runs? boolean?]
                        [show-results? boolean?] [archived-at (or/c time/c #f)] [allow-additional? boolean?])]
          [struct poll-draft ([slide (or/c id/c #f)] [question string?] [kind kind/c] [options (listof option-draft?)]
                              [show-results? boolean?] [allow-additional? boolean?])]
          [struct stage ([slide id/c] [overlay (or/c overlay/c #f)])]
          [struct qr-overlay ()]
          [struct poll-overlay ([run-id id/c] [revealed? boolean?])]
          [struct session ([id id/c] [presentation-id id/c] [code string?] [screen-code string?] [label string?]
                           [current-slide id/c] [started-at time/c] [ended-at (or/c time/c #f)])]
          [struct session-view ([session session?] [audience-url string?] [screen-url string?])]
          [struct vote ([participant string?] [option-ids (listof id/c)])]
          [struct poll-run ([id id/c] [poll-id id/c] [question string?] [kind kind/c]
                            [opened-at time/c] [closed-at (or/c time/c #f)]
                            [options (listof option?)] [votes ballots?] [allow-additional? boolean?])]
          [ballots? (-> any/c boolean?)]
          [empty-ballots ballots?]
          [votes->ballots (-> (listof vote?) ballots?)]
          [ballots-cast (-> ballots? string? (listof id/c) ballots?)]
          [ballots-choice (-> ballots? string? (or/c (listof id/c) #f))]
          [ballots-tally (-> ballots? id/c natural-number/c)]
          [ballots-voters (-> ballots? natural-number/c)]
          [struct option-count ([id id/c] [idx natural-number/c] [label string?] [count natural-number/c])]
          [struct run-result ([run-id id/c] [poll-id id/c] [slide (or/c id/c #f)] [question string?] [kind kind/c]
                              [opened-at time/c] [closed-at (or/c time/c #f)] [total-voters natural-number/c]
                              [peak-audience (or/c natural-number/c #f)] [median-seconds (or/c real? #f)]
                              [changed-voters (or/c natural-number/c #f)] [options (listof option-count?)])]
          [struct results-totals ([unique-voters natural-number/c] [peak-audience (or/c natural-number/c #f)]
                                  [median-seconds (or/c real? #f)] [changed-votes (or/c natural-number/c #f)]
                                  [changed-voters (or/c natural-number/c #f)])]
          [struct session-results ([session session?] [presentation presentation?] [totals results-totals?]
                                   [runs (listof run-result?)])]))

;; An Id is a Natural: a database key (bigint).
(define id/c exact-nonnegative-integer?)
;; A Kind is "single" or "multi": how many options a vote may pick.
(define kind/c (or/c "single" "multi"))
;; A Time is a String: an ISO-8601 UTC timestamp, formatted by the database.
(define time/c string?)
;; A Status is "active" or "suspended": whether a user may log in and use the app.
(define status/c (or/c "active" "suspended"))

;; A Limits is a (limits Natural (or Natural #f) (or String #f))
;; interp. the largest single PDF a user may upload, the bytes of PDFs they may store (#f means unlimited)
;; and the name of their plan as shown to them (#f means none).
(struct limits (max-upload-bytes storage-quota-bytes plan) #:transparent)

;; A User is a (user Id (or String #f) Boolean String Status)
;; interp. a person who logged in: email (#f when no provider gave one), whether it is trusted for linking
;; and for receiving shares, display name and status.
(struct user (id email email-verified? name status) #:transparent)

;; A Presentation is a (presentation Id String Id Time (or Time #f))
;; interp. an uploaded PDF deck with its page count; archived-at is #f while active.
(struct presentation (id title page-count created-at archived-at) #:transparent)

;; An Access is an (access Boolean Boolean Boolean Boolean Boolean Boolean)
;; interp. what a user may do with a deck: owner? view? edit? moderate? copy? results?
(struct access (owner? view? edit? moderate? copy? results?) #:transparent)

;; A Share is a (share String Boolean Boolean Boolean Boolean)
;; interp. what the owner granted to a verified email (lowercase): edit? moderate? copy? results?
(struct share (email edit? moderate? copy? results?) #:transparent)

;; An Owner is an (owner String String)
;; interp. the display email ("" when the owner has none) and name of a deck's owner.
(struct owner (email name) #:transparent)

;; A Deck is a (deck Presentation Owner Access)
;; interp. a presentation as one user sees it: who owns it and what that user may do with it.
(struct deck (presentation owner access) #:transparent)

;; A PresentationListing is a (presentation-listing Deck Natural)
;; interp. a deck plus the number of its sessions still live.
(struct presentation-listing (deck live-sessions) #:transparent)

;; An Option is an (option Id Natural String Boolean)
;; interp. one answer of a poll or run; an exclusive answer must be chosen alone.
(struct option (id idx label exclusive?) #:transparent)

;; An OptionDraft is an (option-draft String Boolean).
;; interp. an answer label and whether it must be selected alone.
(struct option-draft (label exclusive?) #:transparent)

;; A Poll is a (poll Id Id (or Id #f) Natural String Kind [Listof Option] Boolean Boolean (or Time #f) Boolean)
;; interp. a question attached to a slide (#f = none); has-runs? once it was ever opened;
;; show-results? when opening it shows its results on the screen right away;
;; archived-at is #f while active; allow-additional? permits editors to append run-local answers.
(struct poll (id presentation-id slide position question kind options has-runs? show-results? archived-at allow-additional?)
  #:transparent)

;; A PollDraft is a (poll-draft (or Id #f) String Kind [Listof OptionDraft] Boolean Boolean)
;; interp. the editable content of a poll, before it is stored.
(struct poll-draft (slide question kind options show-results? allow-additional?) #:transparent)

;; An Overlay is one of:
;;  - (qr-overlay)             interp. the join QR + URL covers the slide
;;  - (poll-overlay Id Boolean)   interp. run <id> of the session covers the slide; #t = its results are shown
;;  - (qa-overlay (or Id #f)) interp. generic Q&A invitation or one moderated question
;; A live session shows (or Overlay #f); #f = only the slide. More kinds are further variants.
(struct qr-overlay () #:transparent)
(struct poll-overlay (run-id revealed?) #:transparent)
;; A Stage is a (stage Id (or Overlay #f))
;; interp. all the screen shows: the slide in the background and the overlay on top of it.
(struct stage (slide overlay) #:transparent)
(define overlay/c (or/c qr-overlay? poll-overlay? qa-overlay?))

;; A Session is a (session Id Id String String String Id Time (or Time #f))
;; interp. a live lecture over a presentation, joined by its code; screen-code is the presenter-only
;; code of the projector screen and the PDF; ended-at is #f while live.
(struct session (id presentation-id code screen-code label current-slide started-at ended-at) #:transparent)

;; A SessionView is a (session-view Session String String)
;; interp. a session with the public URLs derived from the configured base URL.
(struct session-view (session audience-url screen-url) #:transparent)

;; A Vote is a (vote String [Listof Id])
;; interp. a participant's chosen option ids, ordered by option idx.
(struct vote (participant option-ids) #:transparent)

;; A Ballots is a (ballots (Hash String [Listof Id]) (Hash Id Natural))
;; interp. each participant's chosen option ids (ordered by option idx) and how many participants
;; chose each option (zero counts are absent), kept in step.
(struct ballots (choices counts) #:transparent)

;; Ballots
(define empty-ballots (ballots (hash) (hash)))

;; [Listof Vote] -> Ballots
;; the ballots of the votes cast so far
(define (votes->ballots votes)
  (for/fold ([b empty-ballots]) ([v votes]) (ballots-cast b (vote-participant v) (vote-option-ids v))))

;; Ballots String [Listof Id] -> Ballots
;; the ballots with the participant's choice replacing their earlier one, if any
(define (ballots-cast b participant ids)
  (match-define (ballots choices counts) b)
  (define without-old (shift-counts counts (hash-ref choices participant '()) sub1))
  (ballots (hash-set choices participant ids) (shift-counts without-old ids add1)))

;; (Hash Id Natural) [Listof Id] (Natural -> Natural) -> (Hash Id Natural)
;; the counts with `change` applied to the count of each id; a count that reaches zero is dropped
(define (shift-counts counts ids change)
  (for/fold ([counts counts]) ([id ids])
    (define n (change (hash-ref counts id 0)))
    (if (zero? n) (hash-remove counts id) (hash-set counts id n))))

;; Ballots String -> (or [Listof Id] #f)
;; the participant's chosen option ids, if they voted
(define (ballots-choice b participant) (hash-ref (ballots-choices b) participant #f))

;; Ballots Id -> Natural
;; how many participants chose the option
(define (ballots-tally b id) (hash-ref (ballots-counts b) id 0))

;; Ballots -> Natural
;; how many participants voted
(define (ballots-voters b) (hash-count (ballots-choices b)))

;; A PollRun is a (poll-run Id Id String Kind Time (or Time #f) [Listof Option] Ballots Boolean)
;; interp. one opening of a poll; options and addition permission are captured for this run.
(struct poll-run (id poll-id question kind opened-at closed-at options votes allow-additional?) #:transparent)

;; An OptionCount is an (option-count Id Natural String Natural)
;; interp. an option of a run's poll with the number of votes that chose it (zero included).
(struct option-count (id idx label count) #:transparent)

;; A RunResult is a (run-result Id Id (or Id #f) String Kind Time (or Time #f) Natural
;;                              (or Natural #f) (or Real #f) (or Natural #f) [Listof OptionCount])
;; interp. the outcome of one run: voters, the most audience connected while it was open, the median
;; seconds from opening to a voter's first vote, the voters who changed their answer (#f = not
;; recorded, for votes cast before engagement tracking), and the options in idx order.
(struct run-result (run-id poll-id slide question kind opened-at closed-at total-voters peak-audience
                           median-seconds changed-voters options)
  #:transparent)

;; A ResultsTotals is a (results-totals Natural (or Natural #f) (or Real #f) (or Natural #f) (or Natural #f))
;; interp. session-wide engagement: distinct voters, the session's peak audience, the median seconds to
;; first vote over all votes, and the answer changes made and the voters who made them (#f = not recorded).
(struct results-totals (unique-voters peak-audience median-seconds changed-votes changed-voters) #:transparent)

;; A SessionResults is a (session-results Session Presentation ResultsTotals [Listof RunResult])
;; interp. everything the results page shows; runs are oldest first.
(struct session-results (session presentation totals runs) #:transparent)

(module+ test
  (require rackunit)
  (define b1 (ballots-cast (ballots-cast empty-ballots "a" '(1)) "b" '(1)))

  (test-case "ballots-cast: a new voter, a changed vote and a multi-choice vote"
    (for ([row (list ;; before, participant, ids, expected choices, expected tallies of options 1 2 3
                (list empty-ballots "a" '(1)   (hash "a" '(1)) '(1 0 0))
                (list b1            "c" '(2)   (hash "a" '(1) "b" '(1) "c" '(2)) '(2 1 0))
                (list b1            "a" '(2)   (hash "a" '(2) "b" '(1)) '(1 1 0))
                (list b1            "a" '(1)   (hash "a" '(1) "b" '(1)) '(2 0 0))
                (list b1            "a" '(1 3) (hash "a" '(1 3) "b" '(1)) '(2 0 1))
                (list b1            "a" '(2 3) (hash "a" '(2 3) "b" '(1)) '(1 1 1)))])
      (match-define (list before who ids choices tallies) row)
      (define after (ballots-cast before who ids))
      (check-equal? (ballots-choices after) choices)
      (check-equal? (for/list ([id '(1 2 3)]) (ballots-tally after id)) tallies)
      (check-equal? (ballots-voters after) (hash-count choices))))

  (test-case "ballots: votes->ballots agrees with casting, unknown voters have no choice"
    (check-equal? (votes->ballots (list (vote "a" '(1)) (vote "b" '(1)))) b1)
    (check-equal? (votes->ballots '()) empty-ballots)
    (check-false (ballots-choice b1 "z"))
    (check-equal? (ballots-choice b1 "a") '(1))
    (check-equal? (ballots-cast (ballots-cast b1 "a" '(2)) "a" '(1)) b1)))
