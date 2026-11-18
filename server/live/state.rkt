#lang racket/base
;; Pure live-session state: transitions (step) and role-specific snapshots (project). No IO.
(require racket/contract/base racket/match racket/list racket/promise "../domain.rkt" "../qa.rkt" "snapshot.rkt")
(provide role/c
         (contract-out
          [initial-state (->* (session? presentation? (listof poll-run?) boolean? string? string?) (qa-state?) live?)]
          [step (-> live? event? live?)]
          [sync-needed? (-> live? event? boolean?)]
          [project (-> live? role/c string? snapshot?)]
          [projection? (-> any/c boolean?)]
          [project-all (-> live? projection?)]
          [project-for (-> projection? role/c string? snapshot?)]
          [event-affects (-> event? (listof role/c))]
          [all-roles (listof role/c)]
          [live-ended? (-> live? boolean?)]
          [live-slide (-> live? id/c)]
          [live-overlay (-> live? (or/c overlay/c #f))]
          [live-open-run (-> live? (or/c poll-run? #f))]
          [live-run-open? (-> live? boolean?)]
          [event? (-> any/c boolean?)]
          [struct live ([code string?] [screen-code string?] [label string?] [started-at time/c] [ended-at (or/c time/c #f)]
                        [presentation presentation?] [stage stage?] [runs (listof poll-run?)] [conns connections?]
                        [audience-url string?] [screen-url string?] [peaks peaks?] [qa qa-state?])]
          [struct peaks ([session natural-number/c] [run-id (or/c id/c #f)] [run natural-number/c])]
          [struct qa-synced ([qa qa-state?])]
          [struct run-updated ([run poll-run?])]
          [struct slide-set ([n id/c])]
          [struct run-opened ([run poll-run?] [revealed? boolean?])]
          [struct run-closed ([run poll-run?])]
          [struct run-resumed ([run poll-run?] [revealed? boolean?])]
          [struct run-synced ([runs (listof poll-run?)] [revealed? boolean?])]
          [struct run-revealed ()]
          [struct run-hidden ()]
          [struct overlay-set ([overlay (or/c overlay/c #f)])]
          [struct vote-cast ([run-id id/c] [participant string?] [option-ids (listof id/c)])]
          [struct lecture-ended ([at time/c])]
          [struct connections-changed ([audience natural-number/c] [screen natural-number/c])]))

;; A Live is a (live String String String Time (or Time #f) Presentation Stage [Listof PollRun]
;;                   Connections String String Peaks QaState)
;; interp. a session as the room sees it: what the screen shows (the Stage; whether results are
;; revealed lives inside the poll overlay, which names its run), the session's runs newest first and
;; the two public URLs. Runs are the one source of run data: the open run, the only one accepting
;; votes, is the head when it has no closed-at (see live-open-run); every other run is immutable
;; history that an overlay may show again.
(struct live (code screen-code label started-at ended-at presentation stage runs conns
                   audience-url screen-url peaks qa)
  #:transparent)

;; A Peaks is a (peaks Natural (or Id #f) Natural)
;; interp. the most audience connections at once in the session, and during run run-id while it was
;; open (the run's participation denominator); run-id is #f before any run, and stays on the last run
;; while it is closed, so resuming it continues its peak.
(struct peaks (session run-id run) #:transparent)

;; A Role is 'audience, 'screen, 'moderator or 'editor.
(define role/c (or/c 'audience 'screen 'moderator 'editor))

;; An Event is one of:
;;   (slide-set Id) (run-opened PollRun Boolean) (run-closed PollRun) (run-resumed PollRun Boolean) (run-synced [Listof PollRun] Boolean)
;;   (run-revealed) (run-hidden) (overlay-set (or Overlay #f))
;;   (vote-cast Id String [Listof Id]) (lecture-ended Time) (connections-changed Natural Natural)
;; A QaSynced is a (qa-synced QaState): authoritative persisted Q&A state.
(struct qa-synced (qa) #:transparent)
;; A RunUpdated is a (run-updated PollRun): a run whose options were extended.
(struct run-updated (run) #:transparent)
(struct slide-set (n) #:transparent)
;; interp. the Boolean of run-opened, run-resumed and run-synced: the (newest) run's results start revealed
(struct run-opened (run revealed?) #:transparent)
(struct run-closed (run) #:transparent)
(struct run-resumed (run revealed?) #:transparent)
(struct run-synced (runs revealed?) #:transparent)
(struct run-revealed () #:transparent)
(struct run-hidden () #:transparent)
(struct overlay-set (overlay) #:transparent)
(struct vote-cast (run-id participant option-ids) #:transparent)
(struct lecture-ended (at) #:transparent)
(struct connections-changed (audience screen) #:transparent)

;; Any -> Boolean
;; is x an Event?
(define (event? x)
  (or (qa-synced? x) (run-updated? x) (slide-set? x) (run-opened? x) (run-closed? x) (run-resumed? x) (run-synced? x) (run-revealed? x) (run-hidden? x) (overlay-set? x)
      (vote-cast? x) (lecture-ended? x) (connections-changed? x)))

;; Events come from concurrent requests, so they can reach the state out of order:
;; run-opened, run-closed and run-resumed carry the run as the database has it (authoritative), runs are
;; ordered by id, and an event about an older run than the current one is ignored.

;; [Listof PollRun] Boolean -> (or Overlay #f)
;; the overlay after a (re)load: the poll of the newest run when it is still open (results shown iff
;; revealed?), else none
(define (reloaded-overlay runs revealed?)
  (match runs
    [(cons run _) #:when (run-open? run) (poll-overlay (poll-run-id run) revealed?)]
    [_ #f]))

;; Session Presentation [Listof PollRun] Boolean String String [QaState] -> Live
;; the state of a session just loaded, nobody connected; runs are newest first and revealed? tells
;; whether the newest one's results were shown
(define (initial-state s pres runs revealed? audience-url screen-url [qa (qa-state #f #f #f #f '() #f)])
  (live (session-code s) (session-screen-code s) (session-label s) (session-started-at s) (session-ended-at s)
        pres (stage (session-current-slide s) (if (qa-state-on-screen? qa) (qa-overlay (qa-state-selected-id qa)) (reloaded-overlay runs revealed?))) runs (connections 0 0) audience-url screen-url
        (peaks 0 (and (pair? runs) (run-open? (car runs)) (poll-run-id (car runs))) 0) qa))

;; ------------------------------------------------------------------ accessors
;; Live -> Boolean
;; has the session ended?
(define (live-ended? st) (and (live-ended-at st) #t))

;; Live -> Id
(define (live-slide st) (stage-slide (live-stage st)))

;; Live -> (or Overlay #f)
(define (live-overlay st) (stage-overlay (live-stage st)))

;; Live (or Overlay #f) -> Live
(define (with-overlay st overlay) (struct-copy live st [stage (stage (live-slide st) overlay)]))

;; Live -> (or PollRun #f)
;; the run opened last, open or closed
(define (latest-run st) (match (live-runs st) [(cons run _) run] ['() #f]))

;; Live -> (or Id #f)
;; id of the current run
(define (latest-run-id st) (and (latest-run st) (poll-run-id (latest-run st))))

;; Live Id -> (or PollRun #f)
;; the session's run with this id, open or past
(define (find-run st id) (findf (λ (r) (equal? (poll-run-id r) id)) (live-runs st)))

;; Live PollRun -> Live
;; the state with the latest run replaced
(define (set-latest-run st run) (struct-copy live st [runs (cons run (cdr (live-runs st)))]))

;; Live PollRun -> Live
;; the state with the run of the same id replaced, wherever it is in the history
(define (replace-run st run)
  (struct-copy live st [runs (for/list ([r (live-runs st)]) (if (equal? (poll-run-id r) (poll-run-id run)) run r))]))

;; Live -> (or PollRun #f)
;; the open run: the only one accepting votes, and the only one the audience sees
(define (live-open-run st) (let ([run (latest-run st)]) (and run (run-open? run) run)))

;; Live -> Boolean
;; is a run open?
(define (live-run-open? st) (and (live-open-run st) #t))

;; PollRun -> Boolean
;; is the run still accepting votes?
(define (run-open? run) (not (poll-run-closed-at run)))

;; ------------------------------------------------------------------ transitions
;; [Listof Option] [Listof Id] -> [Listof Id]
;; the chosen ids in option order
(define (sorted-by-idx options ids)
  (for/list ([o options] #:when (memv (option-id o) ids)) (option-id o)))

;; PollRun String [Listof Id] -> PollRun
;; the run with the participant's vote recorded
(define (record-vote run participant ids)
  (struct-copy poll-run run
               [votes (ballots-cast (poll-run-votes run) participant (sorted-by-idx (poll-run-options run) ids))]))

;; Live Id String [Listof Id] -> Live
;; votes count on the latest run, open or closed: a vote committed before the close
;; may be applied after it; no past run ever changes
(define (cast st run-id participant ids)
  (if (equal? run-id (latest-run-id st))
      (set-latest-run st (record-vote (latest-run st) participant ids))
      st))

;; Live Time -> Live
;; closes the open run, if any
(define (close-run st at)
  (if (live-run-open? st)
      (set-latest-run st (struct-copy poll-run (latest-run st) [closed-at at]))
      st))

;; Live PollRun Boolean -> Live
;; opens a newer run (closing the open one, as the database did) and puts its poll overlay up;
;; a run that is already known or older changes nothing
(define (open-run st run revealed?)
  (if (> (poll-run-id run) (or (latest-run-id st) -1))
      (let ([closed (close-run st (poll-run-opened-at run))])
        (with-overlay (struct-copy live closed [runs (cons run (live-runs closed))])
                      (poll-overlay (poll-run-id run) revealed?)))
      st))

;; Live PollRun Boolean -> Live
;; the authoritative closed run replaces its earlier self (it holds every committed vote);
;; a newer run is adopted as by open-run; an unknown older one is ignored
(define (close-run-with st run revealed?)
  (if (find-run st (poll-run-id run))
      (replace-run st run)
      (open-run st run revealed?)))

;; Live PollRun Boolean -> Live
;; the authoritative reopened run replaces the latest one (open again, votes kept) and its poll
;; overlay goes up; a newer run is adopted as by open-run; an older one is ignored
(define (resume-run st run revealed?)
  (define latest (or (latest-run-id st) -1))
  (cond [(= (poll-run-id run) latest) (with-overlay (replace-run st run) (poll-overlay (poll-run-id run) revealed?))]
        [(> (poll-run-id run) latest) (open-run st run revealed?)]
        [else st]))

;; Live [Listof PollRun] Boolean -> Live
;; adopts the database's runs when they are at least as new as ours: they hold every committed vote
;; and every run, so the history is complete again. A newer current run puts its poll overlay up.
(define (adopt-runs st runs revealed?)
  (match runs
    [(cons run _) #:when (>= (poll-run-id run) (or (latest-run-id st) -1))
     (define newer? (> (poll-run-id run) (or (latest-run-id st) -1)))
     (struct-copy live (if newer? (with-overlay st (poll-overlay (poll-run-id run) revealed?)) st)
                  [runs runs])]
    [_ st]))

;; Live Boolean -> Live
;; shows or hides the results inside the poll overlay; without one nothing changes
(define (set-revealed st on?)
  (match (live-overlay st)
    [(poll-overlay id _) (with-overlay st (poll-overlay id on?))]
    [_ st]))

;; Live (or Overlay #f) -> Live
;; replaces the overlay; the poll overlay needs a run of this session to show
(define (show-overlay st overlay)
  (match overlay
    [(poll-overlay id _) #:when (not (find-run st id)) st]
    [_ (with-overlay st overlay)]))

;; Live Event -> Boolean
;; must the hub first adopt the database's view of the run (a run-synced event)? Events are
;; applied after their database commit but may overtake each other on the way to the hub:
;;  - a vote for a run newer than ours: its run-opened is still on the way. Dropping the vote
;;    would lose it from the live counts, so the hub reloads instead of guessing;
;;  - a run-opened for an older run we don't hold: it lost the race to a newer one, and
;;    only the database's run list puts it back into the history;
;;  - lecture-ended: it carries only a time, and the run it closes may be one we have not
;;    seen yet or lack late votes of. The end transaction waits for every vote in flight
;;    (they hold a share lock on the run), so the database then holds all of them.
;; Reloading is the simplest correct repair: the database is the one authority, and
;; adopting its run via close-run-with is idempotent and order-insensitive.
(define (sync-needed? st ev)
  (and (not (live-ended? st))
       (match ev
         [(vote-cast run-id _ _) (> run-id (or (latest-run-id st) -1))]
         [(run-opened run _) (and (not (find-run st (poll-run-id run)))
                                  (< (poll-run-id run) (or (latest-run-id st) -1)))]
         [(lecture-ended _) #t]
         [_ #f])))

;; Live Event -> Live
;; the next state, with the peak audiences kept up to date
(define (step st ev) (track-peaks (transition st ev)))

;; Live -> Live
;; raises the session's peak to the current audience, and the peak of the open run: a newer open run
;; starts from the audience present; a closed run's peak is frozen. Nothing changes once ended.
(define (track-peaks st)
  (define audience (connections-audience (live-conns st)))
  (match-define (peaks session run-id run) (live-peaks st))
  (define open (live-open-run st))
  (define open-id (and open (poll-run-id open)))
  (define new-peaks
    (cond [(not open-id) (peaks (max session audience) run-id run)]
          [(equal? open-id run-id) (peaks (max session audience) run-id (max run audience))]
          [else (peaks (max session audience) open-id audience)]))
  (if (live-ended? st) st (struct-copy live st [peaks new-peaks])))

;; Live Event -> Live
;; the next state; once ended only connection counts still change
(define (transition st ev)
  (match ev
    [(connections-changed a s) (struct-copy live st [conns (connections a s)])]
    [_ #:when (live-ended? st) st]
    [(slide-set n) (struct-copy live st [stage (stage n (live-overlay st))])]
    [(qa-synced qa) (adopt-qa st qa)]
    [(run-updated run) (replace-run st run)]
    [(run-opened run revealed?) (open-run st run revealed?)]
    [(run-closed run) (close-run-with st run #f)]
    [(run-resumed run revealed?) (resume-run st run revealed?)]
    [(run-synced runs revealed?) (adopt-runs st runs revealed?)]
    [(run-revealed) (set-revealed st #t)]
    [(run-hidden) (set-revealed st #f)]
    [(overlay-set overlay) (show-overlay st overlay)]
    [(vote-cast run-id participant ids) (cast st run-id participant ids)]
    [(lecture-ended at) (struct-copy live (close-run st at) [ended-at at] [qa (struct-copy qa-state (live-qa st) [open? #f])])]))

;; Live QaState -> Live
;; adopts the inbox and updates the projector only when Q&A owns its overlay.
(define (adopt-qa st qa)
  (define overlay
    (cond [(qa-state-on-screen? qa) (qa-overlay (qa-state-selected-id qa))]
          [(qa-overlay? (live-overlay st)) #f]
          [else (live-overlay st)]))
  (struct-copy live st [qa qa] [stage (stage (live-slide st) overlay)]))

;; ------------------------------------------------------------------ projections
;; PollRun -> [Listof Tally]
(define (tallies run)
  (for/list ([o (poll-run-options run)])
    (tally (option-id o) (option-label o) (ballots-tally (poll-run-votes run) (option-id o)) (option-exclusive? o))))

;; PollRun -> [Listof Choice]
(define (choices run) (for/list ([o (poll-run-options run)]) (choice (option-id o) (option-label o) (option-exclusive? o))))

;; PollRun -> Natural
(define (total-voters run) (ballots-voters (poll-run-votes run)))

;; Live -> SessionBrief
(define (session-part st) (session-brief (live-code st) (live-label st)))

;; Live -> DeckInfo
(define (deck-of st)
  (define p (live-presentation st))
  (deck-info (presentation-id p) (presentation-title p) (presentation-page-count p)))

;; PollRun -> AudiencePoll
(define (audience-poll-of run)
  (audience-poll (poll-run-id run) (poll-run-question run) (poll-run-kind run) (run-open? run) (choices run)))

;; PollRun Boolean -> [Listof ScreenOption]
;; the options with their counts, which stay hidden (#f) until revealed
(define (screen-options run revealed?)
  (for/list ([t (tallies run)])
    (screen-option (tally-id t) (tally-label t) (and revealed? (tally-count t)))))

;; PollRun Boolean -> ScreenPoll
(define (screen-poll-of run revealed?)
  (screen-poll (poll-run-id run) (poll-run-question run) (poll-run-kind run) (run-open? run) revealed?
               (screen-options run revealed?) (total-voters run)))

;; Live -> (or ScreenOverlay #f)
(define (screen-overlay-of st)
  (match (live-overlay st)
    [#f #f]
    [(qr-overlay) (qr-overlay)]
    [(qa-overlay id) (screen-qa (findf (λ (q) (equal? id (qa-question-id q))) (qa-state-questions (live-qa st))) (qa-state-open? (live-qa st)))]
    [(poll-overlay id revealed?) (let ([run (find-run st id)]) (and run (screen-poll-of run revealed?)))]))

;; PollRun -> RunSummary
(define (run-summary-of run)
  (run-summary (poll-run-id run) (poll-run-poll-id run) (poll-run-question run) (poll-run-kind run)
               (poll-run-opened-at run) (poll-run-closed-at run) (total-voters run)))

;; PollRun -> ModeratorOpenRun
(define (moderator-open-run-of run)
  (moderator-open-run (poll-run-id run) (poll-run-poll-id run) (poll-run-question run) (poll-run-kind run)
                  (poll-run-opened-at run) (tallies run) (total-voters run) (poll-run-allow-additional? run)))

;; Live String -> AudienceSnapshot
(define (audience-view st participant) (with-my-vote (audience-base st) (open-ballots st) participant))

;; Live -> AudienceSnapshot
;; what every audience member sees, without their own vote
(define (audience-base st)
  (define run (live-open-run st))
  (define p (live-presentation st))
  (audience-snapshot (session-part st) (deck-brief (presentation-id p) (presentation-title p))
                     (and run (audience-poll-of run)) #f (live-qa st)))

;; Live -> Ballots
;; the ballots of the open run, none without one
(define (open-ballots st)
  (define run (live-open-run st))
  (if run (poll-run-votes run) empty-ballots))

;; AudienceSnapshot Ballots String [[Listof QaQuestion]] -> AudienceSnapshot
;; the base with the participant's vote, which only exists while a poll is shown
(define (with-my-vote base ballots participant [questions #f])
  (struct-copy audience-snapshot base [my-vote (and (audience-snapshot-poll base) (ballots-choice ballots participant))]
               [qa (struct-copy qa-state (audience-snapshot-qa base)
                                [questions (or questions
                                               (filter (λ (q) (equal? participant (qa-question-participant q)))
                                                       (qa-state-questions (audience-snapshot-qa base))))])]))

;; Live -> ScreenSnapshot
(define (screen-view st)
  (screen-snapshot (session-part st) (deck-of st) (live-audience-url st)
                   (screen-stage (live-slide st) (screen-overlay-of st))))

;; Live -> ModeratorSnapshot
(define (moderator-view st)
  (define run (live-open-run st))
  (moderator-snapshot (moderator-session (live-code st) (live-screen-code st) (live-label st) (live-started-at st) (live-ended-at st))
                  (deck-of st) (live-audience-url st) (live-screen-url st) (live-conns st)
                  (live-stage st) (and run (moderator-open-run-of run)) (map run-summary-of (live-runs st)) (live-qa st)))

;; Live -> EditorSnapshot
;; only the current poll context, without projector credentials or moderation data.
(define (editor-view st)
  (define run (live-open-run st))
  (editor-snapshot (session-part st) (live-started-at st) (live-ended-at st) (deck-of st)
                   (live-audience-url st) (and run (moderator-open-run-of run))))

;; Live Role String -> Snapshot
;; what the subscriber of the given role ('audience 'screen 'moderator) sees
(define (project st role participant)
  (match role
    ['audience (audience-view st participant)]
    ['screen (screen-view st)]
    ['moderator (moderator-view st)]
    ['editor (editor-view st)]))

;; A Projection is a (projection (Promise AudienceSnapshot) (Promise ScreenSnapshot) (Promise ModeratorSnapshot)
;;                               (Promise EditorSnapshot) Ballots (Promise (Hash String [Listof QaQuestion])))
;; interp. what every role sees of one state, built once and on demand: the audience base lacks
;; the participant's vote, which comes from the open run's ballots.
(struct projection (audience screen moderator editor ballots questions))

;; QaState -> (Hash String [Listof QaQuestion])
;; indexes the inbox once per shared projection, rather than scanning it for every audience member.
(define (questions-by-participant qa)
  (for/hash ([group (group-by qa-question-participant (qa-state-questions qa))])
    (values (qa-question-participant (car group)) group)))

;; Live -> Projection
(define (project-all st)
  (projection (delay (audience-base st)) (delay (screen-view st)) (delay (moderator-view st)) (delay (editor-view st)) (open-ballots st)
              (delay (questions-by-participant (live-qa st)))))

;; Projection Role String -> Snapshot
;; same as project, from the shared projection
(define (project-for pr role participant)
  (match role
    ['audience (with-my-vote (force (projection-audience pr)) (projection-ballots pr) participant
                             (hash-ref (force (projection-questions pr)) participant '()))]
    ['screen (force (projection-screen pr))]
    ['moderator (force (projection-moderator pr))]
    ['editor (force (projection-editor pr))]))

;; [Listof Role]
(define all-roles '(audience screen moderator editor))

;; Event -> [Listof Role]
;; the roles whose snapshot the event can change (a vote: for the audience only the voter's own)
(define (event-affects ev)
  (match ev
    [(? connections-changed?) '(moderator)]
    [(or (? slide-set?) (? run-revealed?) (? run-hidden?) (? overlay-set?)) '(screen moderator)]
    [(or (? qa-synced?) (? run-updated?) (? vote-cast?) (? run-opened?) (? run-closed?) (? run-resumed?) (? run-synced?) (? lecture-ended?)) all-roles]))

(module+ test
  (require rackunit racket/runtime-path json "../http/json.rkt")
  (define-runtime-path fixtures "../../docs/api-fixtures")
  (define (fixture name) (call-with-input-file (build-path fixtures name) read-json))
  (define (js st role p) (snapshot->jsexpr (project st role p)))

  (define aud-url "https://orquelo.com/7/abcde23456")
  (define scr-url "https://orquelo.com/screen/7/vwxyz76543")
  (define sess (session 4 7 "abcde23456" "vwxyz76543" "Class A" 5 "2026-11-15T10:00:00.000Z" #f))
  (define pres (presentation 7 "Intro to HtDP" 42 "2026-11-15T09:00:00.000Z" #f))
  (define opts (list (option 101 0 "square" #f) (option 102 1 "random" #f) (option 103 2 "string-append" #f)))
  (define (run #:id [id 12] #:votes [votes '()] #:closed [closed #f])
    (poll-run id 3 "Which are pure functions?" "multi" "2026-11-15T10:20:00.000Z" closed opts (votes->ballots votes) #f))
  (define idle (initial-state sess pres '() #f aud-url scr-url))
  (define (st-with-run . evs) (for/fold ([s idle]) ([e (cons (run-opened (run) #f) evs)]) (step s e)))
  (define (cast-vote s p ids [id 12]) (step s (vote-cast id p ids)))
  (define (open-another s id) (step s (run-opened (run #:id id) #f)))

  ;; fixture population: 27 voters, counts 21/3/18; p0 voted [101 103]
  (define votes27
    (for/list ([i 27])
      (vote (format "p~a" i)
            (cond [(<= 21 i 23) '(102)]
                  [(>= i 24) '(103)]
                  [(<= i 2) '(101 103)]
                  [(<= i 5) '(101)]
                  [(<= i 17) '(101 103)]
                  [else '(101)]))))
  (define fixture-state
    (step (initial-state sess pres (list (run #:votes votes27)) #f aud-url scr-url) (connections-changed 28 1)))
  ;; field k of the moderator's open run / of the newest history entry / of the screen's overlay
  (define (open-js s k) (hash-ref (hash-ref (js s 'moderator "x") 'open_run) k))
  (define (newest-js s k) (hash-ref (car (hash-ref (js s 'moderator "x") 'runs)) k))
  (define (stage-js s role) (hash-ref (js s role "x") 'stage))
  (define (screen-overlay-js s) (hash-ref (stage-js s 'screen) 'overlay))
  (define (open-js-overlay s) (hash-ref (js s 'moderator "x") 'open_run))
  (define (counts-of o) (map (λ (x) (hash-ref x 'count)) (hash-ref o 'options)))

  (test-case "fixtures: exact projection of the contract examples"
    (define s (step fixture-state (run-revealed)))
    (check-equal? (js s 'audience "p0") (fixture "audience.json"))
    (check-equal? (js s 'audience "nobody") (fixture "audience-no-vote.json"))
    (check-equal? (js idle 'audience "p0") (fixture "audience-idle.json"))
    (check-equal? (js (step s (run-closed (run #:votes votes27 #:closed "2026-11-15T10:25:00.000Z"))) 'screen "p0") (fixture "screen.json"))
    (check-equal? (js fixture-state 'screen "x") (fixture "screen-unrevealed.json"))
    (check-equal? (js (step fixture-state (overlay-set (qr-overlay))) 'screen "x") (fixture "screen-qr.json"))
    (check-equal? (js fixture-state 'moderator "x") (fixture "moderator.json")))

  (test-case "idle state"
    (check-false (latest-run idle))
    (check-false (live-open-run idle))
    (check-equal? (js idle 'screen "p")
                  (hasheq 'session (hasheq 'code "abcde23456" 'label "Class A")
                          'presentation (hasheq 'id 7 'title "Intro to HtDP" 'page_count 42)
                          'join_url aud-url 'stage (hasheq 'slide 5 'overlay 'null)))
    (define a (js idle 'moderator "p"))
    (check-equal? (hash-ref a 'stage) (hasheq 'slide 5 'overlay 'null))
    (check-equal? (hash-ref a 'open_run) 'null)
    (check-equal? (hash-ref a 'runs) '()))

  (test-case "the screen depends only on the stage: slide and overlay change independently"
    (define s (step (step idle (overlay-set (qr-overlay))) (slide-set 9)))
    (check-equal? (live-slide s) 9)
    (check-equal? (live-overlay s) (qr-overlay))
    (check-equal? (stage-js s 'moderator) (hasheq 'slide 9 'overlay (hasheq 'type "qr")))
    (check-equal? (stage-js s 'screen) (hasheq 'slide 9 'overlay (hasheq 'type "qr")))
    (check-equal? (live-stage (step s (overlay-set #f))) (stage 9 #f)))

  (test-case "overlay-set: replaces, clears, and the poll overlay needs a run of this session"
    (check-false (live-overlay (step idle (overlay-set (poll-overlay 12 #f)))))
    (define s (st-with-run))
    (check-equal? (live-overlay s) (poll-overlay 12 #f))
    (check-equal? (live-overlay (step s (overlay-set (poll-overlay 99 #f)))) (poll-overlay 12 #f))
    (define qr (step s (overlay-set (qr-overlay))))
    (check-equal? (live-overlay qr) (qr-overlay))
    (check-equal? (live-overlay (step qr (overlay-set (poll-overlay 12 #t)))) (poll-overlay 12 #t))
    (check-false (live-overlay (step qr (overlay-set #f))))
    ;; what covers the slide never touches the runs
    (check-equal? (live-runs qr) (live-runs s)))

  (test-case "open: the run is the open one, the previous closes, the poll overlay goes up as told"
    (define s (step (step (st-with-run (run-revealed)) (overlay-set (qr-overlay))) (run-opened (run #:id 13) #f)))
    (check-equal? (latest-run-id s) 13)
    (check-equal? (poll-run-id (live-open-run s)) 13)
    (check-equal? (map poll-run-id (live-runs s)) '(13 12))
    (check-equal? (poll-run-closed-at (cadr (live-runs s))) (poll-run-opened-at (run #:id 13)))
    (check-equal? (live-overlay s) (poll-overlay 13 #f))
    (check-equal? (live-overlay (step s (run-opened (run #:id 14) #t))) (poll-overlay 14 #t)))

  (test-case "open of an already known run is a no-op"
    (define s (cast-vote (st-with-run (run-revealed)) "p1" '(101)))
    (check-equal? (step s (run-opened (run) #f)) s))

  (test-case "close: no run is open, the stage is unchanged, the run stays in the history"
    (define s (step (st-with-run (run-revealed)) (run-closed (run #:closed "2026-11-15T10:30:00.000Z"))))
    (check-false (live-run-open? s))
    (check-equal? (live-overlay s) (poll-overlay 12 #t))
    (check-equal? (hash-ref (js s 'moderator "x") 'open_run) 'null)
    (check-equal? (newest-js s 'closed_at) "2026-11-15T10:30:00.000Z")
    (check-equal? (hash-ref (screen-overlay-js s) 'open) #f))

;; the closed run 12 with p1's vote, then resumed
  (define voted-closed
    (step (cast-vote (st-with-run) "p1" '(101)) (run-closed (run #:votes (list (vote "p1" '(101))) #:closed "t"))))

  (test-case "resume: the latest run is open again with its votes, the poll overlay goes up as told"
    (define resumed (run #:votes (list (vote "p1" '(101)))))
    (define s (step (step voted-closed (overlay-set (qr-overlay))) (run-resumed resumed #t)))
    (check-true (live-run-open? s))
    (check-equal? (map poll-run-id (live-runs s)) '(12))
    (check-equal? (poll-run-votes (live-open-run s)) (votes->ballots (list (vote "p1" '(101)))))
    (check-equal? (live-overlay s) (poll-overlay 12 #t))
    (check-equal? (live-overlay (step voted-closed (run-resumed resumed #f))) (poll-overlay 12 #f))
    (check-equal? (hash-ref (js s 'audience "p1") 'my_vote) '(101))
    (check-equal? (hash-ref (hash-ref (js s 'audience "p1") 'poll) 'run_id) 12)
    (check-equal? (counts-of (open-js-overlay s)) '(1 0 0)))

  (test-case "resume: a run older than the latest is ignored; a newer one is adopted like an open"
    (define s (open-another voted-closed 13))
    (check-equal? (step s (run-resumed (run #:votes (list (vote "p1" '(101)))) #t)) s)
    (check-equal? (map poll-run-id (live-runs (step voted-closed (run-resumed (run #:id 14) #f)))) '(14 12)))

  (test-case "audience sees the open run only: nothing once it is closed, whatever the stage shows"
    (define s (cast-vote (st-with-run (run-revealed)) "p1" '(101)))
    (check-equal? (hash-ref (hash-ref (js s 'audience "p1") 'poll) 'run_id) 12)
    (define closed (step s (run-closed (run #:votes (list (vote "p1" '(101))) #:closed "t"))))
    (check-equal? (hash-ref (js closed 'audience "p1") 'poll) 'null)
    (check-equal? (hash-ref (js closed 'audience "p1") 'my_vote) 'null)
    (check-equal? (js closed 'audience "p1") (js idle 'audience "p1")
                  "same as having no run at all, except the session part which is equal")
    ;; an earlier run on the stage does not leak into the audience: it shows the open one
    (define two (cast-vote (open-another closed 13) "p2" '(102) 13))
    (check-equal? (hash-ref (hash-ref (js (step two (overlay-set (poll-overlay 12 #t))) 'audience "p2") 'poll) 'run_id) 13))

  (test-case "votes count on the latest run, open or closed, and nowhere else"
    (define s (cast-vote (st-with-run) "p1" '(101)))
    (check-equal? (hash-ref (js s 'audience "p1") 'my_vote) '(101))
    (check-equal? (step s (vote-cast 99 "p2" '(101))) s)
    (check-equal? (step idle (vote-cast 12 "p2" '(102))) idle)
    (define closed (step s (run-closed (struct-copy poll-run (latest-run s) [closed-at "t"]))))
    (check-equal? (newest-js (cast-vote closed "p2" '(102)) 'total_voters) 2))

  (test-case "a shown past run keeps its counts; votes on the open run move only the open run"
    (define s1 (cast-vote (st-with-run) "p1" '(101)))
    (define past (step s1 (run-closed (run #:votes (list (vote "p1" '(101))) #:closed "t"))))
    (define s (cast-vote (open-another past 13) "p2" '(102) 13))
    ;; the stage shows run 13; bring back run 12 and reveal it
    (define shown (step (step s (overlay-set (poll-overlay 12 #f))) (run-revealed)))
    (check-equal? (live-overlay shown) (poll-overlay 12 #t))
    (define o (screen-overlay-js shown))
    (check-equal? (hash-ref o 'run_id) 12)
    (check-equal? (counts-of o) '(1 0 0))
    (check-equal? (hash-ref o 'total_voters) 1)
    (check-equal? (hash-ref o 'open) #f)
    (define after (cast-vote shown "p3" '(103) 13))
    (check-equal? (screen-overlay-js after) o)
    ;; ... while the open run's own overlay does follow its votes
    (define live13 (step after (overlay-set (poll-overlay 13 #t))))
    (check-equal? (counts-of (screen-overlay-js live13)) '(0 1 1))
    (check-equal? (counts-of (screen-overlay-js (cast-vote live13 "p4" '(101) 13))) '(1 1 1)))

  (test-case "order: a late run-opened for an older run is ignored"
    (define s (step (st-with-run (run-revealed)) (run-opened (run #:id 13) #f)))
    (define s2 (step s (run-opened (run) #f)))
    (check-equal? s2 s)
    (check-equal? (latest-run-id s2) 13)
    (check-true (live-run-open? s2))
    (check-false (sync-needed? s (run-opened (run) #f)) "a known run needs no reload")
    (check-false (sync-needed? s (run-opened (run #:id 14) #f)) "a newer run is applied directly"))

  (test-case "order: a late run-opened for an older run we never saw triggers a reload"
    (define s (step idle (run-opened (run #:id 13) #f)))
    (check-true (sync-needed? s (run-opened (run) #f))))

  (test-case "order: a late run-closed for an unknown older run is ignored"
    (define s (step idle (run-opened (run #:id 13) #f)))
    (check-equal? (step s (run-closed (run #:id 11 #:closed "t"))) s))

  (test-case "order: run-closed carries the votes the hub missed"
    (define s (st-with-run))
    (define closed (step s (run-closed (run #:votes (list (vote "p1" '(101))) #:closed "t"))))
    (check-equal? (newest-js closed 'total_voters) 1)
    (check-false (live-run-open? closed)))

  (test-case "order: a vote applied after the close still counts, and the close then repeats it harmlessly"
    (define closed (step (st-with-run) (run-closed (run #:closed "t"))))
    (define voted (cast-vote closed "p1" '(101)))
    (check-equal? (newest-js voted 'total_voters) 1)
    (check-equal? (step voted (run-closed (run #:votes (list (vote "p1" '(101))) #:closed "t"))) voted))

  (test-case "order: run-closed before its run-opened adopts the run; the late open is a no-op"
    (define s (step idle (run-closed (run #:closed "t"))))
    (check-equal? (latest-run-id s) 12)
    (check-false (live-run-open? s))
    (check-equal? (step s (run-opened (run) #f)) s))

  (test-case "order: a vote for a newer run than ours needs a sync, and the sync adopts that run"
    (define s (st-with-run))
    (define newer (run #:id 13 #:votes (list (vote "p1" '(101)))))
    (check-true (sync-needed? s (vote-cast 13 "p1" '(101))))
    (check-false (sync-needed? s (vote-cast 12 "p1" '(101))))
    (check-false (sync-needed? s (vote-cast 11 "p1" '(101))))
    (check-true (sync-needed? idle (vote-cast 1 "p1" '(101))))
    (define synced (step (step s (run-synced (list newer (run #:closed "t")) #f)) (vote-cast 13 "p1" '(101))))
    (check-equal? (latest-run-id synced) 13)
    (check-equal? (map poll-run-id (live-runs synced)) '(13 12))
    (check-equal? (open-js synced 'total_voters) 1)
    (check-equal? (live-overlay synced) (poll-overlay 13 #f))
    (check-equal? (live-overlay (step (step idle (run-synced (list newer) #t)) (vote-cast 13 "p1" '(101)))) (poll-overlay 13 #t))
    ;; the late run-opened for the run adopted by the sync changes nothing
    (check-equal? (step synced (run-opened newer #f)) synced))

  (test-case "order: syncing replaces the runs with the database's; older or no runs change nothing"
    (define s (st-with-run))
    (define db-run (run #:votes (list (vote "p1" '(101))) #:closed "t"))
    (check-equal? (live-runs (step s (run-synced (list db-run) #f))) (list db-run))
    (check-equal? (step s (run-synced (list (run #:id 11)) #f)) s)
    (check-equal? (step s (run-synced '() #f)) s))

  (test-case "order: lecture-ended needs a sync; once ended nothing does"
    (define s (st-with-run))
    (check-true (sync-needed? s (lecture-ended "t")))
    (check-false (sync-needed? s (slide-set 2)))
    (define ended (step s (lecture-ended "t")))
    (check-false (sync-needed? ended (lecture-ended "t")))
    (check-false (sync-needed? ended (vote-cast 99 "p" '(1))))
    (check-equal? (step ended (run-synced (list (run #:id 13)) #f)) ended))

  (test-case "order: sync then lecture-ended ends on the run the end really closed, with its late votes"
    (define db-run (run #:id 13 #:votes (list (vote "p1" '(101))) #:closed "t"))
    (define ended (step (step (st-with-run) (run-synced (list db-run) #f)) (lecture-ended "t")))
    (check-equal? (latest-run-id ended) 13)
    (check-false (live-run-open? ended))
    (check-equal? (newest-js ended 'total_voters) 1))

  (test-case "vote replaces the participant's previous vote; my_vote is ordered by idx"
    (define s (cast-vote (cast-vote (st-with-run) "p1" '(101)) "p1" '(103 101)))
    (check-equal? (hash-ref (js s 'audience "p1") 'my_vote) '(101 103))
    (define s2 (cast-vote s "p1" '(102)))
    (check-equal? (map (λ (o) (hash-ref o 'count)) (open-js s2 'options)) '(0 1 0))
    (check-equal? (open-js s2 'total_voters) 1))

  (test-case "my_vote is per participant"
    (define s (cast-vote (cast-vote (st-with-run) "p1" '(101)) "p2" '(102)))
    (check-equal? (hash-ref (js s 'audience "p1") 'my_vote) '(101))
    (check-equal? (hash-ref (js s 'audience "p2") 'my_vote) '(102))
    (check-equal? (hash-ref (js s 'audience "p3") 'my_vote) 'null))

  (test-case "audience never sees counts or totals"
    (define s (step (cast-vote (st-with-run) "p1" '(101)) (run-revealed)))
    (check-false (regexp-match? #rx"count|total_voters" (jsexpr->string (js s 'audience "p1")))))

  (test-case "screen counts are null unless revealed; total_voters is always there; hide re-hides"
    (define s (cast-vote (st-with-run) "p1" '(101)))
    (define hidden (screen-overlay-js s))
    (check-equal? (hash-ref hidden 'type) "poll")
    (check-false (hash-ref hidden 'revealed))
    (check-equal? (hash-ref hidden 'total_voters) 1)
    (check-equal? (counts-of hidden) '(null null null))
    (define r (step s (run-revealed)))
    (check-true (hash-ref (screen-overlay-js r) 'revealed))
    (check-equal? (counts-of (screen-overlay-js r)) '(1 0 0))
    (check-equal? (hash-ref (stage-js r 'moderator) 'overlay) (hasheq 'type "poll" 'run_id 12 'revealed #t))
    (check-equal? (screen-overlay-js (step r (run-hidden))) hidden))

  (test-case "reveal and hide act only inside the poll overlay"
    (check-equal? (step idle (run-revealed)) idle)
    (check-equal? (step idle (run-hidden)) idle)
    (define qr (step (st-with-run) (overlay-set (qr-overlay))))
    (check-equal? (step qr (run-revealed)) qr)
    (check-equal? (step qr (run-hidden)) qr)
    (define r (step (st-with-run (run-revealed)) (overlay-set #f)))
    (check-equal? (step r (run-revealed)) r)
    (check-equal? (live-overlay (step r (overlay-set (poll-overlay 12 #t)))) (poll-overlay 12 #t)))

  (test-case "closing the run keeps the overlay; the slide changes underneath"
    (define s (step (st-with-run (run-revealed)) (run-closed (run #:closed "t"))))
    (check-false (live-run-open? s))
    (check-equal? (live-overlay s) (poll-overlay 12 #t))
    (check-equal? (live-overlay (step s (slide-set 3))) (poll-overlay 12 #t)))

  (test-case "reload: stage overlay is the open run's poll, revealed as persisted, else none"
    (define (reloaded runs revealed?) (live-stage (initial-state sess pres runs revealed? aud-url scr-url)))
    (check-equal? (reloaded '() #f) (stage 5 #f))
    (check-equal? (reloaded (list (run)) #f) (stage 5 (poll-overlay 12 #f)))
    (check-equal? (reloaded (list (run)) #t) (stage 5 (poll-overlay 12 #t)))
    (check-equal? (reloaded (list (run #:id 13 #:closed "t") (run)) #t) (stage 5 #f)))

  (test-case "the audience projection ignores overlays"
    (define s (cast-vote (st-with-run) "p1" '(101)))
    (for ([ev (list (overlay-set (qr-overlay)) (overlay-set #f) (run-revealed) (run-hidden) (slide-set 2))])
      (check-equal? (project (step s ev) 'audience "p1") (project s 'audience "p1"))))

  (test-case "moderator runs: history newest first"
    (define s (open-another (step (st-with-run) (run-closed (run #:votes (list (vote "p1" '(101))) #:closed "t"))) 13))
    (define rs (hash-ref (js s 'moderator "x") 'runs))
    (check-equal? (map (λ (r) (hash-ref r 'run_id)) rs) '(13 12))
    (check-equal? (map (λ (r) (hash-ref r 'total_voters)) rs) '(0 1))
    (check-equal? (hash-ref (cadr rs) 'closed_at) "t"))

  (test-case "end closes the run, marks ended and freezes the state"
    (define s (step (cast-vote (st-with-run) "p1" '(101)) (lecture-ended "2026-11-15T11:00:00.000Z")))
    (check-true (live-ended? s))
    (check-false (live-run-open? s))
    (check-equal? (hash-ref (hash-ref (js s 'moderator "x") 'session) 'ended_at) "2026-11-15T11:00:00.000Z")
    (check-equal? (step s (slide-set 1)) s)
    (check-equal? (step s (vote-cast 12 "p2" '(102))) s)
    (check-equal? (step s (run-opened (run) #f)) s)
    (check-equal? (newest-js s 'closed_at) "2026-11-15T11:00:00.000Z"))

  (test-case "connections update moderator only"
    (define s (step idle (connections-changed 3 2)))
    (check-equal? (hash-ref (js s 'moderator "x") 'connections) (hasheq 'audience 3 'screen 2))
    (check-equal? (project s 'audience "x") (project idle 'audience "x"))
    (check-equal? (project s 'screen "x") (project idle 'screen "x")))

  (define (audience n s) (step s (connections-changed n 0)))
  (define (peaks-of s) (let ([p (live-peaks s)]) (list (peaks-session p) (peaks-run-id p) (peaks-run p))))

  (test-case "peaks: the session peak ramps up and never drops; no run, no run peak"
    (define s (audience 2 (audience 9 (audience 4 idle))))
    (check-equal? (peaks-of s) '(9 #f 0)))
  (test-case "peaks: the open run follows the audience, a closed run is frozen"
    (define s (audience 5 (st-with-run)))
    (check-equal? (peaks-of s) '(5 12 5))
    (define closed (audience 8 (step (audience 7 s) (run-closed (run #:closed "t")))))
    (check-equal? (peaks-of closed) '(8 12 7)))
  (test-case "peaks: resuming a run continues its peak"
    (define closed (audience 3 (step (audience 7 (st-with-run)) (run-closed (run #:closed "t")))))
    (check-equal? (peaks-of (audience 4 (step closed (run-resumed (run) #f)))) '(7 12 7))
    (check-equal? (peaks-of (audience 9 (step closed (run-resumed (run) #f)))) '(9 12 9)))
  (test-case "peaks: a newer run starts from the audience present"
    (define s (audience 2 (audience 7 (st-with-run))))
    (check-equal? (peaks-of (open-another s 13)) '(7 13 2))
    (check-equal? (peaks-of (audience 5 (open-another s 13))) '(7 13 5)))
  (test-case "peaks: a reloaded session starts at zero, on its open run"
    (check-equal? (peaks-of (initial-state sess pres (list (run)) #f aud-url scr-url)) '(0 12 0)))
  (test-case "peaks: nothing changes once ended"
    (define s (step (audience 4 (st-with-run)) (lecture-ended "t")))
    (check-equal? (peaks-of (audience 9 s)) '(4 12 4)))

  (test-case "projections are valid jsexprs"
    (for ([role '(audience screen moderator)])
      (check-true (jsexpr? (js fixture-state role "p0")))))
  (test-case "event-affects: the roles each event can change"
    (define r (run))
    (for ([row (list (list (slide-set 2) '(screen moderator))
                     (list (overlay-set #f) '(screen moderator))
                     (list (run-revealed) '(screen moderator))
                     (list (run-hidden) '(screen moderator))
                     (list (connections-changed 1 1) '(moderator))
                     (list (vote-cast 12 "p" '(101)) all-roles)
                     (list (run-opened r #f) all-roles)
                     (list (run-closed r) all-roles)
                     (list (run-resumed r #f) all-roles)
                     (list (run-synced '() #f) all-roles)
                     (list (lecture-ended "t") all-roles))])
      (check-equal? (event-affects (car row)) (cadr row))))

  (test-case "the open run's ballots follow votes and runs"
    (define s (cast-vote (cast-vote (st-with-run) "p1" '(103 101)) "p2" '(102)))
    (define (choice-of s p) (ballots-choice (poll-run-votes (live-open-run s)) p))
    (check-equal? (list (choice-of s "p1") (choice-of s "p2")) '((101 103) (102)))
    (check-equal? (choice-of (cast-vote s "p1" '(102)) "p1") '(102))
    (check-equal? (cast-vote s "p1" '(102) 99) s) ; not the newest run
    (check-false (choice-of (open-another s 13) "p1"))
    (check-equal? (ballots-voters (poll-run-votes (live-open-run fixture-state))) 27)
    (check-false (live-open-run (step fixture-state (run-synced (list (run #:closed "t")) #f)))))

  (test-case "project-all agrees with project for every role"
    (define s (cast-vote fixture-state "p9" '(102)))
    (define pr (project-all s))
    (for* ([role all-roles] [p '("p0" "p9" "nobody")])
      (check-equal? (project-for pr role p) (project s role p))))
  (test-case "Q&A projections isolate authors, keep moderation private, and show only one question"
    (define q1 (qa-question 1 "First?" "pending" "t" "t" "p1"))
    (define q2 (qa-question 2 "Second?" "pending" "t" "t" "p2"))
    (define qa (qa-state #t #t #t 2 (list q1 q2) #t))
    (define st (step (st-with-run) (qa-synced qa)))
    (define pr (project-all st))
    (for ([participant '("p1" "p2" "stranger")])
      (check-equal? (project-for pr 'audience participant) (project st 'audience participant)))
    (check-true (live-run-open? st))
    (check-equal? (qa-state-questions (audience-snapshot-qa (project st 'audience "p1"))) (list q1))
    (check-equal? (qa-state-questions (audience-snapshot-qa (project st 'audience "stranger"))) '())
    (check-equal? (qa-state-questions (moderator-snapshot-qa (project st 'moderator "-"))) (list q1 q2))
    (define screen (hash-ref (hash-ref (js st 'screen "-") 'stage) 'overlay))
    (check-equal? (hash-ref screen 'question) (hasheq 'id 2 'text "Second?"))
    (check-false (regexp-match? #rx"First|participant" (jsexpr->string screen)))
    (check-false (hash-has-key? (hash-ref (js st 'audience "p1") 'qa) 'selected_question_id)))

  (test-case "editor projections expose the open run but no moderation data or projector credentials"
    (define qa (qa-state #t #t #t #f (list (qa-question 1 "Secret?" "pending" "t" "t" "p1")) #t))
    (define st (step (st-with-run) (qa-synced qa)))
    (define ed (js st 'editor "-"))
    (check-equal? (hash-ref (hash-ref ed 'session) 'screen_code) 'null)
    (for ([key '(stage screen_url connections qa)]) (check-equal? (hash-ref ed key) 'null))
    (check-equal? (hash-ref ed 'runs) '())
    (check-equal? (hash-ref (hash-ref ed 'open_run) 'run_id) 12)
    (check-false (regexp-match? #rx"Secret|vwxyz76543" (jsexpr->string ed))))

  (test-case "Q&A reload retains projector selection and ending closes submissions"
    (define qa (qa-state #t #t #t #f '() #t))
    (define st (initial-state sess pres (list (run)) #f aud-url scr-url qa))
    (check-equal? (live-overlay st) (qa-overlay #f))
    (define closed (step st (lecture-ended "later")))
    (check-false (qa-state-open? (live-qa closed)))
    (check-equal? (live-overlay (step st (qa-synced (struct-copy qa-state qa [on-screen? #f])))) #f))
)
