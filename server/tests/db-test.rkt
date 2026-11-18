#lang racket/base
;; Integration tests: migrations and repo against Postgres (TEST_DATABASE_URL).
(require rackunit racket/file racket/list db "support.rkt" "../db/conn.rkt" "../auth/users.rkt" "../db/accounts.rkt" "../db/migrate.rkt" "../db/repo.rkt" "../domain.rkt" "../export.rkt" "../live/codes.rkt")

;; (or Id #f) String Kind [Listof String] Boolean -> PollDraft
;; constructs an ordinary fixed-answer poll for the integration scenarios
(define (simple-draft slide question kind labels show-results?)
  (poll-draft slide question kind (map (λ (label) (option-draft label #f)) labels) show-results? #f))

(define (sqlstate-of thunk)
  (with-handlers ([exn:fail:sql? (λ (e) (format "~a" (exn:fail:sql-sqlstate e)))]) (thunk) #f))

(define U1 "11111111-1111-4111-8111-111111111111")
(define U2 "22222222-2222-4222-8222-222222222222")

(define (setup-run! c labels kind)
  (define pid (new-deck! c (new-owner! c) "T" 10))
  (define poll (create-poll! c pid (simple-draft 3 "Q?" kind labels #f)))
  (define s (insert-session! c pid "A" (random-code) (random-code)))
  (define run (open-run! c (session-id s) (poll-id poll)))
  (values pid poll s run))

(define (option-ids poll) (map option-id (poll-options poll)))
(define (listed? listings id)
  (and (memf (λ (l) (= (presentation-id (deck-presentation (presentation-listing-deck l))) id)) listings) #t))

(module+ test
  (if (test-db-url)
      (test-suite-body (fresh-db!))
      (eprintf "SKIPPED db-test: TEST_DATABASE_URL not set (use scripts/with-ephemeral-pg)\n")))

(define (test-suite-body c)
  (test-case "migrate is idempotent"
    (check-equal? (migrate! c test-sources) '())
    (check-equal? (query-list c "SELECT version FROM schema_migrations ORDER BY version") '("core/20261117000000_init.sql")))

  (test-case "session epoch: a cookie matches only its own epoch; suspending bumps it, activating does not"
    (define id (create-user! c "epoch@example.org" #t "E"))
    (check-equal? (session-epoch c id) 0)
    (check-equal? (user-id (get-session-user c id 0)) id)
    (check-false (get-session-user c id 1))
    (check-false (get-session-user c (add1 id) 0))
    (check-equal? (bump-session-epoch! c id) 1)
    (check-false (get-session-user c id 0))
    (check-equal? (user-status (get-session-user c id 1)) "active")
    (set-user-status! c id "suspended")
    (check-equal? (session-epoch c id) 2)
    (check-equal? (user-status (get-session-user c id 2)) "suspended")
    (set-user-status! c id "active")
    (check-equal? (session-epoch c id) 2)
    (check-false (get-session-user c id 1)))

  (test-case "passwords: one per user, replaced by set-password!, found by verified email in any case"
    (define id (create-user! c "pw@example.org" #t "P"))
    (check-false (find-credential c "pw@example.org"))
    (set-password! c id "h1")
    (check-equal? (find-credential c "PW@Example.org") (credential id "h1" "active"))
    (set-password! c id "h2")
    (check-equal? (credential-hash (find-credential c "pw@example.org")) "h2")
    (set-user-status! c id "suspended")
    (check-equal? (credential-status (find-credential c "pw@example.org")) "suspended")
    (define unverified (create-user! c "unverified@example.org" #f "U"))
    (set-password! c unverified "h3")
    (check-false (find-credential c "unverified@example.org")))

  (test-case "list-users returns every user, oldest first"
    (define ids (map user-id (list-users c)))
    (check-equal? ids (sort ids <))
    (check-not-false (member "pw@example.org" (map user-email (list-users c)))))

  (test-case "migrate! orders streams and refuses a back-dated file"
    (define core (make-temporary-file "orquelo-mig~a" 'directory))
    (define extra (make-temporary-file "orquelo-mig~a" 'directory))
    (define (write-sql! dir name) (display-to-file "SELECT 1;\n" (build-path dir name)))
    (dynamic-wind
     void
     (λ ()
       (write-sql! core "20260301000000_a.sql")
       (write-sql! extra "20260101000000_x.sql")
       (define sources (list (migration-source "t1" core) (migration-source "t2" extra)))
       (check-equal? (migrate! c sources) '("t1/20260301000000_a.sql" "t2/20260101000000_x.sql"))
       (write-sql! core "20260201000000_old.sql")
       (check-exn #rx"t1/20260201000000_old.sql is older than applied t1/20260301000000_a.sql"
                  (λ () (migrate! c sources)))
       (check-equal? (query-value c "SELECT count(*) FROM schema_migrations WHERE version LIKE 't1/%'") 1)
       (write-sql! core "20260401000000_new.sql")
       (delete-file (build-path core "20260201000000_old.sql"))
       (check-equal? (migrate! c sources) '("t1/20260401000000_new.sql")))
     (λ ()
       (query-exec c "DELETE FROM schema_migrations WHERE version LIKE 't_/%'")
       (delete-directory/files core) (delete-directory/files extra))))

  (test-case "RESTRICT deletes raise 23503"
    (define-values (pid poll s run) (setup-run! c '("a" "b") "single"))
    (check-equal? (sqlstate-of (λ () (query-exec c "DELETE FROM presentations WHERE id=$1" pid))) "23503")
    (check-equal? (sqlstate-of (λ () (query-exec c "DELETE FROM polls WHERE id=$1" (poll-id poll)))) "23503"))

  (test-case "presentation CRUD, archive, delete guard"
    (define owner (new-owner! c))
    (define id (new-deck! c owner "Deck" 5 1234))
    (set-pdf-key! c id "x.pdf")
    (check-equal? (presentation-title (get-presentation c id)) "Deck")
    (check-equal? (presentation-archived-at (get-presentation c id)) #f)
    (check-equal? (presentation-title (rename-presentation! c id "New")) "New")
    (check-true (string? (presentation-archived-at (set-archived! c id #t))))
    (check-false (listed? (list-presentations c owner #f) id))
    (check-true (listed? (list-presentations c owner #t) id))
    (check-false (presentation-archived-at (set-archived! c id #f)))
    (check-equal? (presentation-pdf-key c id) "x.pdf")
    (check-equal? (delete-presentation! c id) "x.pdf")
    (check-false (delete-presentation! c id))
    (check-false (delete-presentation! c 999999)))

  (test-case "deleting a presentation waits for its sessions to end, then takes everything with it"
    (define-values (pid poll s run) (setup-run! c '("a" "b") "single"))
    (put-share! c pid (share "x@example.org" #t #t #t #t))
    (check-equal? (cast-vote! c (poll-run-id run) (session-code s) pid U1 (list (option-id (car (poll-run-options run))))) 'ok)
    (check-equal? (delete-presentation! c pid) 'session-live)
    (check-true (and (get-presentation c pid) #t))
    (end-session! c (session-id s))
    (check-equal? (delete-presentation! c pid) "pending")
    (define rid (poll-run-id run))
    (for ([(table where) (in-hash (hash "presentations" "id" "polls" "presentation_id" "lecture_sessions" "presentation_id"
                                        "deck_shares" "presentation_id" "poll_runs" "id"
                                        "votes" "poll_run_id" "vote_options" "poll_run_id"))])
      (check-equal? (query-value c (format "SELECT count(*) FROM ~a WHERE ~a=$1" table where)
                                 (if (member table '("poll_runs" "votes" "vote_options")) rid pid))
                    0 table)))

  (test-case "storage used sums the pdf bytes of the user's own decks"
    (define owner (new-owner! c))
    (check-equal? (storage-used c owner) 0)
    (new-deck! c owner "A" 1 100)
    (new-deck! c owner "B" 1 23)
    (check-equal? (storage-used c owner) 123)
    (check-equal? (storage-used c (new-owner! c)) 0))

  (test-case "live_sessions counts only live sessions"
    (define owner (new-owner! c))
    (define pid (new-deck! c owner "Live" 3))
    (insert-session! c pid "" "bbbbbbbbbb" "bbbbbbbbb2")
    (define s2 (insert-session! c pid "" "cccccccccc" "ccccccccc2"))
    (end-session! c (session-id s2))
    (check-equal? (presentation-listing-live-sessions (findf (λ (l) (= (presentation-id (deck-presentation (presentation-listing-deck l))) pid)) (list-presentations c owner #f))) 1))

  (test-case "poll CRUD, positions, ordering"
    (define pid (new-deck! c (new-owner! c) "P" 10))
    (define a (create-poll! c pid (simple-draft 2 "A" "single" '("x" "y") #f)))
    (define b (create-poll! c pid (simple-draft 2 "B" "multi" '("x" "y" "z") #f)))
    (define n (create-poll! c pid (simple-draft #f "N" "single" '("x" "y") #f)))
    (define first (create-poll! c pid (simple-draft 1 "F" "single" '("x" "y") #f)))
    (check-equal? (map poll-position (list a b)) '(1 2))
    (check-equal? (map poll-question (list-polls c pid)) '("F" "A" "B" "N"))
    (check-equal? (map option-idx (poll-options b)) '(0 1 2))
    (check-false (poll-slide n))
    (define u (update-poll! c (poll-id a) (simple-draft 2 "A2" "multi" '("q" "r" "s") #f)))
    (check-equal? (poll-question u) "A2")
    (check-equal? (map option-label (poll-options u)) '("q" "r" "s"))
    (check-equal? (poll-position u) 1)
    (define d (duplicate-poll! c (poll-id b)))
    (check-equal? (poll-position d) 3)
    (check-equal? (poll-question d) "B")
    (check-not-equal? (poll-id d) (poll-id b))
    (check-equal? (delete-poll! c (poll-id d)) 'ok)
    (check-false (delete-poll! c (poll-id d)))
    (check-false (get-poll c (poll-id d))))

  (test-case "poll_has_runs guards update and delete"
    (define-values (pid poll s run) (setup-run! c '("a" "b") "single"))
    (check-true (poll-has-runs? (get-poll c (poll-id poll))))
    (check-equal? (update-poll! c (poll-id poll) (simple-draft 3 "Z" "single" '("a" "b") #f)) 'has-runs)
    (check-equal? (delete-poll! c (poll-id poll)) 'has-runs)
    (check-equal? (poll-question (get-poll c (poll-id poll))) "Q?"))

  (test-case "poll archive: needs runs, idempotent, unarchive, duplicate is active"
    (define pid0 (new-deck! c (new-owner! c) "AR" 5))
    (define fresh (create-poll! c pid0 (simple-draft 1 "F" "single" '("x" "y") #f)))
    (check-equal? (set-poll-archived! c (poll-id fresh) #t) 'has-no-runs)
    (check-false (poll-archived-at (get-poll c (poll-id fresh))))
    (check-false (set-poll-archived! c 999999 #t))
    (check-false (set-poll-archived! c 999999 #f))
    (define-values (pid poll s run) (setup-run! c '("a" "b") "single"))
    (check-false (poll-archived-at poll))
    (define archived (set-poll-archived! c (poll-id poll) #t))
    (check-true (string? (poll-archived-at archived)))
    (check-equal? (poll-archived-at (set-poll-archived! c (poll-id poll) #t)) (poll-archived-at archived))
    (check-true (string? (poll-archived-at (car (list-polls c pid)))) "listed with its archived-at")
    (check-false (poll-archived-at (duplicate-poll! c (poll-id poll))))
    (check-true (string? (poll-archived-at (get-poll c (poll-id poll)))))
    (check-false (poll-archived-at (set-poll-archived! c (poll-id poll) #f)))
    (check-false (poll-archived-at (set-poll-archived! c (poll-id fresh) #f))))

  (test-case "show_results: default false, stored on create, updated, copied, editable after runs"
    (define pid (new-deck! c (new-owner! c) "SR" 5))
    (define a (create-poll! c pid (simple-draft 1 "A" "single" '("x" "y") #f)))
    (define b (create-poll! c pid (simple-draft 1 "B" "single" '("x" "y") #t)))
    (check-false (poll-show-results? a))
    (check-true (poll-show-results? b))
    (check-true (poll-show-results? (duplicate-poll! c (poll-id b))))
    (check-true (poll-show-results? (update-poll! c (poll-id a) (simple-draft 1 "A" "single" '("x" "y") #t))))
    (define-values (pid2 poll s run) (setup-run! c '("a" "b") "single"))
    (check-true (poll-show-results? (set-show-results! c (poll-id poll) #t)))
    (check-false (poll-show-results? (get-poll c (poll-id (set-show-results! c (poll-id poll) #f)))))
    (check-false (set-show-results! c 999999 #t)))

  (test-case "run-results-shown? follows revealed_at"
    (define-values (pid poll s run) (setup-run! c '("a" "b") "single"))
    (check-false (run-results-shown? c (poll-run-id run)))
    (reveal-run! c (poll-run-id run))
    (check-true (run-results-shown? c (poll-run-id run))))

  (test-case "one open run per session; opening closes the previous"
    (define-values (pid poll s run) (setup-run! c '("a" "b") "single"))
    (define run2 (open-run! c (session-id s) (poll-id poll)))
        (check-true (string? (poll-run-closed-at (get-run c (poll-run-id run)))))
    (check-equal? (poll-run-id (current-run c (session-id s))) (poll-run-id run2))
    (check-equal? (sqlstate-of (λ () (query-exec c "INSERT INTO poll_runs (session_id, poll_id) VALUES ($1, $2)" (session-id s) (poll-id poll)))) "23505")
    (check-true (string? (close-run! c (poll-run-id run2))))
    (check-false (close-run! c (poll-run-id run2))))

  (test-case "vote upsert replaces options"
    (define-values (pid poll s run) (setup-run! c '("a" "b" "c") "multi"))
    (define ids (map option-id (poll-run-options run)))
    (define rid (poll-run-id run))
    (check-equal? (cast-vote! c rid (session-code s) pid U1 (list (car ids) (cadr ids))) 'ok)
    (check-equal? (cast-vote! c rid (session-code s) pid U1 (list (caddr ids))) 'ok)
    (check-equal? (cast-vote! c rid (session-code s) pid U2 (list (car ids))) 'ok)
    (check-equal? (sort (run-votes c rid) string<? #:key vote-participant)
                  (list (vote U1 (list (caddr ids))) (vote U2 (list (car ids)))))
    (check-equal? (query-value c "SELECT count(*) FROM votes WHERE poll_run_id=$1" rid) 2))

  (test-case "vote on closed run / wrong session / ended session is poll-not-open"
    (define-values (pid poll s run) (setup-run! c '("a" "b") "single"))
    (define ids (map option-id (poll-run-options run)))
    (define rid (poll-run-id run))
    (check-equal? (cast-vote! c rid "zzzzzzzzzz" pid U1 (list (car ids))) 'poll-not-open)
    (check-equal? (cast-vote! c rid (session-code s) (+ pid 1) U1 (list (car ids))) 'poll-not-open)
    (close-run! c rid)
    (check-equal? (cast-vote! c rid (session-code s) pid U1 (list (car ids))) 'poll-not-open)
    (check-equal? (cast-vote! c 999999 (session-code s) pid U1 (list (car ids))) 'poll-not-open))

  (test-case "option from another poll is invalid and rolls back"
    (define-values (pid poll s run) (setup-run! c '("a" "b") "multi"))
    (define other (create-poll! c pid (simple-draft 4 "Other" "single" '("x" "y") #f)))
    (define ids (map option-id (poll-run-options run)))
    (define rid (poll-run-id run))
    (check-equal? (cast-vote! c rid (session-code s) pid U1 (list (car ids))) 'ok)
    (check-equal? (cast-vote! c rid (session-code s) pid U1 (list (cadr ids) (car (option-ids other)))) 'invalid)
    (check-equal? (run-votes c rid) (list (vote U1 (list (car ids))))))

  (test-case "end-session closes the open run and blocks votes"
    (define-values (pid poll s run) (setup-run! c '("a" "b") "single"))
    (check-true (string? (end-session! c (session-id s))))
    (check-true (string? (poll-run-closed-at (get-run c (poll-run-id run)))))
    (check-true (string? (session-ended-at (get-session c (session-code s))))))

  (test-case "screen code finds its session, the audience code does not"
    (define-values (pid poll s run) (setup-run! c '("a" "b") "single"))
    (check-not-equal? (session-code s) (session-screen-code s))
    (check-equal? (get-session-by-screen-code c (session-screen-code s)) s)
    (check-false (get-session-by-screen-code c (session-code s)))
    (check-false (get-session c (session-screen-code s))))

  (test-case "csv export"
    (define-values (pid poll s run) (setup-run! c '("a,1" "b") "multi"))
    (define ids (map option-id (poll-run-options run)))
    (cast-vote! c (poll-run-id run) (session-code s) pid U1 ids)
    (define rows (export-rows c (session-id s)))
    (check-equal? (length rows) 2)
    (check-equal? (list-ref (car rows) 10) "a,1")
    (define csv (render-csv export-header rows))
    (check-regexp-match #rx"\"a,1\"" csv)
    (check-regexp-match #rx"^session_code," csv))

  (define (vote-row run-id participant)
    (query-row c "SELECT changes, first_voted_at FROM votes WHERE poll_run_id=$1 AND participant_id=$2::uuid" run-id participant))

  (test-case "changes count only revotes of a different option set; first_voted_at never moves"
    (define-values (pid poll s run) (setup-run! c '("a" "b" "c") "multi"))
    (define-values (a b _c) (apply values (map option-id (poll-run-options run))))
    (define rid (poll-run-id run))
    (define (vote! . ids) (cast-vote! c rid (session-code s) pid U1 ids))
    (vote! a)
    (define first-at (vector-ref (vote-row rid U1) 1))
    (check-equal? (vector-ref (vote-row rid U1) 0) 0)
    (vote! a)
    (check-equal? (vector-ref (vote-row rid U1) 0) 0)
    (vote! b a)
    (check-equal? (vector-ref (vote-row rid U1) 0) 1)
    (vote! a b)
    (check-equal? (vector-ref (vote-row rid U1) 0) 1)
    (vote! b)
    (check-equal? (vector-ref (vote-row rid U1) 0) 2)
    (check-equal? (vector-ref (vote-row rid U1) 1) first-at)
    (check-equal? (participant-option-ids c rid U1) (list b))
    ;; a rejected revote changes nothing
    (check-equal? (cast-vote! c rid (session-code s) pid U1 (list a 999999)) 'invalid)
    (check-equal? (vector-ref (vote-row rid U1) 0) 2))

  (test-case "record-peaks! only raises the stored peaks"
    (define-values (pid poll s run) (setup-run! c '("a" "b") "single"))
    (define rid (poll-run-id run))
    (define (stored) (list (query-value c "SELECT peak_audience FROM lecture_sessions WHERE id=$1" (session-id s))
                           (query-value c "SELECT peak_audience FROM poll_runs WHERE id=$1" rid)))
    (check-equal? (map sql-null? (stored)) '(#t #t))
    (record-peaks! c (session-code s) 5 rid 3)
    (check-equal? (stored) '(5 3))
    (record-peaks! c (session-code s) 4 rid 8)
    (check-equal? (stored) '(5 8))
    (record-peaks! c (session-code s) 9 #f 0)
    (check-equal? (stored) '(9 8)))

  (test-case "results: zero-count options, voters, changes, medians and peaks"
    (define-values (pid poll s run) (setup-run! c '("a" "b" "c") "single"))
    (define-values (a b _c) (apply values (map option-id (poll-run-options run))))
    (define rid (poll-run-id run))
    (define sid (session-id s))
    (query-exec c "UPDATE poll_runs SET opened_at = now() - interval '60 seconds' WHERE id=$1" rid)
    (cast-vote! c rid (session-code s) pid U1 (list a))
    (cast-vote! c rid (session-code s) pid U1 (list b))
    (cast-vote! c rid (session-code s) pid U2 (list b))
    (query-exec c "UPDATE votes SET first_voted_at = (SELECT opened_at FROM poll_runs WHERE id=$1) + CASE participant_id WHEN $2::uuid THEN interval '10 seconds' ELSE interval '15 seconds' END WHERE poll_run_id=$1" rid U1)
    (record-peaks! c (session-code s) 6 rid 4)
    (define second (create-poll! c pid (simple-draft 4 "Q2" "single" '("x" "y") #f)))
    (open-run! c sid (poll-id second))
    (define runs (run-results c sid))
    (check-equal? (map run-result-run-id runs) (list rid (add1 rid)))
    (define r1 (car runs))
    (check-equal? (map (λ (o) (list (option-count-label o) (option-count-count o))) (run-result-options r1))
                  '(("a" 0) ("b" 2) ("c" 0)))
    (check-equal? (list (run-result-total-voters r1) (run-result-peak-audience r1) (run-result-median-seconds r1) (run-result-changed-voters r1))
                  '(2 4 12.5 1))
    (define r2 (cadr runs))
    (check-equal? (map option-count-count (run-result-options r2)) '(0 0))
    (check-equal? (list (run-result-total-voters r2) (run-result-peak-audience r2) (run-result-median-seconds r2) (run-result-changed-voters r2))
                  (list 0 #f #f #f))
    (check-equal? (results-totals-row c sid) (results-totals 2 6 12.5 1 1)))

  (test-case "results: votes from before engagement tracking report unknown, not zero"
    (define-values (pid poll s run) (setup-run! c '("a" "b") "single"))
    (cast-vote! c (poll-run-id run) (session-code s) pid U1 (list (car (map option-id (poll-run-options run)))))
    (query-exec c "UPDATE votes SET first_voted_at = NULL, changes = NULL WHERE poll_run_id=$1" (poll-run-id run))
    (check-equal? (results-totals-row c (session-id s)) (results-totals 1 #f #f #f #f))
    (check-equal? (run-result-changed-voters (car (run-results c (session-id s)))) #f))

  (test-case "results of a session without runs"
    (define pid (new-deck! c (new-owner! c) "Empty" 3))
    (define s (insert-session! c pid "" (random-code) (random-code)))
    (check-equal? (run-results c (session-id s)) '())
    (check-equal? (results-totals-row c (session-id s)) (results-totals 0 #f #f #f #f)))

  (test-case "run-local answers preserve votes, past results, definitions and other sessions"
    (define pid (new-deck! c (new-owner! c) "Dynamic" 3))
    (define pl (create-poll! c pid
                 (poll-draft #f "Choose" "multi"
                   (list (option-draft "a" #f) (option-draft "unsure" #t)) #f #t)))
    (define s (insert-session! c pid "A" (random-code) (random-code)))
    (define s2 (insert-session! c pid "B" (random-code) (random-code)))
    (define first (open-run! c (session-id s) (poll-id pl)))
    (define other (open-run! c (session-id s2) (poll-id pl)))
    (define rid (poll-run-id first))
    (define a (option-id (car (poll-run-options first))))
    (define unsure (option-id (cadr (poll-run-options first))))
    (check-true (poll-run-allow-additional? first))
    (check-equal? (cast-vote! c rid (session-code s) pid U1 (list a)) 'ok)
    (check-equal? (cast-vote! c rid (session-code s) pid U1 (list a unsure)) 'invalid)
    (check-equal? (participant-option-ids c rid U1) (list a))
    (define added (append-run-option! c (session-id s) rid (option-draft "b" #f)))
    (check-true (option? added))
    (check-equal? (map option-label (poll-options (get-poll c (poll-id pl)))) '("a" "unsure"))
    (check-equal? (map option-label (poll-run-options (get-run c (poll-run-id other)))) '("a" "unsure"))
    (check-equal? (participant-option-ids c rid U1) (list a))
    (check-equal? (cast-vote! c rid (session-code s) pid U2 (list a (option-id added))) 'ok)
    (close-run! c rid)
    (check-equal? (append-run-option! c (session-id s) rid (option-draft "late" #f)) 'poll-not-open)
    (check-true (resume-run! c rid))
    (check-equal? (length (poll-run-options (get-run c rid))) 3)
    (define next (open-run! c (session-id s) (poll-id pl)))
    (check-equal? (length (poll-run-options next)) 2)
    (check-equal? (map option-count-count (run-result-options (car (run-results c (session-id s))))) '(2 0 1))
    (check-equal? (map option-label (poll-run-options (get-run c rid))) '("a" "unsure" "b"))
    (check-equal? (cast-vote! c (poll-run-id next) (session-code s) pid U1 (list a)) 'invalid))

  (test-case "option additions enforce opt-in, type, session and capacity"
    (define-values (pid fixed s run) (setup-run! c '("a" "b") "single"))
    (check-equal? (append-run-option! c (session-id s) (poll-run-id run) (option-draft "c" #f)) 'not-allowed)
    (define pl (create-poll! c pid
                 (poll-draft #f "Choose" "single"
                   (for/list ([i (in-range 29)]) (option-draft (format "~a" i) #f)) #f #t)))
    (define dynamic (open-run! c (session-id s) (poll-id pl)))
    (define rid (poll-run-id dynamic))
    (check-equal? (append-run-option! c (+ (session-id s) 10000) rid (option-draft "bad" #f)) 'poll-not-open)
    (check-equal? (append-run-option! c (session-id s) rid (option-draft "exclusive" #t)) 'invalid)
    (define channels
      (for/list ([i (in-range 2)])
        (define ch (make-channel))
        (thread
          (λ ()
            (define cx (connect-direct (test-db-url)))
            (dynamic-wind void
              (λ () (channel-put ch (append-run-option! cx (session-id s) rid (option-draft "last" #f))))
              (λ () (disconnect cx)))))
        ch))
    (define outcomes (map channel-get channels))
    (check-equal? (count option? outcomes) 1)
    (check-equal? (count (λ (x) (eq? x 'too-many)) outcomes) 1)
    (check-equal? (length (poll-run-options (get-run c rid))) 30)
    (end-session! c (session-id s))
    (check-equal? (append-run-option! c (session-id s) rid (option-draft "ended" #f)) 'poll-not-open))

  ;; ---------------------------------------------------------------- decks, shares, limits
  (define (user! email #:verified [v #t]) (create-user! c email v "U"))
  (define (flags a) (list (access-owner? a) (access-view? a) (access-edit? a) (access-moderate? a)
                          (access-copy? a) (access-results? a)))

  (test-case "a deck is visible to its owner and to the verified email it is shared with, only"
    (define ow (user! "own@example.org"))
    (define pid (new-deck! c ow "Shared" 3))
    (define bob (user! "bob@example.org"))
    (define unverified (user! "eve@example.org" #:verified #f))
    (put-share! c pid (share "bob@example.org" #f #t #f #f))
    (put-share! c pid (share "eve@example.org" #t #t #t #t))
    (check-equal? (flags (deck-access (get-deck c ow pid))) '(#t #t #t #t #t #t))
    (check-equal? (deck-owner (get-deck c ow pid)) (owner "own@example.org" "U"))
    (check-equal? (flags (deck-access (get-deck c bob pid))) '(#f #t #f #t #f #f))
    (check-false (get-deck c unverified pid))
    (check-false (get-deck c (user! "nobody@example.org") pid))
    (check-true (listed? (list-presentations c bob #f) pid))
    (check-false (listed? (list-presentations c unverified #f) pid)))

  (test-case "a share is replaced by a new grant and removed by delete-share!"
    (define pid (new-deck! c (user! "o2@example.org") "S" 1))
    (put-share! c pid (share "a@example.org" #t #f #f #f))
    (put-share! c pid (share "a@example.org" #f #f #t #t))
    (check-equal? (list-shares c pid) (list (share "a@example.org" #f #f #t #t)))
    (check-true (delete-share! c pid "a@example.org"))
    (check-false (delete-share! c pid "a@example.org"))
    (check-equal? (list-shares c pid) '()))

  (test-case "the database lowercases share emails, on grant and on revoke"
    (define pid (new-deck! c (user! "o3@example.org") "S" 1))
    (check-equal? (put-share! c pid (share "MiXed@Example.org" #t #f #f #f)) (share "mixed@example.org" #t #f #f #f))
    (check-equal? (put-share! c pid (share "mixed@EXAMPLE.org" #f #t #f #f)) (share "mixed@example.org" #f #t #f #f))
    (check-equal? (map share-email (list-shares c pid)) '("mixed@example.org"))
    (check-true (delete-share! c pid "MIXED@example.org"))
    (check-equal? (list-shares c pid) '()))

  (test-case "a share with the owner's own email changes nothing"
    (define ow (user! "self@example.org"))
    (define pid (new-deck! c ow "Mine" 1))
    (put-share! c pid (share "self@example.org" #f #f #f #f))
    (check-equal? (flags (deck-access (get-deck c ow pid))) '(#t #t #t #t #t #t))
    (check-equal? (length (list-presentations c ow #f)) 1))

  (test-case "add-presentation! enforces the limits' per-deck cap and storage quota"
    (define (tiny c id) (limits 60 100 #f))
    (define u (user! "tiny@example.org"))
    (check-equal? (add-presentation! c tiny u "Big" 1 61) 'too-large)
    (check-true (exact-integer? (add-presentation! c tiny u "A" 1 60)))
    (check-equal? (add-presentation! c tiny u "B" 1 41) 'quota-exceeded)
    (check-true (exact-integer? (add-presentation! c tiny u "B" 1 40)))
    (check-equal? (storage-used c u) 100))

  (test-case "a limits function with no quota leaves only the per-deck cap"
    (define u (user! "unlimited@example.org"))
    (define (no-quota c id) (limits 60 #f #f))
    (check-equal? (add-presentation! c no-quota u "Big" 1 61) 'too-large)
    (check-true (exact-integer? (add-presentation! c no-quota u "A" 1 60)))
    (check-true (exact-integer? (add-presentation! c no-quota u "B" 1 60))))

  (test-case "copy-presentation! copies the deck and its non-archived polls, within the copier's limits"
    (define owner (user! "src@example.org"))
    (define pid (new-deck! c owner "Src" 4 50))
    (set-pdf-key! c pid "1-aaaaaaaaaa.pdf")
    (define keep (create-poll! c pid (simple-draft 2 "Keep?" "single" '("a" "b") #f)))
    (define old (create-poll! c pid (simple-draft 1 "Old?" "single" '("a" "b") #f)))
    (define s (insert-session! c pid "" (random-code) (random-code)))
    (open-run! c (session-id s) (poll-id old))
    (set-poll-archived! c (poll-id old) #t)
    (define copier (user! "copier@example.org"))
    (define (roomy c id) (limits 104857600 #f #f))
    (define (tiny c id) (limits 60 100 #f))
    (define new-id (copy-presentation! c roomy copier pid))
    (check-equal? (presentation-title (get-presentation c new-id)) "Src")
    (check-equal? (map poll-question (list-polls c new-id)) '("Keep?"))
    (check-equal? (list-sessions c new-id) '())
    (check-equal? (storage-used c copier) 50)
    (check-false (copy-presentation! c roomy copier 999999))
    (check-true (exact-integer? (copy-presentation! c tiny copier pid)))
    (check-equal? (copy-presentation! c tiny copier pid) 'quota-exceeded)))
