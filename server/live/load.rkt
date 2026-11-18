#lang racket/base
;; Glue between the repo, config and the live state: lazy state loading and public URLs.
(require racket/contract/base "../config.rkt" "../db/repo.rkt" "../db/qa.rkt" "../domain.rkt" "state.rkt" db/base)
(provide (contract-out
          [make-session-view (-> config? session? session-view?)]
          [make-loader (-> connection? config? (-> string? (or/c live? #f)))]
          [make-peak-recorder (-> connection? (-> string? peaks? void?))]))

;; Config Id String -> String
(define (audience-url cfg pid code) (format "~a/~a/~a" (config-public-base-url cfg) pid code))

;; Config Id String -> String
(define (screen-url cfg pid code) (format "~a/screen/~a/~a" (config-public-base-url cfg) pid code))

;; Config Session -> SessionView
;; the session with its public URLs
(define (make-session-view cfg s)
  (define pid (session-presentation-id s))
  (session-view s (audience-url cfg pid (session-code s)) (screen-url cfg pid (session-screen-code s))))

;; Connection Config -> [String -> (or Live #f)]
;; loads a session's state by code; on (re)load the overlay is the poll of an open run (revealed as stored).
;; It runs on the hub's manager thread, which would keep its pooled connection for good, so the
;; connection is released after each load.
(define (make-loader conn cfg)
  (λ (code)
    (dynamic-wind
     void
     (λ () (load-state conn cfg code))
     (λ () (disconnect conn)))))

;; Connection Config String -> (or Live #f)
;; the state of the session with the code, #f when there is none
(define (load-state conn cfg code)
  (define s (get-session conn code))
  (and s
       (let ([pid (session-presentation-id s)] [runs (session-runs conn (session-id s))])
         (initial-state s (get-presentation conn pid) runs (and (pair? runs) (run-results-shown? conn (poll-run-id (car runs))))
                        (audience-url cfg pid code) (screen-url cfg pid (session-screen-code s)) (get-qa conn (session-id s))))))

;; Connection -> [String Peaks -> Void]
;; stores a session's peak audiences (never lowering them). The connection is a pool: it is released
;; after each write, so the hub's ticker thread does not keep a connection while idle.
(define (make-peak-recorder conn)
  (λ (code p)
    (dynamic-wind
     void
     (λ () (record-peaks! conn code (peaks-session p) (peaks-run-id p) (peaks-run p)))
     (λ () (disconnect conn)))))
