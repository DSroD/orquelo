#lang racket/base
;; Entity lookups for handlers: each returns the struct or raises the matching API error.
(require racket/contract/base
         "../auth/access.rkt" "../db/repo.rkt" "../domain.rkt" "../live/codes.rkt" "../live/hub.rkt" "../live/state.rkt" "../storage/store.rkt"
         "deps.rkt" "json.rkt")
(provide found
         (contract-out
          [need-presentation (-> deps? id/c presentation?)]
          [need-poll (-> deps? id/c poll?)]
          [need-deck (-> deps? user? id/c capability/c deck?)]
          [need-user-poll (-> deps? user? id/c capability/c poll?)]
          [need-user-session (-> deps? user? string? capability/c session?)]
          [need-user-mutable-session (-> deps? user? string? capability/c session?)]
          [need-public-session (-> deps? id/c string? session?)]
          [need-screen-session (-> deps? id/c string? session?)]
          [need-live (-> deps? string? live?)]
          [need-pdf (-> deps? id/c input-port?)]
          [need-presentation-of (-> deps? (or/c session? poll?) presentation?)]))

;; X String -> X
;; the value, or a 404 naming `what` when it is #f
(define (found v what) (or v (not-found! what)))

;; Deps Id -> Presentation
(define (need-presentation d id) (found (get-presentation (deps-db d) id) "presentation not found"))

;; Deps Id -> Poll
(define (need-poll d id) (found (get-poll (deps-db d) id) "poll not found"))

;; Deps String -> Session
;; the session with this code; 404 when the code is malformed or unknown
(define (need-session d code)
  (found (and (valid-code? code) (get-session (deps-db d) code)) "unknown session"))

;; Deps User Id String -> Deck
;; the deck as the user sees it; 404 (naming `what`) when they cannot see it
(define (visible-deck d me pid what) (found (get-deck (deps-db d) (user-id me) pid) what))

;; Deck Capability -> Deck
;; the deck itself, or 403 when the user's access lacks the capability
(define (allowing dk cap)
  (unless (access-allows? (deck-access dk) cap) (api-error! 403 "forbidden" "you do not have access to do that"))
  dk)

;; Deps User Id Capability -> Deck
;; 404 when the deck is not visible to the user, 403 when it is but they lack the capability
(define (need-deck d me id cap) (allowing (visible-deck d me id "presentation not found") cap))

;; Deps User Id Capability -> Poll
;; the poll, 404 unless its deck is visible to the user, then 403 without the capability
(define (need-user-poll d me id cap)
  (define pl (need-poll d id))
  (allowing (visible-deck d me (poll-presentation-id pl) "poll not found") cap)
  pl)

;; Deps User String Capability -> Session
;; the session with this code, 404 unless its deck is visible to the user, then 403 without the capability
(define (need-user-session d me code cap)
  (define s (need-session d code))
  (allowing (visible-deck d me (session-presentation-id s) "unknown session") cap)
  s)

;; Deps User String Capability -> Session
;; the same, then 410 once the session has ended: access is checked first, so a user without it learns nothing
(define (need-user-mutable-session d me code cap) (live-or-gone (need-user-session d me code cap)))

;; Session -> Session
;; the session itself, or 410 once it has ended
(define (live-or-gone s)
  (when (session-ended-at s) (api-error! 410 "session_ended" "this session has ended"))
  s)

;; Deps Id String -> Session
;; the live session of presentation pid; 404 on a mismatched code, 410 once ended
(define (need-public-session d pid code)
  (define s (need-session d code))
  (unless (= pid (session-presentation-id s)) (not-found! "unknown session"))
  (live-or-gone s))

;; Deps Id String -> Session
;; the live session of presentation pid whose projector code this is; 404 on an audience code
;; or any other mismatch, 410 once ended
(define (need-screen-session d pid screen-code)
  (define s (found (and (valid-code? screen-code) (get-session-by-screen-code (deps-db d) screen-code)) "unknown session"))
  (unless (= pid (session-presentation-id s)) (not-found! "unknown session"))
  (live-or-gone s))

;; Deps String -> Live
(define (need-live d code) (found (after-db d (λ () (hub-state (deps-hub d) code))) "unknown session"))

;; Deps (or Session Poll) -> Presentation
;; the presentation a session or poll belongs to
(define (need-presentation-of d x)
  (need-presentation d (if (session? x) (session-presentation-id x) (poll-presentation-id x))))

;; Deps Id -> InputPort
;; the stored PDF of the presentation, to be closed by the caller; 404 when it is missing in storage
(define (need-pdf d pid)
  (define key (presentation-pdf-key (deps-db d) pid))
  (found (and key (pdf-key? key) (store-open (deps-store d) key)) "pdf missing"))
