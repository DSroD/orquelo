#lang racket/base
;; Gauges describing the live hub, computed at scrape time from a HubStats.
(require racket/contract/base "registry.rkt" "../live/hub.rkt")
(provide (contract-out [hub-families (-> hub-stats? (listof family?))]))

;; String String [Listof (Pair [Listof (Pair String String)] Real)] -> Family
;; a gauge from (labels . value) pairs
(define (gauge name help points)
  (family name help 'gauge (for/list ([p points]) (sample "" (car p) (cdr p)))))

;; HubStats -> [Listof Family]
(define (hub-families st)
  (list (gauge "orquelo_sse_connections" "Open SSE subscriptions by role"
               `((,(list (cons "role" "audience")) . ,(hub-stats-audience st))
                 (,(list (cons "role" "screen")) . ,(hub-stats-screen st))
                 (,(list (cons "role" "moderator")) . ,(hub-stats-moderator st))))
        (gauge "orquelo_sessions" "Sessions in the hub by state (loaded, or live: not ended)"
               `((,(list (cons "state" "loaded")) . ,(hub-stats-loaded st))
                 (,(list (cons "state" "live")) . ,(hub-stats-live st))))
        (gauge "orquelo_runs_open" "Sessions with a poll run open" `((() . ,(hub-stats-runs-open st))))))

(module+ test
  (require rackunit)
  (test-case "hub stats become gauges"
    (define out (render-families (hub-families (hub-stats 3 2 1 10 1 2))))
    (check-regexp-match #rx"orquelo_sse_connections{role=\"audience\"} 10\n" out)
    (check-regexp-match #rx"orquelo_sse_connections{role=\"moderator\"} 2\n" out)
    (check-regexp-match #rx"orquelo_sessions{state=\"live\"} 2\n" out)
    (check-regexp-match #rx"\norquelo_runs_open 1\n" out)))
