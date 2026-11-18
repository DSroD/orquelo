#lang racket/base
;; The `user` command line: manage local accounts in the database.
;;   orquelo user add EMAIL [--name NAME]   (the password is read from stdin, never from argv)
;;   orquelo user passwd EMAIL              (the new password is read from stdin; ends the user's sessions)
;;   orquelo user suspend EMAIL | activate EMAIL
;;   orquelo user list
;; Reads DATABASE_URL and MIGRATIONS_DIR; it migrates first, so it works against a fresh database.
;; Without passwords (#:passwords? #f, an edition with another login) just list, suspend and activate work.
(require racket/contract/base racket/match racket/port racket/string db
         "auth/password.rkt" "db/accounts.rkt" "db-cli.rkt" (only-in "config.rkt" core-streams)
         "domain.rkt" "edition.rkt")
(provide (contract-out
          [run-user (->* ((vectorof string?) env/c input-port? output-port?) ((listof migration-stream?) #:passwords? boolean?)
                         natural-number/c)]
          [make-user-command (-> (listof migration-stream?) boolean? command?)]))

(define (usage passwords?)
  (if passwords?
      "usage: orquelo user (add EMAIL [--name NAME] | passwd EMAIL | suspend EMAIL | activate EMAIL | list)\n"
      "usage: orquelo user (list | suspend EMAIL | activate EMAIL)\n"))

;; ------------------------------------------------------------------ input
;; String -> String
;; the address as stored: trimmed, lower-case; raises unless it looks like one
(define (normalize-email s)
  (define e (string-downcase (string-trim s)))
  (unless (regexp-match? #px"^[^@\\s]+@[^@\\s]+$" e) (error 'user "invalid email ~a" s))
  e)

;; InputPort -> String
;; the password on `in` (piped or redirected), without one trailing newline; raises unless it is a valid new one
(define (read-password in)
  (define s (regexp-replace #rx"\r?\n$" (port->string in) ""))
  (unless (valid-new-password? s) (error 'user "the password (on stdin) must be 10 to 1024 bytes"))
  s)

;; String -> String
;; the display name for an address without --name: its local part
(define (default-name email) (car (string-split email "@" #:trim? #f)))

;; Exception -> Boolean
(define (unique-violation? e)
  (and (exn:fail:sql? e) (equal? (exn:fail:sql-sqlstate e) "23505")))

;; ------------------------------------------------------------------ commands
;; Connection String -> Id
;; the id of the user with this verified email; raises when there is none
(define (user-id-of c email)
  (or (find-user-id-by-verified-email c email) (error 'user "no user ~a" email)))

;; Connection String String String -> Void
;; a new user with a verified email and the password hash, in one transaction
(define (user-add c email name hash)
  (call-with-transaction c (λ () (set-password! c (create-user! c email #t name) hash)))
  (printf "added ~a\n" email))

;; Connection String String -> Void
;; replaces the password and ends every session of the user
(define (user-passwd c email hash)
  (call-with-transaction c (λ ()
                             (define id (user-id-of c email))
                             (set-password! c id hash)
                             (bump-session-epoch! c id)))
  (printf "password changed for ~a\n" email))

;; Connection -> Void
;; one line per user: id, email, status and name, tab-separated
(define (user-list c)
  (for ([u (list-users c)])
    (printf "~a\n" (string-join (list (number->string (user-id u)) (or (user-email u) "") (user-status u) (user-name u)) "\t"))))

;; (Vectorof String) Env InputPort OutputPort [Listof MigrationStream] [#:passwords? Boolean] -> Natural
;; runs the `user` subcommand in `argv` (what follows "user") and returns the exit code; errors go to stderr.
;; The password is read and checked before the database is touched.
(define (run-user argv env in out [streams core-streams] #:passwords? [passwords? #t])
  (define (with-db f) (call-with-migrated-db env streams f) 0)
  (define (refuse) (eprintf (usage passwords?)) 2)
  (parameterize ([current-output-port out])
    (with-handlers ([unique-violation? (λ (_) (eprintf "a user with this email already exists\n") 1)]
                    [exn:fail? (λ (e) (eprintf "~a\n" (exn-message e)) 1)])
      (match (vector->list argv)
        [(list "list") (with-db user-list)]
        [(list (and verb (or "suspend" "activate")) email)
         (define e (normalize-email email))
         (with-db (λ (c) (set-user-status! c (user-id-of c e) (if (equal? verb "suspend") "suspended" "active"))
                    (printf "~a ~a\n" (if (equal? verb "suspend") "suspended" "activated") e)))]
        [(list "add" email rest ...)
         #:when passwords?
         (match rest
           [(list) (user-add-from env streams in email #f)]
           [(list "--name" name) (user-add-from env streams in email name)]
           [_ (refuse)])]
        [(list "passwd" email)
         #:when passwords?
         (define e (normalize-email email))
         (define hash (hash-password (read-password in)))
         (with-db (λ (c) (user-passwd c e hash)))]
        [_ (refuse)]))))

;; Env [Listof MigrationStream] InputPort String (or String #f) -> Natural
;; `user add` once its arguments are known: reads the password, hashes it, then writes
(define (user-add-from env streams in email name)
  (define e (normalize-email email))
  (define hash (hash-password (read-password in)))
  (call-with-migrated-db env streams (λ (c) (user-add c e (or name (default-name e)) hash)))
  0)

;; [Listof MigrationStream] Boolean -> Command
;; the `user` subcommand, migrating `streams` before it touches the database
(define (make-user-command streams passwords?)
  (command "user" (if passwords? "user (add|passwd|suspend|activate|list) ..." "user (list|suspend|activate) ...")
           (λ (argv env in out) (run-user argv env in out streams #:passwords? passwords?))))

(module+ test
  (require rackunit)
  (test-case "emails are trimmed and lower-cased; anything else is refused"
    (check-equal? (normalize-email " A@Example.ORG \n") "a@example.org")
    (for ([bad '("" "nope" "a@" "@b" "a b@c" "a@b@c")]) (check-exn #rx"invalid email" (λ () (normalize-email bad)) bad)))
  (test-case "the password on stdin loses one trailing newline only"
    (check-equal? (read-password (open-input-string "correct horse\n")) "correct horse")
    (check-equal? (read-password (open-input-string "correct horse\r\n")) "correct horse")
    (check-equal? (read-password (open-input-string "correct horse\n\n")) "correct horse\n")
    (check-exn #rx"10 to 1024" (λ () (read-password (open-input-string "short\n"))))
    (check-exn #rx"10 to 1024" (λ () (read-password (open-input-string "")))))
  (test-case "default name"
    (check-equal? (default-name "ann@x.cz") "ann"))
  (test-case "without passwords, add and passwd exit 2 before reading anything"
    (define err (open-output-string))
    (define (run . argv)
      (parameterize ([current-error-port err])
        (run-user (list->vector argv) (hash) (open-input-string "") (open-output-string) #:passwords? #f)))
    (check-equal? (run "add" "a@b.c") 2)
    (check-equal? (run "passwd" "a@b.c") 2)
    (check-equal? (run) 2)
    (check-regexp-match #rx"^usage: orquelo user \\(list \\| suspend EMAIL \\| activate EMAIL\\)" (get-output-string err))))
