#lang racket/base
;; Parsed request bodies. define-endpoint's #:json / #:form clauses build these from the raw body.
(require racket/contract/base "../domain.rkt" "../qa.rkt")
(provide (contract-out
          [struct title-input ([title string?])]
          [struct label-input ([label string?])]
          [struct slide-input ([slide id/c])]
          [struct open-input ([poll-id id/c] [only-if-idle? boolean?])]
          [struct resume-input ([run-id id/c])]
          [struct rotation-input ([run-id id/c] [revealed? boolean?] [action string?])]
          [struct screen-page-input ([viewer string?] [run-id id/c] [revealed? boolean?] [open? boolean?] [page id/c] [total id/c])]
          [struct overlay-input ([overlay (or/c qr-overlay? qa-overlay? id/c #f)])]
          [struct qa-enabled-input ([enabled? boolean?])]
          [struct qa-open-input ([open? boolean?])]
          [struct qa-status-input ([status string?])]
          [struct qa-text-input ([text question-text?])]
          [struct run-option-input ([run-id id/c] [label string?] [exclusive? boolean?])]
          [struct share-input ([edit? boolean?] [moderate? boolean?] [copy? boolean?] [results? boolean?])]
          [struct show-results-input ([show-results? boolean?])]
          [struct participant-choice-input ([remember? boolean?])]
          [struct vote-input ([run-id id/c] [option-ids (listof id/c)])]
          [struct upload-input ([title string?] [page-count id/c] [pdf input-port?])]
          [struct login-input ([email string?] [password string?])]
          [struct password-change-input ([current string?] [new string?])]))

;; Each input is a struct of the validated fields of one request body:
;; A TitleInput is a (title-input String): a new presentation title.
(struct title-input (title))
;; A LabelInput is a (label-input String): a session label, "" when absent.
(struct label-input (label))
;; A SlideInput is a (slide-input Id): the slide to show.
(struct slide-input (slide))
;; An OpenInput is an (open-input Id Boolean): the poll to open and whether to refuse replacement.
(struct open-input (poll-id only-if-idle?))
;; A ResumeInput is a (resume-input Id): the run to reopen.
(struct resume-input (run-id))
;; A RotationInput is a (rotation-input Id Boolean String): a page command for the displayed poll.
(struct rotation-input (run-id revealed? action))
;; A ScreenPageInput is a (screen-page-input String Id Boolean Boolean Id Id): a viewer's current poll page.
(struct screen-page-input (viewer run-id revealed? open? page total))
;; An OverlayInput is an (overlay-input (or QrOverlay Id #f)): the overlay to show, #f = none; an Id asks
;; for the poll overlay of that run.
(struct overlay-input (overlay))
;; A ShowResultsInput is a (show-results-input Boolean): the poll's "show results when it starts" setting.
(struct show-results-input (show-results?))
;; A ShareInput is a (share-input Boolean Boolean Boolean Boolean): the flags granted: edit? moderate? copy? results?.
(struct share-input (edit? moderate? copy? results?))
;; A VoteInput is a (vote-input Id [Listof Id]): the run voted on and the options picked.
(struct vote-input (run-id option-ids))
;; An UploadInput is an (upload-input String Id InputPort): title, page count and the PDF bytes.
(struct upload-input (title page-count pdf))

;; A LoginInput is a (login-input String String): the email and password of a password login.
(struct login-input (email password))
;; A PasswordChangeInput is a (password-change-input String String): the current and the new password.
(struct password-change-input (current new))

;; A QaEnabledInput is a (qa-enabled-input Boolean): whether new sessions may use Q&A.
(struct qa-enabled-input (enabled?))
;; A QaOpenInput is a (qa-open-input Boolean): whether submissions are accepted.
(struct qa-open-input (open?))
;; A QaStatusInput is a (qa-status-input String): a moderator's question disposition.
(struct qa-status-input (status))
;; A QaTextInput is a (qa-text-input QuestionText): an audience question.
(struct qa-text-input (text))
;; A RunOptionInput is a (run-option-input Id String Boolean): an option appended to an open run.
(struct run-option-input (run-id label exclusive?))

;; A ParticipantChoiceInput is a (participant-choice-input Boolean): whether to remember the browser across sessions.
(struct participant-choice-input (remember?))
