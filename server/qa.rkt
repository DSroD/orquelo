#lang racket/base
;; Session-owned questions; participant identity never belongs in public encoders.
(require racket/contract/base racket/string "domain/parse.rkt")
(provide qa-status/c
         (contract-out
          [struct question-text ([value string?])]
          [make-question-text (-> any/c question-text?)]
          [struct qa-overlay ([question-id (or/c exact-nonnegative-integer? #f)])]
          [struct qa-question ([id exact-nonnegative-integer?] [body string?] [status qa-status/c] [created-at string?]
                               [updated-at string?] [participant string?])]
          [struct qa-state ([enabled? boolean?] [open? boolean?] [on-screen? boolean?]
                            [selected-id (or/c exact-nonnegative-integer? #f)] [questions (listof qa-question?)] [started? boolean?])]))

;; A QaStatus is "pending", "answered" or "dismissed": the moderator's disposition.
(define qa-status/c (or/c "pending" "answered" "dismissed"))

;; Any Symbol -> String
;; constructs normalized text that is safe to submit without further content checks
(define (parse-question-text raw _)
  (unless (and (string? raw) (<= 1 (string-length raw) 1000))
    (domain-error! 'text "text must be a string of 1 to 1000 characters"))
  (define text (string-trim raw))
  (when (string=? text "")
    (domain-error! 'text "question must contain 1 to 1000 non-blank characters"))
  (string->immutable-string text))

;; A QuestionText is a (question-text String).
;; interp. normalized, nonblank question text from input of at most 1000 characters.
(struct question-text (value) #:transparent #:guard parse-question-text)

;; Any -> QuestionText
;; parses untrusted text into a trusted submission value
(define (make-question-text raw) (question-text raw))

;; A QaOverlay is a (qa-overlay (or Id #f)).
;; interp. the generic Q&A screen, or the id of the one question selected for projection.
(struct qa-overlay (question-id) #:transparent)

;; A QaQuestion is a (qa-question Id String QaStatus Time Time String).
;; interp. a private submission, associated with its browser participant UUID.
(struct qa-question (id body status created-at updated-at participant) #:transparent)

;; A QaState is a (qa-state Boolean Boolean Boolean (or Id #f) [Listof QaQuestion] Boolean).
;; interp. availability captured at session start, submission and projector controls, and the inbox.
;; selected-id is #f for the generic Q&A screen; on-screen? distinguishes it from another overlay.
(struct qa-state (enabled? open? on-screen? selected-id questions started?) #:transparent)

(module+ test
  (require rackunit)
  (test-case "question text is normalized and bounded at construction"
    (check-equal? (question-text-value (make-question-text " \n Why? \t ")) "Why?")
    (check-equal? (string-length (question-text-value (question-text (make-string 1000 #\a)))) 1000)
    (for ([raw (list #f "" " \n\t " (make-string 1001 #\a)
                     (string-append "Q" (make-string 1000 #\space)))])
      (check-exn exn:domain? (λ () (make-question-text raw))))
    (check-exn exn:domain? (λ () (struct-copy question-text (question-text "Q") [value " "]))))
  (test-case "question text cannot change after construction"
    (define raw (string-copy "Why?"))
    (define text (question-text raw))
    (string-fill! raw #\space)
    (check-equal? (question-text-value text) "Why?")
    (check-true (immutable? (question-text-value text)))))
