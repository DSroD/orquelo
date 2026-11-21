#lang racket/base
;; Live hub: one manager thread owns all session states and subscribers, so state
;; transitions are serialised. States are loaded lazily per session code via `load`, on the manager
;; thread: a slow database read in the loader (first use of a code, `sync!`) delays every session.
;; Subscribers get messages in a mailbox: a Queued Snapshot (a newer one replaces an unread one), or a
;; Queued 'ended once the session is over.
;; A subscriber only receives a snapshot when its own projection changed.
(require racket/contract/base racket/match racket/list racket/promise
         "../domain.rkt" "../qa.rkt" "../metrics/app.rkt" "state.rkt" "snapshot.rkt" "mailbox.rkt")
(provide hub?
         (contract-out
          [sub? (-> any/c boolean?)]
          [sub-mailbox (-> sub? mailbox?)]
          [struct hub-stats ([loaded natural-number/c] [live natural-number/c] [runs-open natural-number/c]
                             [audience natural-number/c] [screen natural-number/c] [moderator natural-number/c])]
          [make-hub (->* ((-> string? (or/c live? #f)))
                         (#:metrics app-metrics? #:record-peaks (-> string? peaks? any) #:flush-every (and/c real? positive?))
                         hub?)]
          [hub-stats-of (-> hub? hub-stats?)]
          [hub-manager (-> hub? thread?)]
          [hub-apply! (-> hub? string? event? (or/c live? #f))]
          [hub-state (-> hub? string? (or/c live? #f))]
          [hub-subscribe! (->* (hub? string? role/c string?) (#:audience-limit (or/c natural-number/c #f))
                               (or/c sub? 'full #f))]
          [hub-audience-present? (-> hub? string? string? boolean?)]
          [hub-report-screen-page! (-> hub? string? string? poll-overlay? boolean? screen-page? void?)]
          [hub-unsubscribe! (-> hub? string? sub? void?)]))

;; A Hub is a (hub Channel Thread [String -> (or Live #f)] AppMetrics [String Peaks -> Any]): the manager
;; thread's request channel, the manager thread, the loader, where the hub records its timings and where
;; it stores peak audiences.
(struct hub (requests manager load metrics record-peaks))
;; A HubStats is a (hub-stats Natural Natural Natural Natural Natural Natural)
;; interp. sessions loaded, sessions not ended, sessions with an open run, and the subscribers by role.
(struct hub-stats (loaded live runs-open audience screen moderator) #:transparent)
;; A Sub is a (sub Role String Mailbox Thread (or Snapshot #f) (or ScreenPage #f))
;; interp. a subscriber, its reader, the last snapshot sent and, for screens, its last measured page.
;; A killed owner never unsubscribes, so the hub drops subscribers whose owner is dead.
(struct sub (role participant mailbox owner [last #:mutable] [page #:auto #:mutable]) #:auto-value #f)
;; A Slot is a (slot Live (Hasheq Role (Hasheq Sub #t)) (Hash String [Listof Sub]) Peaks)
;; interp. a loaded session, its subscribers as a set per role (so counts are O(1)), the audience
;; subscribers by participant (a vote reaches only its voter) and the peaks last handed over for
;; storing (flushed); the session has unflushed peaks when they differ from the live ones.
(struct slot ([st #:mutable] subs voters [flushed #:mutable]))

;; -> (Hasheq Role (Hasheq Sub #t))
;; an empty set of subscribers per role
(define (make-role-sets) (for/hasheq ([r all-roles]) (values r (make-hasheq))))

;; Slot Role -> [Listof Sub]
(define (role-subs s role) (hash-keys (hash-ref (slot-subs s) role)))

;; Slot Role -> Natural
(define (role-count s role) (hash-count (hash-ref (slot-subs s) role)))

;; Slot -> [Listof Sub]
(define (all-subs s) (append-map (λ (r) (role-subs s r)) all-roles))

;; Slot Sub -> Boolean
(define (subscribed? s sb) (hash-has-key? (hash-ref (slot-subs s) (sub-role sb)) sb))

;; Slot Sub -> Void
(define (add-sub! s sb)
  (hash-set! (hash-ref (slot-subs s) (sub-role sb)) sb #t)
  (when (eq? (sub-role sb) 'audience)
    (hash-update! (slot-voters s) (sub-participant sb) (λ (l) (cons sb l)) '())))

;; Slot Sub -> Void
(define (remove-sub! s sb)
  (hash-remove! (hash-ref (slot-subs s) (sub-role sb)) sb)
  (when (eq? (sub-role sb) 'audience)
    (define left (remq sb (hash-ref (slot-voters s) (sub-participant sb) '())))
    (if (null? left) (hash-remove! (slot-voters s) (sub-participant sb)) (hash-set! (slot-voters s) (sub-participant sb) left))))

;; Slot -> Void
(define (clear-subs! s)
  (for ([sb (all-subs s)]) (remove-sub! s sb)))

;; -> Real
;; the monotonic clock in milliseconds
(define (now-ms) (current-inexact-monotonic-milliseconds))

;; [String -> (or Live #f)] [#:metrics AppMetrics] [#:record-peaks [String Peaks -> Any]] [#:flush-every Real] -> Hub
;; starts the manager thread, which owns the cache of slots by session code, and a ticker thread that
;; stores changed peak audiences every flush-every seconds (a busy room must not cause an UPDATE per connection)
(define (make-hub load #:metrics [metrics (make-app-metrics)] #:record-peaks [record-peaks void] #:flush-every [flush-every 10])
  (define requests (make-channel))
  (define cache (make-hash))
  (define manager (thread (λ () (let loop () ((channel-get requests) cache) (loop)))))
  (define h (hub requests manager load metrics record-peaks))
  (thread (λ () (let loop () (sleep flush-every) (tick-once! h) (loop))))
  h)

;; Hub -> Void
;; sweeps the dead subscribers and stores the changed peaks; a failure is logged, so that the ticker
;; thread survives it
(define (tick-once! h)
  (with-handlers ([exn:fail? (λ (e) (log-error "hub tick failed: ~a" (exn-message e)))])
    (store-peaks! h (call h (λ (cache) (tick h cache))))))

;; Slot -> Boolean
;; has the session peaks not stored yet?
(define (dirty? s) (not (equal? (live-peaks (slot-st s)) (slot-flushed s))))

;; String Slot -> [Listof (Pair String Peaks)]
;; the session's unflushed peaks (if any), now counted as flushed
(define (take-dirty! code s)
  (cond [(dirty? s) (set-slot-flushed! s (live-peaks (slot-st s))) (list (cons code (live-peaks (slot-st s))))]
        [else '()]))

;; Hash -> [Listof (Pair String Peaks)]
;; the unflushed peaks of every loaded session
(define (dirty-peaks cache)
  (for*/list ([(code s) (in-hash cache)] [d (take-dirty! code s)]) d))

;; Hub Hash -> [Listof (Pair String Peaks)]
;; one tick of the ticker: drops the dead subscribers of every session, then takes the unflushed peaks
(define (tick h cache)
  (for ([s (in-hash-values cache)]) (sweep-dead! h s))
  (dirty-peaks cache))

;; Hub [Listof (Pair String Peaks)] -> Void
;; stores the peaks. Runs outside the manager thread, so slow peak writes never stall the hub (loading
;; sessions does, see the top of this file); a failure is logged and the next change of that session's peaks stores them again.
(define (store-peaks! h dirty)
  (for ([d dirty])
    (with-handlers ([exn:fail? (λ (e) (log-error "storing peak audience of ~a failed: ~a" (car d) (exn-message e)))])
      ((hub-record-peaks h) (car d) (cdr d)))))

;; -> Void
;; raises the error of a call on a hub whose manager thread is gone
(define (raise-manager-dead) (error 'hub "the manager thread is dead"))

;; Hub [Hash -> X] -> X
;; runs (f cache) on the manager thread; its exceptions are re-raised in the caller.
;; The round trip, queue wait included, is recorded as hub call time.
(define (call h f)
  (define t0 (now-ms))
  ;; a one-shot reply (a box and a semaphore) never blocks the manager, even when the caller was
  ;; killed while waiting, and unlike an async-channel it needs no thread of its own
  (define reply (box #f))
  (define ready (make-semaphore 0))
  (define manager-dead (handle-evt (thread-dead-evt (hub-manager h)) (λ (_) (raise-manager-dead))))
  (sync (channel-put-evt (hub-requests h)
                         (λ (cache)
                           (set-box! reply (with-handlers ([exn:fail? (λ (e) (cons 'err e))]) (cons 'ok (f cache))))
                           (semaphore-post ready)))
        manager-dead)
  (sync ready manager-dead)
  (match-define (cons tag v) (unbox reply))
  (observe-hub-call! (hub-metrics h) (/ (- (now-ms) t0) 1000.0))
  (if (eq? tag 'ok) v (raise v)))

;; Hub Hash String -> (or Slot #f)
;; the slot for the code, loading its state on first use
(define (find-slot h cache code)
  (or (hash-ref cache code #f)
      (let ([st ((hub-load h) code)])
        (and st (let ([s (slot st (make-role-sets) (make-hash) (live-peaks st))]) (hash-set! cache code s) s)))))

;; ------------------------------------------------------------------ push
;; Sub (or Snapshot 'ended) -> Void
;; queues the message for the subscriber, stamped with the time
(define (enqueue! sb msg) (mailbox-put! (sub-mailbox sb) (queued msg (now-ms))))

;; Slot Role Event -> [Listof Sub]
;; the subscribers of the role the event can change: a vote reaches only its voter among the audience
(define (targets s role ev)
  (match* (role ev)
    [('audience (vote-cast _ participant _)) (hash-ref (slot-voters s) participant '())]
    [(_ _) (role-subs s role)]))

;; Sub Snapshot -> Boolean
;; queues the snapshot unless the subscriber already has it; was it sent?
(define (send-if-changed! sb snap)
  (define changed? (not (equal? snap (sub-last sb))))
  (when changed?
    (set-sub-last! sb snap)
    (enqueue! sb snap))
  changed?)

;; Slot -> [Listof ScreenPage]
;; the distinct pages being projected, ordered so unchanged views compare equal.
(define (screen-pages s)
  (define pages (remove-duplicates (filter-map sub-page (role-subs s 'screen))))
  (sort (sort pages < #:key screen-page-number) < #:key screen-page-total))

;; Live -> (or #f (List PollOverlay Boolean))
;; identifies the displayed poll and whether viewers can vote on it.
(define (poll-view st)
  (match (live-overlay st)
    [(and overlay (poll-overlay id _))
     (define open (live-open-run st))
     (list overlay (and open (= id (poll-run-id open))))]
    [_ #f]))

;; Hub Slot (or Event #f) [Listof Role] -> Void
;; sends the subscribers of the roles the event affects their snapshot, if it changed.
;; Records the snapshots sent and suppressed per role.
(define (push-roles! h s ev roles)
  (define pr (project-all (slot-st s)))
  (define moderator
    (delay (struct-copy moderator-snapshot (project-for pr 'moderator "") [screen-pages (screen-pages s)])))
  (for ([role roles])
    (define subs (targets s role ev))
    (define sent
      (for/sum ([sb subs])
        (define snap (if (eq? role 'moderator) (force moderator) (project-for pr role (sub-participant sb))))
        (if (send-if-changed! sb snap) 1 0)))
    (count-messages! (hub-metrics h) role sent (- (length subs) sent))))

;; Slot -> Void
;; the session is over: tells every subscriber and drops them all
(define (end-subs! s)
  (for ([sb (all-subs s)]) (enqueue! sb 'ended))
  (clear-subs! s))

;; Hub Slot Event -> Void
;; pushes what the event changed; on an ended session everyone gets the final snapshot, then 'ended.
;; Records the push time.
(define (push! h s ev)
  (define t0 (now-ms))
  (define ended? (live-ended? (slot-st s)))
  (push-roles! h s ev (if ended? all-roles (event-affects ev)))
  (when ended? (end-subs! s))
  (observe-push! (hub-metrics h) (/ (- (now-ms) t0) 1000.0)))

;; Hub Slot -> Void
;; tells the state how many audience and screen subscribers there are, and pushes that to the moderators
(define (sync-connections! h s)
  (define ev (connections-changed (role-count s 'audience) (role-count s 'screen)))
  (set-slot-st! s (step (slot-st s) ev))
  (push! h s ev))

;; Hub String String PollOverlay Boolean ScreenPage -> Void
;; accepts a measurement for the current poll from a connected projector only.
(define (hub-report-screen-page! h code viewer overlay open? page)
  (call h (λ (cache)
            (define s (hash-ref cache code #f))
            (when (and s (equal? (poll-view (slot-st s)) (list overlay open?)))
              (define matching
                (filter (λ (sb) (and (equal? viewer (sub-participant sb))
                                     (not (thread-dead? (sub-owner sb)))
                                     (not (equal? page (sub-page sb)))))
                        (role-subs s 'screen)))
              (unless (null? matching)
                (for ([sb matching]) (set-sub-page! sb page))
                (push-roles! h s #f '(moderator)))))))

;; Hub Slot -> Void
;; drops the subscribers whose thread died (they never unsubscribe), pushing the new counts if any went
(define (sweep-dead! h s)
  (define dead (filter (λ (sb) (thread-dead? (sub-owner sb))) (all-subs s)))
  (unless (null? dead)
    (for-each (λ (sb) (remove-sub! s sb)) dead)
    (sync-connections! h s)))

;; Hub Slot String -> Void
;; adopts the database's current run for the session (see sync-needed?)
(define (sync! h s code)
  (define fresh ((hub-load h) code))
  (when fresh
    (define revealed? (match (live-overlay fresh) [(poll-overlay _ r) r] [_ #f]))
    (set-slot-st! s (step (slot-st s) (run-synced (live-runs fresh) revealed?)))))

;; Hub Slot String Event -> Event
;; reloads mutable Q&A/options after commit, so requests arriving out of order cannot lose newer data.
(define (authoritative-event h s code ev)
  (cond
    [(or (qa-synced? ev) (run-updated? ev))
     (define fresh ((hub-load h) code))
     (cond [(not fresh) ev]
           [(qa-synced? ev) (qa-synced (live-qa fresh))]
           [else
            (define revealed? (match (live-overlay fresh) [(poll-overlay _ r) r] [_ #f]))
            (run-synced (live-runs fresh) revealed?)])]
    [else ev]))

;; Hub Slot String -> Void
;; reconciles persisted Q&A projector ownership after a competing projector mutation.
(define (sync-qa-overlay! h s code)
  (define fresh ((hub-load h) code))
  (when fresh (set-slot-st! s (step (slot-st s) (qa-synced (live-qa fresh))))))

;; ------------------------------------------------------------------ api
;; Event -> Boolean
;; does the event end or start a run's peak (or end the session), so its peaks are stored right away?
(define (peak-boundary? ev) (or (run-opened? ev) (run-closed? ev) (run-resumed? ev) (lecture-ended? ev)))

;; Hub String Event -> (or Live #f)
;; applies the event; the new state, or #f when the session does not exist.
;; Around a peak boundary the peaks are stored too: those of before the event, which a new run would
;; reset, and of after it.
(define (hub-apply! h code event)
  (define boundary? (peak-boundary? event))
  (define-values (st dirty)
    (apply values
           (call h (λ (cache)
                     (define s (find-slot h cache code))
                     (cond [(not s) (list #f '())]
                           [else
                            (define before (if boundary? (take-dirty! code s) '()))
                            (define previous-view (poll-view (slot-st s)))
                            (define applied (authoritative-event h s code event))
                            (define synced? (and (sync-needed? (slot-st s) applied) (begin (sync! h s code) #t)))
                            ;; an adopted database run can change any role, so push as for a run-synced
                            (set-slot-st! s (step (slot-st s) applied))
                            (when (or (overlay-set? applied) (run-opened? applied) (run-resumed? applied))
                              (sync-qa-overlay! h s code))
                            (unless (equal? previous-view (poll-view (slot-st s)))
                              (for ([sb (role-subs s 'screen)]) (set-sub-page! sb #f)))
                            (push! h s (if synced? (run-synced '() #f) applied))
                            (list (slot-st s) (append before (if boundary? (take-dirty! code s) '())))])))))
  (store-peaks! h dirty)
  st)

;; Hub -> HubStats
;; a consistent count of the loaded sessions and their subscribers
(define (hub-stats-of h)
  (call h (λ (cache)
            (define slots (hash-values cache))
            (hub-stats (length slots)
                       (count (λ (s) (not (live-ended? (slot-st s)))) slots)
                       (count (λ (s) (and (live-open-run (slot-st s)) #t)) slots)
                       (for/sum ([s slots]) (role-count s 'audience)) (for/sum ([s slots]) (role-count s 'screen))
                       (for/sum ([s slots]) (role-count s 'moderator))))))

;; Hub String -> (or Live #f)
(define (hub-state h code)
  (call h (λ (cache) (let ([s (find-slot h cache code)]) (and s (slot-st s))))))

;; Hub Slot Sub -> Void
;; gives the subscriber its snapshot, and registers it unless the session is over, when it is told so
(define (admit! h s sb)
  (define (send-snapshot!) (send-if-changed! sb (project (slot-st s) (sub-role sb) (sub-participant sb))))
  (cond [(live-ended? (slot-st s)) (send-snapshot!) (enqueue! sb 'ended)]
        [else (add-sub! s sb) (sync-connections! h s) (unless (eq? (sub-role sb) 'moderator) (send-snapshot!))]))

;; Slot String Natural -> Boolean
;; whether this participant needs a new seat and none are available
(define (audience-full? s participant limit)
  (and (not (live-ended? (slot-st s)))
       (not (hash-has-key? (slot-voters s) participant))
       (>= (hash-count (slot-voters s)) limit)))

;; Hub String Role String [#:audience-limit (or Natural #f)] -> (or Sub 'full #f)
;; registers a subscriber with a snapshot, or returns 'full at capacity or #f for an unknown session.
(define (hub-subscribe! h code role participant #:audience-limit [limit #f])
  (define owner (current-thread))
  (call h (λ (cache)
            (define s (find-slot h cache code))
            (cond
              [(not s) #f]
              [else
               (when (and limit (eq? role 'audience) (audience-full? s participant limit))
                 (sweep-dead! h s))
               (cond
                 [(and limit (eq? role 'audience) (audience-full? s participant limit)) 'full]
                 [else
                  (define sb (sub role participant (make-mailbox) owner #f))
                  (admit! h s sb)
                  sb])]))))

;; Hub String String -> Boolean
;; whether the participant has an active audience stream in the session
(define (hub-audience-present? h code participant)
  (call h (λ (cache)
            (define s (hash-ref cache code #f))
            (and s (for/or ([sb (hash-ref (slot-voters s) participant '())])
                     (not (thread-dead? (sub-owner sb))))))))

;; Hub String Sub -> Void
(define (hub-unsubscribe! h code sb)
  (call h (λ (cache)
            (define s (hash-ref cache code #f))
            (when (and s (subscribed? s sb))
              (remove-sub! s sb)
              (sync-connections! h s)))))

(module+ testing (provide sub)) ; the constructor, for tests of other modules

(module+ test
  (require rackunit racket/runtime-path json "../http/json.rkt" "../metrics/registry.rkt")
  (define (a-session code label) (session 1 7 code "zzzzzzzzzz" label 1 "t" #f))
  (define sess (a-session "abcde23456" "A"))
  (define pres (presentation 7 "T" 5 "t" #f))
  (define opts (list (option 1 0 "x" #f) (option 2 1 "y" #f)))
  (define run (poll-run 12 3 "Q" "single" "t" #f opts empty-ballots #f))
  (define loads 0)
  (define (load code)
    (set! loads (add1 loads))
    (and (equal? code "abcde23456") (initial-state sess pres '() #f "http://a" "http://s")))
  (define (drain sb) (map queued-message (or (sync/timeout 0.05 (sub-mailbox sb)) '())))
  (define (snapshots ms) (filter (λ (m) (not (eq? m 'ended))) ms))
  (define-runtime-path pages-fixture "../../docs/api-fixtures/screen-pages.json")

  (test-case "moderators see measured pages while their projector streams and poll view match"
    (define h (make-hub load))
    (define code "abcde23456")
    (define a (hub-subscribe! h code 'screen "first"))
    (define b (hub-subscribe! h code 'screen "second"))
    (define adm (hub-subscribe! h code 'moderator "-"))
    (define (pages) (hash-ref (snapshot->jsexpr (sub-last adm)) 'screen_pages #f))
    (define (report viewer page total [open? #t])
      (hub-report-screen-page! h code viewer (poll-overlay 12 #f) open? (screen-page page total)))
    (hub-apply! h code (run-opened run #f))
    (drain a)
    (report "unknown" 2 2)
    (report "first" 1 3 #f)
    (check-false (pages))
    (report "second" 2 4)
    (report "first" 1 3)
    (check-equal? (pages) (call-with-input-file pages-fixture read-json))
    (check-equal? (drain a) '())
    (hub-unsubscribe! h code b)
    (check-equal? (pages) (list (hasheq 'page 1 'total 3)))
    (hub-apply! h code (run-closed (struct-copy poll-run run [closed-at "t"])))
    (report "first" 2 3)
    (check-false (pages))
    (report "first" 1 3 #f)
    (check-equal? (pages) (list (hasheq 'page 1 'total 3)))
    (hub-apply! h code (overlay-set (qr-overlay)))
    (check-false (pages)))

  (test-case "metrics: pushes, messages and calls are recorded; stats count subscribers"
    (define m (make-app-metrics))
    (define h (make-hub load #:metrics m))
    (define a1 (hub-subscribe! h "abcde23456" 'audience "p1"))
    (define adm (hub-subscribe! h "abcde23456" 'moderator "-"))
    (hub-apply! h "abcde23456" (run-opened run #f))
    (hub-apply! h "abcde23456" (vote-cast 12 "p1" '(1)))
    (hub-apply! h "abcde23456" (vote-cast 12 "p1" '(1))) ; changes nothing: suppressed
    (check-equal? (hub-stats-of h) (hub-stats 1 1 1 1 0 1))
    (define out (render (app-metrics-registry m)))
    (check-regexp-match #rx"orquelo_sse_messages_total{role=\"audience\",kind=\"suppressed\"} [1-9]" out)
    (check-regexp-match #rx"orquelo_sse_messages_total{role=\"moderator\",kind=\"sent\"} [1-9]" out)
    (check-regexp-match #rx"orquelo_hub_push_seconds_count [1-9]" out)
    (check-regexp-match #rx"orquelo_hub_call_seconds_count [1-9]" out)
    (check-true (andmap queued? (sync/timeout 1 (sub-mailbox a1)))))

  ;; a recorder that keeps what it was given, newest first
  (define (recording) (let ([b (box '())]) (values b (λ (code p) (set-box! b (cons (cons code p) (unbox b)))))))

  (test-case "the ticker stores changed peaks, once"
    (define-values (stored record) (recording))
    (define h (make-hub load #:record-peaks record #:flush-every 0.05))
    (define a1 (hub-subscribe! h "abcde23456" 'audience "p1"))
    (define a2 (hub-subscribe! h "abcde23456" 'audience "p2"))
    (sleep 0.3)
    (check-equal? (unbox stored) (list (cons "abcde23456" (peaks 2 #f 0))))
    (hub-unsubscribe! h "abcde23456" a2)
    (sleep 0.3)
    (check-equal? (length (unbox stored)) 1))

  (test-case "run boundaries and the end store peaks at once, the old run's before a new run resets them"
    (define-values (stored record) (recording))
    (define h (make-hub load #:record-peaks record))
    (hub-subscribe! h "abcde23456" 'audience "p1")
    (hub-subscribe! h "abcde23456" 'audience "p2")
    (hub-apply! h "abcde23456" (run-opened run #f))
    (check-equal? (reverse (unbox stored)) (list (cons "abcde23456" (peaks 2 #f 0)) (cons "abcde23456" (peaks 2 12 2))))
    (hub-apply! h "abcde23456" (run-opened (struct-copy poll-run run [id 13]) #f))
    (check-equal? (car (unbox stored)) (cons "abcde23456" (peaks 2 13 2)))
    (hub-apply! h "abcde23456" (lecture-ended "2026-11-15T11:00:00.000Z"))
    (check-equal? (length (unbox stored)) 3))

  (test-case "a failing recorder is survived"
    (define h (make-hub load #:record-peaks (λ (code p) (error "db down")) #:flush-every 0.05))
    (hub-subscribe! h "abcde23456" 'audience "p1")
    (sleep 0.2)
    (check-equal? (live-slide (hub-state h "abcde23456")) 1)
    (check-true (live? (hub-apply! h "abcde23456" (run-opened run #f)))))

  (test-case "a failing tick is survived: the ticker keeps sweeping"
    (define h (make-hub load #:flush-every 0.05))
    (define (admit-audience!) ; a subscriber whose thread dies at once
      (define t (thread void))
      (thread-wait t)
      (call h (λ (cache) (add-sub! (find-slot h cache "abcde23456") (sub 'audience "p" (make-mailbox) t #f)))))
    (hub-subscribe! h "abcde23456" 'audience "live")
    ;; a moderator that cannot be pushed to: sweeping a dead subscriber raises after removing it
    (call h (λ (cache) (add-sub! (find-slot h cache "abcde23456") (sub 'moderator "-" 'not-a-channel (current-thread) #f))))
    (admit-audience!)
    (sleep 0.2)
    (admit-audience!)
    (sleep 0.2)
    (check-equal? (hub-stats-audience (hub-stats-of h)) 1))

  (test-case "calls on a hub whose manager is dead raise instead of hanging"
    (define h (make-hub load))
    (kill-thread (hub-manager h))
    (check-exn #rx"manager thread is dead" (λ () (hub-state h "abcde23456"))))

  (test-case "audience capacity counts identities and releases the last connection"
    (define h (make-hub load))
    (define code "abcde23456")
    (define (join participant) (hub-subscribe! h code 'audience participant #:audience-limit 1))
    (define first (join "p1"))
    (define second (join "p1"))
    (check-true (sub? first))
    (check-true (sub? second))
    (check-true (sub? (hub-subscribe! h code 'screen "screen" #:audience-limit 1)))
    (check-eq? (join "p2") 'full)
    (hub-unsubscribe! h code first)
    (check-true (hub-audience-present? h code "p1"))
    (check-eq? (join "p2") 'full)
    (hub-unsubscribe! h code second)
    (check-false (hub-audience-present? h code "p1"))
    (check-true (sub? (join "p2"))))

  (test-case "unknown session"
    (define h (make-hub load))
    (check-false (hub-apply! h "zzzzzzzzzz" (run-visibility-set 12 #f)))
    (check-false (hub-subscribe! h "zzzzzzzzzz" 'audience "p")))

  (test-case "lazy load happens once per code"
    (set! loads 0)
    (define h (make-hub load))
    (hub-apply! h "abcde23456" (slide-set 2))
    (hub-apply! h "abcde23456" (slide-set 3))
    (check-equal? loads 1)
    (check-equal? (live-slide (hub-state h "abcde23456")) 3))

  (test-case "subscribe sends an immediate snapshot"
    (define h (make-hub load))
    (define sb (hub-subscribe! h "abcde23456" 'audience "p1"))
    (define ms (drain sb))
    (check-equal? (length ms) 1)
    (check-equal? (car ms) (project (hub-state h "abcde23456") 'audience "p1")))

  (test-case "diff suppression: other participants' votes send nothing to an audience member"
    (define h (make-hub load))
    (define a1 (hub-subscribe! h "abcde23456" 'audience "p1"))
    (define a2 (hub-subscribe! h "abcde23456" 'audience "p2"))
    (define adm (hub-subscribe! h "abcde23456" 'moderator "-"))
    (hub-apply! h "abcde23456" (run-opened run #f))
    (drain a1) (drain a2) (drain adm)
    (hub-apply! h "abcde23456" (vote-cast 12 "p2" '(1)))
    (check-equal? (drain a1) '())
    (check-equal? (length (drain a2)) 1)
    (check-equal? (length (drain adm)) 1)
    ;; same vote again: nothing changes anywhere
    (hub-apply! h "abcde23456" (vote-cast 12 "p2" '(1)))
    (check-equal? (drain a2) '())
    (check-equal? (drain adm) '()))

  (test-case "connections are tracked and pushed to moderator"
    (define h (make-hub load))
    (define adm (hub-subscribe! h "abcde23456" 'moderator "-"))
    (define a (hub-subscribe! h "abcde23456" 'audience "p1"))
    (check-equal? (connections-audience (moderator-snapshot-connections (last (snapshots (drain adm))))) 1)
    (hub-unsubscribe! h "abcde23456" a)
    (check-equal? (connections-audience (moderator-snapshot-connections (last (snapshots (drain adm))))) 0)
    (hub-unsubscribe! h "abcde23456" a)
    (check-equal? (drain adm) '()))

  (test-case "state is isolated per session code"
    (define other (a-session "bbbbbbbbbb" "B"))
    (define h (make-hub (λ (code) (initial-state (if (equal? code "bbbbbbbbbb") other sess) pres '() #f "u" "s"))))
    (define b (hub-subscribe! h "bbbbbbbbbb" 'audience "p"))
    (drain b)
    (hub-apply! h "abcde23456" (run-opened run #f))
    (check-equal? (drain b) '())
    (check-equal? (live-runs (hub-state h "bbbbbbbbbb")) '()))

  (test-case "end pushes a final snapshot then ended, and drops subscribers"
    (define h (make-hub load))
    (define a (hub-subscribe! h "abcde23456" 'audience "p1"))
    (define adm (hub-subscribe! h "abcde23456" 'moderator "-"))
    (drain a) (drain adm)
    (hub-apply! h "abcde23456" (lecture-ended "2026-11-15T11:00:00.000Z"))
    (define am (drain adm))
    (check-equal? (last am) 'ended)
    (check-equal? (moderator-session-ended-at (moderator-snapshot-session (car am))) "2026-11-15T11:00:00.000Z")
    (check-equal? (drain a) '(ended))
    ;; subscribing to an ended session: snapshot then ended
    (define late (hub-subscribe! h "abcde23456" 'moderator "-"))
    (check-equal? (map (λ (m) (if (symbol? m) m 'snapshot)) (drain late)) '(snapshot ended)))

  (test-case "a caller killed while waiting does not freeze the hub"
    (define h (make-hub (λ (code) (sleep 0.2) (and (equal? code "abcde23456") (initial-state sess pres '() #f "u" "s")))))
    (define t (thread (λ () (hub-state h "abcde23456"))))
    (sleep 0.05)
    (kill-thread t)
    (check-equal? (live-slide (hub-state h "abcde23456")) 1))

  (test-case "subscribers whose thread was killed are dropped by the ticker"
    (define h (make-hub load #:flush-every 0.05))
    (define adm (hub-subscribe! h "abcde23456" 'moderator "-"))
    (define cell (box #f))
    (define t (thread (λ () (set-box! cell (hub-subscribe! h "abcde23456" 'audience "p1")) (sync never-evt))))
    (let wait () (unless (unbox cell) (sleep 0.01) (wait)))
    (check-equal? (connections-audience (moderator-snapshot-connections (last (snapshots (drain adm))))) 1)
    (kill-thread t)
    (thread-wait t)
    (sleep 0.3)
    (check-equal? (connections-audience (moderator-snapshot-connections (last (snapshots (drain adm))))) 0))

  ;; a loader standing in for the database: its run is whatever `db-run` holds
  (define (db-backed db-run loads)
    (λ (code)
      (set-box! loads (add1 (unbox loads)))
      (and (equal? code "abcde23456")
           (initial-state sess pres (let ([r (unbox db-run)]) (if r (list r) '())) #f "http://a" "http://s"))))

  (test-case "a vote overtaking run-opened reloads the session instead of being dropped"
    (define db-run (box #f))
    (define loads (box 0))
    (define h (make-hub (db-backed db-run loads)))
    (define adm (hub-subscribe! h "abcde23456" 'moderator "-"))
    (drain adm)
    ;; the run and the vote are committed; the hub has heard of neither
    (set-box! db-run (struct-copy poll-run run [votes (votes->ballots (list (vote "p1" '(1))))]))
    (hub-apply! h "abcde23456" (vote-cast 12 "p1" '(1)))
    (define st (hub-state h "abcde23456"))
    (check-equal? (map poll-run-id (live-runs st)) '(12))
    (check-equal? (ballots-voters (poll-run-votes (car (live-runs st)))) 1)
    (check-equal? (moderator-open-run-total-voters (moderator-snapshot-open-run (last (snapshots (drain adm))))) 1)
    ;; the late run-opened is harmless
    (hub-apply! h "abcde23456" (run-opened run #f))
    (check-equal? (live-runs st) (live-runs (hub-state h "abcde23456"))))

  (test-case "a vote for the current run does not touch the database"
    (define db-run (box run))
    (define loads (box 0))
    (define h (make-hub (db-backed db-run loads)))
    (hub-state h "abcde23456")
    (hub-apply! h "abcde23456" (vote-cast 12 "p1" '(1)))
    (check-equal? (unbox loads) 1))

  (test-case "lecture-ended overtaking run-opened ends on the run the database closed"
    (define db-run (box #f))
    (define loads (box 0))
    (define h (make-hub (db-backed db-run loads)))
    (hub-state h "abcde23456")
    (set-box! db-run (struct-copy poll-run run [closed-at "t2"] [votes (votes->ballots (list (vote "p1" '(2))))]))
    (hub-apply! h "abcde23456" (lecture-ended "t2"))
    (define st (hub-state h "abcde23456"))
    (check-true (live-ended? st))
    (check-equal? (live-runs st) (list (unbox db-run))))

  (test-case "load errors surface in the caller and the hub survives"
    (define h (make-hub (λ (code) (if (equal? code "boom") (error "boom") #f))))
    (check-exn exn:fail? (λ () (hub-state h "boom")))
    (check-false (hub-state h "other")))

  (test-case "only the affected subscribers are pushed to"
    (define h (make-hub load))
    (define a1 (hub-subscribe! h "abcde23456" 'audience "p1"))
    (define a2 (hub-subscribe! h "abcde23456" 'audience "p2"))
    (define scr (hub-subscribe! h "abcde23456" 'screen "-"))
    (define adm (hub-subscribe! h "abcde23456" 'moderator "-"))
    (hub-apply! h "abcde23456" (run-opened run #f))
    (for-each drain (list a1 a2 scr adm))
    ;; a slide change concerns the projector and the presenter, not the phones
    (hub-apply! h "abcde23456" (slide-set 4))
    (check-equal? (list (drain a1) (drain a2)) '(() ()))
    (check-equal? (list (length (drain scr)) (length (drain adm))) '(1 1))
    ;; a new connection concerns the presenter only; the newcomer gets its own snapshot
    (define a3 (hub-subscribe! h "abcde23456" 'audience "p3"))
    (check-equal? (list (drain a1) (drain a2) (drain scr)) '(() () ()))
    (check-equal? (length (drain a3)) 1)
    (check-equal? (length (drain adm)) 1)
    ;; a vote reaches the voter, the projector (its voter count) and the presenter
    (hub-apply! h "abcde23456" (vote-cast 12 "p1" '(2)))
    (check-equal? (list (length (drain a1)) (drain a2) (drain a3) (length (drain scr)) (length (drain adm))) '(1 () () 1 1)))

  (test-case "a vote that overtakes run-opened reaches every audience member"
    (define db-run (box #f))
    (define h (make-hub (db-backed db-run (box 0))))
    (define a2 (hub-subscribe! h "abcde23456" 'audience "p2"))
    (drain a2)
    (set-box! db-run run)
    (hub-apply! h "abcde23456" (vote-cast 12 "p1" '(1)))
    (check-equal? (audience-snapshot-poll (last (snapshots (drain a2)))) (audience-poll 12 "Q" "single" #t (list (choice 1 "x" #f) (choice 2 "y" #f)))))
  (test-case "late Q&A events reload persisted state instead of replacing newer inbox/status"
    (define q (qa-question 1 "Private" "pending" "t" "t" "p1"))
    (define old (qa-state #t #t #t 1 (list q) #t))
    (define latest (qa-state #t #t #t #f (list (struct-copy qa-question q [status "answered"])) #t))
    (define db (box old))
    (define h (make-hub (λ (_) (initial-state sess pres '() #f "aud" "scr" (unbox db)))))
    (hub-state h "abcde23456")
    (set-box! db latest)
    (hub-apply! h "abcde23456" (qa-synced old))
    (define st (hub-state h "abcde23456"))
    (check-equal? (live-qa st) latest)
    (check-equal? (live-overlay st) (qa-overlay #f)))

  (test-case "option invalidations adopt authoritative ballots instead of their stale event copy"
    (define latest (struct-copy poll-run run [options (append opts (list (option 3 2 "new" #f)))]
                                [votes (votes->ballots (list (vote "p1" '(3))))]))
    (define db (box run))
    (define h (make-hub (λ (_) (initial-state sess pres (list (unbox db)) #f "aud" "scr"))))
    (hub-state h "abcde23456")
    (set-box! db latest)
    (hub-apply! h "abcde23456" (run-updated run))
    (check-equal? (live-open-run (hub-state h "abcde23456")) latest))
)
