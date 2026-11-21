#lang racket/base
;; Everything the handlers need.
(require racket/contract/base db/base web-server/http "../config.rkt" "../db/repo.rkt" "../domain.rkt" "../live/hub.rkt" "../metrics/app.rkt" "../storage/store.rkt")
;; the contracts of the endpoint handlers by the path arguments they take: none, a numeric id (a
;; presentation or poll), a session code, an id and a code, or (signed-in only) an id and a string such as
;; an email. The user variants also take the logged-in user, resolved by the route guard.
(provide current-deck-disabled? current-deck-removed!
         handler/c handler/id/c handler/code/c handler/id-code/c
         user-handler/c user-handler/id/c user-handler/code/c user-handler/id-string/c
         (contract-out [struct deps ([cfg config?] [db connection?] [hub hub?] [metrics app-metrics?] [store store?] [limits limits-of/c])]
                       [after-db (-> deps? (-> any) any)]))

;; Deps is a (deps Config Connection Hub AppMetrics Store LimitsOf)
;; interp. the configuration, the database connection (pool), the live hub, the application metrics, the
;; PDF storage and the function giving the limits of a user.
(struct deps (cfg db hub metrics store limits))

;; Defaults preserve standalone behavior. The edition binds them during request dispatch.
(define current-deck-disabled? (make-parameter (λ (_c _id) #f)))
(define current-deck-removed! (make-parameter (λ (_c _owner-id) (void))))

(define handler/c (-> deps? request? response?))
(define handler/id/c (-> deps? request? exact-integer? response?))
(define handler/code/c (-> deps? request? string? response?))
(define handler/id-code/c (-> deps? request? exact-integer? string? response?))
(define user-handler/c (-> deps? request? user? response?))
(define user-handler/id/c (-> deps? request? user? exact-integer? response?))
(define user-handler/code/c (-> deps? request? user? string? response?))
(define user-handler/id-string/c (-> deps? request? user? exact-integer? string? response?))

;; Deps (-> X) -> X
;; releases the thread's pooled database connection, then runs the thunk. Hub calls go through
;; here: they can queue for seconds behind other sessions, and a lease held meanwhile starves the pool.
;; The next query leases again.
(define (after-db d thunk)
  (disconnect (deps-db d))
  (thunk))
