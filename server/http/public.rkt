#lang racket/base
;; Public (participant / screen) handlers. Each is (name deps request pid code) -> response.
(require racket/contract/base racket/match web-server/http
         "../qa.rkt" "../db/qa.rkt" "../auth/session.rkt" "../db/repo.rkt" "../domain.rkt" "../live/codes.rkt" "../live/hub.rkt" "../live/state.rkt" "../metrics/app.rkt"
         "deps.rkt" "endpoint.rkt" "inputs.rkt" "json.rkt" "lookup.rkt" "sse.rkt" "validate.rkt")
(provide (contract-out
          [session-info handler/id-code/c]
          [stream-public handler/id-code/c]
          [cast-vote* handler/id-code/c]
          [submit-question* handler/id-code/c]
          [screen-info handler/id-code/c]
          [stream-screen handler/id-code/c]
          [slides-pdf handler/id-code/c]))

;; Deps Request (String [Listof Header] -> Response) -> Response
;; runs (proc participant-id extra-headers); sets the participant cookie when the request has none
(define (with-participant d req proc)
  (define existing (request-participant req))
  (define id (or existing (random-uuid-v4)))
  (proc id (if existing '() (list (participant-cookie id (deps-cfg d))))))

(define-endpoint (session-info d req pid code)
  #:need [s (public-session pid code)] [p (presentation pid)]
  (with-participant d req
    (λ (_ headers) (json-response (session-info->jsexpr p s) #:headers headers))))

;; Deps Request String Role -> Response
;; the SSE stream of the session `code` for the role
(define (stream-as d req code role)
  (with-participant d req
    (λ (participant headers)
      (define h (deps-hub d))
      (sse-response (λ () (hub-subscribe! h code role participant))
                    (λ (sb) (hub-unsubscribe! h code sb))
                    #:headers headers
                    #:on-delivery (λ (secs) (observe-delivery! (deps-metrics d) role secs))))))

;; The audience stream never serves the screen role: that one needs the screen code.
(define-endpoint (stream-public d req pid code)
  #:need [s (public-session pid code)]
  (unless (equal? (query-param req 'role) "audience") (api-error! 400 "bad_request" "role must be audience"))
  (stream-as d req code 'audience))

;; Same as session-info, behind the screen code
(define-endpoint (screen-info d req pid screen-code)
  #:need [s (screen-session pid screen-code)] [p (presentation pid)]
  (json-response (session-info->jsexpr p s)))

(define-endpoint (stream-screen d req pid screen-code)
  #:need [s (screen-session pid screen-code)]
  (stream-as d req (session-code s) 'screen))

;; Connection Id [Listof Id] -> Void
;; a single-choice poll takes exactly one option
(define (check-choice-count! c run-id ids)
  (when (and (equal? (run-poll-kind c run-id) "single") (> (length ids) 1))
    (invalid! 'option_ids "a single-choice poll takes one option")))

(define-endpoint (cast-vote* d req pid code)
  #:need [s (public-session pid code)]
  #:json [in (vote-input [run-id (id)] [option-ids (distinct-integers)])]
  (match-define (vote-input run-id ids) in)
  (check-choice-count! (deps-db d) run-id ids)
  (with-participant d req
    (λ (participant headers)
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
  (with-participant d req
    (λ (_ headers) (pdf-response in (cons (make-header #"Cache-Control" #"private, max-age=3600") headers)))))

;; Deps Request Id String -> Response
;; accepts a private participant question while this session permits submissions.
(define-endpoint (submit-question* d req pid code)
  #:need [s (public-session pid code)]
  #:json [in (qa-text-input [text (string 1 1000)])]
  (with-participant d req
    (λ (participant headers)
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
