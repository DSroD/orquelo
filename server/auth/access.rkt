#lang racket/base
;; What a user may do with a deck. Pure: the caller's share is looked up elsewhere (db/repo.rkt).
(require racket/contract/base "../domain.rkt")
(provide capabilities capability/c
         (contract-out
          [access-for (-> id/c id/c (or/c share? #f) access?)]
          [access-allows? (-> access? capability/c boolean?)]))

;; A Capability is one of 'view 'edit 'moderate 'copy 'results 'owner
(define capabilities '(view edit moderate copy results owner))
(define capability/c (apply or/c capabilities))

;; Id Id (or Share #f) -> Access
;; the owner may do everything; otherwise a share grants view plus each flag it sets
(define (access-for user-id owner-id share)
  (cond
    [(= user-id owner-id) (access #t #t #t #t #t #t)]
    [share (access #f #t (share-edit? share) (share-moderate? share) (share-copy? share) (share-results? share))]
    [else (access #f #f #f #f #f #f)]))

;; Access Capability -> Boolean
(define (access-allows? a cap)
  (case cap
    [(view) (access-view? a)]
    [(edit) (access-edit? a)]
    [(moderate) (access-moderate? a)]
    [(copy) (access-copy? a)]
    [(results) (access-results? a)]
    [(owner) (access-owner? a)]))

(module+ test
  (require rackunit)
  (define (flags a) (list (access-owner? a) (access-view? a) (access-edit? a) (access-moderate? a)
                          (access-copy? a) (access-results? a)))
  (test-case "the owner may do everything, shared or not"
    (check-equal? (flags (access-for 1 1 #f)) '(#t #t #t #t #t #t))
    (check-equal? (flags (access-for 1 1 (share "a@b" #f #f #f #f))) '(#t #t #t #t #t #t)))
  (test-case "a stranger may do nothing"
    (check-equal? (flags (access-for 2 1 #f)) '(#f #f #f #f #f #f)))
  (test-case "any share gives view; each flag comes only from itself"
    (check-equal? (flags (access-for 2 1 (share "a@b" #f #f #f #f))) '(#f #t #f #f #f #f))
    (check-equal? (flags (access-for 2 1 (share "a@b" #t #f #f #f))) '(#f #t #t #f #f #f))
    (check-equal? (flags (access-for 2 1 (share "a@b" #f #t #f #f))) '(#f #t #f #t #f #f))
    (check-equal? (flags (access-for 2 1 (share "a@b" #f #f #t #f))) '(#f #t #f #f #t #f))
    (check-equal? (flags (access-for 2 1 (share "a@b" #f #f #f #t))) '(#f #t #f #f #f #t)))
  (test-case "access-allows? maps capabilities to flags"
    (define a (access-for 2 1 (share "a@b" #f #t #f #f)))
    (check-equal? (for/list ([c capabilities]) (access-allows? a c)) '(#t #f #t #f #f #f))))
