#lang racket/base
;; Public (participant / screen) handlers. Each is (name deps request pid code) -> response.
(require racket/contract/base racket/match web-server/http
         "../qa.rkt" "../db/qa.rkt" "../auth/session.rkt" "../db/repo.rkt" "../domain.rkt" "../edition.rkt" "../live/codes.rkt" "../live/hub.rkt" "../live/state.rkt" "../metrics/app.rkt"
         "deps.rkt" "endpoint.rkt" "inputs.rkt" "json.rkt" "lookup.rkt" "sse.rkt" "validate.rkt")
(provide (contract-out
          [session-info handler/id-code/c]
          [get-participant-choice (-> deps? request? response?)]
          [set-participant-choice (-> deps? request? response?)]
          [stream-public audience-handler/c]
          [cast-vote* audience-handler/c]
          [submit-question* audience-handler/c]
          [screen-info handler/id-code/c]
          [stream-screen handler/id-code/c]
          [slides-pdf handler/id-code/c]))

(define audience-handler/c
  (->* (deps? request? exact-integer? string?) (#:audience-limit audience-limit/c) response?))

;; Connection Id -> #f
;; self-hosted sessions have no audience cap
(define (unlimited _db _pid) #f)

;; Deps Request Id String (String [Listof Header] -> Response) -> Response
;; keeps an existing session identity even if the visitor changes their cookie choice
(define (with-participant d req pid code proc)
  (define cfg (deps-cfg d))
  (define existing (request-participant req code))
  (define id (or existing (remembered-participant req cfg) (random-uuid-v4)))
  (define retired (legacy-participant-headers req))
  (proc id (if existing retired (cons (participant-cookie id pid code cfg) retired))))

(define choice-headers (list (make-header #"Cache-Control" #"no-store")))

(define-endpoint (get-participant-choice d req)
  (json-response (hasheq 'remember (participant-cookie-choice req (deps-cfg d))) #:headers choice-headers))

(define-endpoint (set-participant-choice d req)
  #:json [in (participant-choice-input [remember (boolean)])]
  (define remember? (participant-choice-input-remember? in))
  (json-response (hasheq 'remember remember?)
                 #:headers (append choice-headers
                                   (list (participant-choice-cookie req (deps-cfg d) remember?))
                                   (legacy-participant-headers req))))

(define-endpoint (session-info d req pid code)
  #:need [s (public-session pid code)] [p (presentation pid)]
  (json-response (session-info->jsexpr p s)))

;; Deps String Role String [Listof Header] [#:audience-limit (or Natural #f)] -> Response
;; subscribes the audience or projector to this live session
(define (stream-as d code role participant headers #:audience-limit [limit #f])
  (define h (deps-hub d))
  (sse-response (λ () (hub-subscribe! h code role participant #:audience-limit limit))
                (λ (sb) (hub-unsubscribe! h code sb))
                #:headers headers
                #:on-delivery (λ (secs) (observe-delivery! (deps-metrics d) role secs))))

;; Deps Request Id String [#:audience-limit AudienceLimit] -> Response
;; serves the audience stream after validating its session and role
(define (stream-public d req pid code #:audience-limit [audience-limit unlimited])
  (stream-audience d req pid code audience-limit))

;; Deps Request Id String AudienceLimit -> Response
;; finds the applicable capacity before the response releases its database connection
(define-endpoint (stream-audience d req pid code audience-limit)
  #:need [s (public-session pid code)]
  (unless (equal? (query-param req 'role) "audience") (api-error! 400 "bad_request" "role must be audience"))
  (with-participant d req pid code
    (λ (participant headers)
      (stream-as d code 'audience participant headers #:audience-limit (audience-limit (deps-db d) pid)))))

;; Deps Id String String AudienceLimit -> Void
;; a capped session accepts votes and questions only from participants with a seat
(define (require-audience-seat! d pid code participant audience-limit)
  (when (audience-limit (deps-db d) pid)
    (unless (after-db d (λ () (hub-audience-present? (deps-hub d) code participant)))
      (api-error! 403 "audience_not_joined" "Join the live audience to participate."))))

;; Same as session-info, behind the screen code
(define-endpoint (screen-info d req pid screen-code)
  #:need [s (screen-session pid screen-code)] [p (presentation pid)]
  (json-response (session-info->jsexpr p s)))

(define-endpoint (stream-screen d req pid screen-code)
  #:need [s (screen-session pid screen-code)]
  (stream-as d (session-code s) 'screen (random-uuid-v4) '()))

;; Connection Id [Listof Id] -> Void
;; a single-choice poll takes exactly one option
(define (check-choice-count! c run-id ids)
  (when (and (equal? (run-poll-kind c run-id) "single") (> (length ids) 1))
    (invalid! 'option_ids "a single-choice poll takes one option")))

;; Deps Request Id String [#:audience-limit AudienceLimit] -> Response
;; records the participant's vote
(define (cast-vote* d req pid code #:audience-limit [audience-limit unlimited])
  (cast-audience-vote d req pid code audience-limit))

;; Deps Request Id String AudienceLimit -> Response
;; validates the vote and checks admission before writing it
(define-endpoint (cast-audience-vote d req pid code audience-limit)
  #:need [s (public-session pid code)]
  #:json [in (vote-input [run-id (id)] [option-ids (distinct-integers)])]
  (match-define (vote-input run-id ids) in)
  (check-choice-count! (deps-db d) run-id ids)
  (with-participant d req pid code
    (λ (participant headers)
      (require-audience-seat! d pid code participant audience-limit)
      (define result (cast-vote! (deps-db d) run-id code pid participant ids))
      (count-vote! (deps-metrics d) (if (memq result '(ok invalid)) result 'not-open))
      (match result
        ['ok
         (after-db d (λ () (hub-apply! (deps-hub d) code (vote-cast run-id participant ids))))
         (json-response (vote-receipt->jsexpr run-id ids) #:headers headers)]
        ['invalid (invalid! 'option_ids "choose valid options; an exclusive answer must be selected alone")]
        [_ (api-error! 409 "poll_not_open" "this poll is not open")]))))

(define-endpoint (slides-pdf d req pid screen-code)
  #:need [s (screen-session pid screen-code)]
  (define in (need-pdf d pid))
  (pdf-response in (list (make-header #"Cache-Control" #"private, max-age=3600"))))

;; Deps Request Id String [#:audience-limit AudienceLimit] -> Response
;; accepts a private participant question while this session permits submissions
(define (submit-question* d req pid code #:audience-limit [audience-limit unlimited])
  (submit-audience-question d req pid code audience-limit))

;; Deps Request Id String AudienceLimit -> Response
;; validates the question and checks admission before writing it
(define-endpoint (submit-audience-question d req pid code audience-limit)
  #:need [s (public-session pid code)]
  #:json [in (qa-text-input [text (string 1 1000)])]
  (with-participant d req pid code
    (λ (participant headers)
      (require-audience-seat! d pid code participant audience-limit)
      (match (submit-question! (deps-db d) (session-id s) participant (qa-text-input-text in))
        ['closed (api-error! 409 "qa_not_open" "Q&A submissions are closed")]
        ['disabled (api-error! 409 "qa_disabled" "Q&A is not enabled")]
        ['ended (api-error! 410 "session_ended" "this lecture has ended")]
        ['too-fast (api-error! 429 "qa_rate_limited" "wait 10 seconds between questions")]
        ['limit (api-error! 429 "qa_question_limit" "you have reached 20 questions in this session")]
        ['invalid (invalid! 'text "question must contain 1 to 1000 non-blank characters")]
        ['not-found (not-found! "unknown session")]
        [q
         (define qa (get-qa (deps-db d) (session-id s)))
         (after-db d (λ () (hub-apply! (deps-hub d) code (qa-synced qa))))
         (json-response (qa-question->jsexpr q) #:status 201 #:headers headers)]))))
