#lang racket/base
;; Session-owned questions; participant identity never belongs in public encoders.
(require racket/contract/base)
(provide qa-status/c
         (contract-out
          [struct qa-overlay ([question-id (or/c exact-nonnegative-integer? #f)])]
          [struct qa-question ([id exact-nonnegative-integer?] [body string?] [status qa-status/c] [created-at string?]
                               [updated-at string?] [participant string?])]
          [struct qa-state ([enabled? boolean?] [open? boolean?] [on-screen? boolean?]
                            [selected-id (or/c exact-nonnegative-integer? #f)] [questions (listof qa-question?)] [started? boolean?])]))

;; A QaStatus is "pending", "answered" or "dismissed": the moderator's disposition.
(define qa-status/c (or/c "pending" "answered" "dismissed"))

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
