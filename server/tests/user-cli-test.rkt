#lang racket/base
;; The `user` command line against Postgres (TEST_DATABASE_URL), driven through run-user.
(require rackunit racket/port racket/string db "support.rkt" "../user-cli.rkt" "../auth/password.rkt"
         "../db/accounts.rkt" "../domain.rkt")

(define env (hash "DATABASE_URL" (or (test-db-url) "") "MIGRATIONS_DIR" (path->string migrations-dir)))
(define good-password "correct horse battery")

;; String ... -> (values Natural String String)
;; runs `user` with the argument words and stdin `in`; the exit code, stdout and stderr
(define (user #:in [in ""] #:passwords? [passwords? #t] . args)
  (define err (open-output-string))
  (define out (open-output-string))
  (define code (parameterize ([current-error-port err])
                 (run-user (list->vector args) env (open-input-string in) out #:passwords? passwords?)))
  (values code (get-output-string out) (get-output-string err)))

;; String ... -> Natural
(define (code-of #:in [in ""] . args)
  (define-values (code _o _e) (apply user #:in in args))
  code)

(module+ test
  (if (test-db-url)
      (run-tests (fresh-db!))
      (eprintf "SKIPPED user-cli-test: TEST_DATABASE_URL not set (use scripts/with-ephemeral-pg)\n")))

(define (run-tests c)
  (test-case "add stores a verified, lower-cased user whose password checks out"
    (define-values (code out err) (user #:in (string-append good-password "\n") "add" "Ann@Example.Org" "--name" "Ann"))
    (check-equal? code 0 err)
    (define cred (find-credential c "ann@example.org"))
    (check-equal? (check-password good-password (credential-hash cred)) 'ok)
    (check-false (string-contains? (string-append out err) good-password))
    (define-values (lcode lout _lerr) (user "list"))
    (check-equal? lcode 0)
    (check-equal? (cdr (string-split (string-trim lout) "\t")) '("ann@example.org" "active" "Ann")))

  (test-case "the name defaults to the local part of the address"
    (check-equal? (code-of #:in good-password "add" "bob@example.org") 0)
    (check-equal? (user-name (get-user c (credential-user-id (find-credential c "bob@example.org")))) "bob"))

  (test-case "a duplicate email exits 1 with a message, and leaves no half-made user"
    (define before (length (list-users c)))
    (define-values (code _o err) (user #:in good-password "add" "ANN@example.org"))
    (check-equal? code 1)
    (check-equal? err "a user with this email already exists\n")
    (check-equal? (length (list-users c)) before))

  (test-case "bad input is refused before the database changes"
    (define before (length (list-users c)))
    (check-equal? (code-of #:in "short" "add" "c@example.org") 1)
    (check-equal? (code-of #:in good-password "add" "not-an-email") 1)
    (check-equal? (code-of #:in good-password "add" "c@example.org" "--bogus") 2)
    (check-equal? (code-of "add") 2)
    (check-equal? (length (list-users c)) before))

  (test-case "passwd replaces the password and ends the user's sessions"
    (define id (credential-user-id (find-credential c "ann@example.org")))
    (define epoch (session-epoch c id))
    (check-equal? (code-of #:in "another long password\n" "passwd" "ANN@example.org") 0)
    (check-equal? (check-password "another long password" (credential-hash (find-credential c "ann@example.org"))) 'ok)
    (check-equal? (session-epoch c id) (add1 epoch))
    (check-equal? (code-of #:in "another long password" "passwd" "nobody@example.org") 1)
    (check-equal? (code-of #:in "short" "passwd" "ann@example.org") 1))

  (test-case "suspend ends sessions, activate restores the account but not the old sessions"
    (define id (credential-user-id (find-credential c "bob@example.org")))
    (define epoch (session-epoch c id))
    (check-equal? (code-of "suspend" "bob@example.org") 0)
    (check-equal? (user-status (get-user c id)) "suspended")
    (check-equal? (session-epoch c id) (add1 epoch))
    (check-equal? (code-of "activate" "Bob@example.org") 0)
    (check-equal? (user-status (get-user c id)) "active")
    (check-equal? (session-epoch c id) (add1 epoch))
    (check-equal? (code-of "suspend" "nobody@example.org") 1))

  (test-case "without passwords, suspend and list work and add refuses"
    (define-values (code _o _e) (user #:passwords? #f "suspend" "bob@example.org"))
    (check-equal? code 0)
    (check-equal? (code-of "activate" "bob@example.org") 0)
    (define-values (acode _ao _ae) (user #:passwords? #f #:in good-password "add" "z@example.org"))
    (check-equal? acode 2)
    (check-false (find-credential c "z@example.org"))))
