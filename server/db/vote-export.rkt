#lang racket/base
(require racket/contract/base racket/match db "query.rkt" "../domain.rkt")
(provide (contract-out [export-votes (-> connection? id/c (listof exported-vote?))]))

;; Vector -> ExportedVote
;; decodes one option selection, including polls without an assigned slide
(define (row->exported-vote row)
  (match-define (vector code label title rid opened pid slide question kind idx answer participant voted) row)
  (exported-vote code label title rid opened pid (if (sql-null? slide) #f slide)
                 question kind idx answer participant voted))

;; Connection Id -> [Listof ExportedVote]
;; reads the recorded selections for a session in export order
(define-query (export-votes c session-id) #:rows row->exported-vote
  "SELECT session_code, session_label, presentation_title, run_id, iso(run_opened_at), poll_id, slide, question, kind, option_idx, option_label, participant_id::text, iso(voted_at)
   FROM analysis_votes WHERE session_id=$1 ORDER BY run_opened_at, participant_id, option_idx")
