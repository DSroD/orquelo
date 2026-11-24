#lang racket/base
;; A pure model of the OAuth grant lifecycle, the oracle for the model-based test in
;; lifecycle-check.rkt (test-only: never required from main.rkt). It follows server.rkt and store.rkt
;; as written: the timing of the periodic sweep, what a sweep drops and when, replay revocation,
;; the 90 day grant lifetime and its clamp of token expiry. Nothing here knows about HTTP or storage.
;;
;; Subjects and clients are slot numbers 0 and 1; the driver maps them to real subjects and client
;; ids. Everything a command refers to (a code, a token, a grant) is a position in a pool of
;; everything of that kind ever issued, taken modulo the pool's size, so a command can name a
;; credential that has expired, been used, or been revoked.
(require racket/contract/base racket/list racket/match)
(provide
 (contract-out
  [struct connect ([subject exact-nonnegative-integer?] [client exact-nonnegative-integer?] [requested exact-nonnegative-integer?] [kept exact-nonnegative-integer?])]
  [struct exchange ([pick exact-nonnegative-integer?] [variant (or/c 'ok 'bad-verifier 'bad-client 'bad-redirect)])]
  [struct refresh ([token exact-nonnegative-integer?] [variant (or/c 'ok 'other-client)])]
  [struct use ([token exact-nonnegative-integer?])]
  [struct revoke ([grant exact-nonnegative-integer?] [other-subject? boolean?])]
  [struct bump ([subject exact-nonnegative-integer?])]
  [struct wait ([seconds exact-nonnegative-integer?])]
  [struct sweep ()]
  [struct register ([client exact-nonnegative-integer?])]
  [struct flip ([client exact-nonnegative-integer?])]
  [struct mclient ([exists? boolean?] [created exact-integer?] [refresh? boolean?])]
  [struct mgrant ([id exact-nonnegative-integer?] [subject exact-nonnegative-integer?] [client exact-nonnegative-integer?] [scopes (listof string?)]
                  [epoch exact-nonnegative-integer?] [created exact-integer?] [last-used (or/c exact-integer? #f)])]
  [struct mcode ([id exact-nonnegative-integer?] [grant exact-nonnegative-integer?] [expires exact-integer?] [used-at (or/c exact-integer? #f)])]
  [struct mtoken ([id exact-nonnegative-integer?] [grant exact-nonnegative-integer?] [kind (or/c 'access 'refresh)] [scopes (listof string?)]
                  [expires exact-integer?] [retired? boolean?])]
  [struct model ([now exact-integer?] [last-sweep (or/c exact-integer? #f)]
                 [epochs (hash/c exact-nonnegative-integer? exact-nonnegative-integer?)] [clients (hash/c exact-nonnegative-integer? mclient?)]
                 [grants (hash/c exact-nonnegative-integer? mgrant?)] [all-grants (hash/c exact-nonnegative-integer? mgrant?)]
                 [codes (hash/c exact-nonnegative-integer? mcode?)] [tokens (hash/c exact-nonnegative-integer? mtoken?)]
                 [grant-pool (listof exact-nonnegative-integer?)] [code-pool (listof exact-nonnegative-integer?)]
                 [access-pool (listof exact-nonnegative-integer?)] [refresh-pool (listof exact-nonnegative-integer?)]
                 [next-id exact-nonnegative-integer?])]
  [initial-model (-> exact-integer? model?)]
  [model-step (-> model? any/c (values model? symbol?))]
  [command-target (-> model? any/c (or/c exact-nonnegative-integer? #f))]
  [revoke-subject (-> model? revoke? exact-nonnegative-integer?)]
  [connect-scopes (-> connect? (values (listof string?) (listof string?)))]
  [tokened-grants (-> model? (listof mgrant?))]
  [current? (-> model? mgrant? boolean?)]
  [wait-durations (listof exact-nonnegative-integer?)]))

;; A Command is one of
;;   (connect Natural Natural Natural Natural)   authorize and approve: subject, client, which scopes to ask
;;                                               for, which of them the user keeps
;;   (exchange Natural Variant)                  trade a code, honestly or with a wrong detail
;;   (refresh Natural Variant)                   trade a refresh token, as its client or as the other one
;;   (use Natural)                               present an access token to the resource server
;;   (revoke Natural Boolean)                    the user disconnects a grant (or a stranger tries)
;;   (bump Natural)                              the subject's epoch moves on (password reset)
;;   (wait Natural)                              seconds pass
;;   (sweep)                                     the periodic cleanup runs now
;;   (register Natural)                          the client is (re)registered now
;;   (flip Natural)                              the registered client's right to refresh is toggled
(struct connect (subject client requested kept) #:transparent)
(struct exchange (pick variant) #:transparent)
(struct refresh (token variant) #:transparent)
(struct use (token) #:transparent)
(struct revoke (grant other-subject?) #:transparent)
(struct bump (subject) #:transparent)
(struct wait (seconds) #:transparent)
(struct sweep () #:transparent)
(struct register (client) #:transparent)
(struct flip (client) #:transparent)

;; A ModelClient is an (mclient Boolean Integer Boolean): whether the store has it, when it was
;; registered, whether it may hold refresh tokens
(struct mclient (exists? created refresh?) #:transparent)
;; A ModelGrant is an (mgrant Natural Natural Natural (listof String) Natural Integer (or Integer #f)):
;; id, subject, client, scopes, epoch, created, last used
(struct mgrant (id subject client scopes epoch created last-used) #:transparent)
;; A ModelCode is an (mcode Natural Natural Integer (or Integer #f)): id, grant, expiry, when it was used
(struct mcode (id grant expires used-at) #:transparent)
;; A ModelToken is an (mtoken Natural Natural (or 'access 'refresh) (listof String) Integer Boolean):
;; id, grant, kind, scopes, expiry, whether a refresh token has been used up
(struct mtoken (id grant kind scopes expires retired?) #:transparent)

;; A Model is a (model Integer (or Integer #f) epochs clients grants all-grants codes tokens
;;                     grant-pool code-pool access-pool refresh-pool Natural)
;; the clock, the time of the last periodic sweep, each subject's epoch, the client slots, the live
;; grants, every grant ever made, the live codes and tokens (by id), the pools of ids in order of
;; issue, and the next id to hand out
(struct model (now last-sweep epochs clients grants all-grants codes tokens
                   grant-pool code-pool access-pool refresh-pool next-id)
  #:transparent)

;; The lifetimes, written out again here rather than imported: the model is the specification
(define code-ttl 60)
(define access-ttl 3600)
(define refresh-ttl (* 30 24 3600))
(define grant-lifetime (* 90 24 3600))
(define token-less-grant-lifetime (* 15 60))
(define used-code-retention (* 24 3600))
(define registered-client-lifetime (* 24 3600))
(define sweep-interval 600)
(define touch-interval 300)

;; (listof Natural)
;; waits worth trying: around each boundary above, with a few common small ones
(define wait-durations
  (list 1 5 30 59 60 61 120 299 300 301 599 600 601 899 900 901 3599 3600 3601 86399 86400 86401
        (sub1 refresh-ttl) refresh-ttl (add1 refresh-ttl)
        (sub1 grant-lifetime) grant-lifetime (add1 grant-lifetime)))

(define app-scopes '("decks" "results"))
;; (listof (listof String))
;; what a request can ask for, in the app's order
(define request-options '(("decks") ("results") ("decks" "results")))

;; Integer -> Model
;; both clients registered at `now`, the first may refresh; every epoch 0
(define (initial-model now)
  (model now #f (hash) (hash 0 (mclient #t now #t) 1 (mclient #t now #f)) (hash) (hash) (hash) (hash)
         '() '() '() '() 0))

;; (listof A) -> (listof (listof A))
;; the non-empty sublists, keeping the order
(define (nonempty-sublists xs)
  (define (all xs) (if (null? xs) '(()) (let ([r (all (cdr xs))]) (append (map (λ (s) (cons (car xs) s)) r) r))))
  (filter pair? (all xs)))

;; (listof A) Natural -> A
;; the element at the index taken modulo the length
(define (cycle-ref xs i) (list-ref xs (modulo i (length xs))))

;; Connect -> (values (listof String) (listof String))
;; the scopes the request asks for and those the user keeps (a non-empty part of them)
(define (connect-scopes c)
  (define requested (cycle-ref request-options (connect-requested c)))
  (values requested (cycle-ref (nonempty-sublists requested) (connect-kept c))))

;; (listof Natural) Natural -> (or Natural #f)
;; the pool's element at the index modulo its size, #f for an empty pool
(define (pool-ref pool i) (and (pair? pool) (cycle-ref pool i)))

;; Model Command -> (or Natural #f)
;; the id of the code, token or grant the command is about; #f when there is none
(define (command-target m cmd)
  (match cmd
    [(exchange i _) (pool-ref (model-code-pool m) i)]
    [(refresh i _) (pool-ref (model-refresh-pool m) i)]
    [(use i) (pool-ref (model-access-pool m) i)]
    [(revoke i _) (pool-ref (model-grant-pool m) i)]
    [_ #f]))

;; Model Revoke -> Natural
;; the subject the revoke is made as: the grant's own, or the other one
(define (revoke-subject m cmd)
  (define g (hash-ref (model-all-grants m) (command-target m cmd)))
  (if (revoke-other-subject? cmd) (- 1 (mgrant-subject g)) (mgrant-subject g)))

;; Model -> (listof ModelGrant)
;; the grants that were used at least once: the connected apps `subject-grants` lists
(define (tokened-grants m) (filter mgrant-last-used (hash-values (model-grants m))))

;; Model ModelGrant -> Boolean
;; does the grant's epoch match its subject's?
(define (current? m g) (= (mgrant-epoch g) (hash-ref (model-epochs m) (mgrant-subject g) 0)))

;; ---------------------------------------------------------------------------------------------
;; Housekeeping

;; Model -> Model
;; the model after a sweep at its current time: what store.rkt `sweep!` drops
(define (sweep-model m)
  (define now (model-now m))
  (define (expired? t) (<= t now))
  (define codes
    (for/hash ([(id c) (in-hash (model-codes m))]
               #:unless (and (expired? (mcode-expires c))
                             (or (not (mcode-used-at c)) (expired? (+ (mcode-used-at c) used-code-retention)))))
      (values id c)))
  (define tokens (for/hash ([(id t) (in-hash (model-tokens m))] #:unless (expired? (mtoken-expires t))) (values id t)))
  (define with-tokens (for/hash ([t (in-hash-values tokens)]) (values (mtoken-grant t) #t)))
  (define grants
    (for/hash ([(id g) (in-hash (model-grants m))]
               #:unless (or (and (not (hash-ref with-tokens id #f)) (expired? (+ (mgrant-created g) token-less-grant-lifetime)))
                            (expired? (+ (mgrant-created g) grant-lifetime))))
      (values id g)))
  (define in-use (for/hash ([g (in-hash-values grants)]) (values (mgrant-client g) #t)))
  (define clients
    (for/hash ([(slot c) (in-hash (model-clients m))])
      (values slot (if (and (mclient-exists? c) (not (hash-ref in-use slot #f))
                            (expired? (+ (mclient-created c) registered-client-lifetime)))
                       (struct-copy mclient c [exists? #f])
                       c))))
  (define (alive? gid) (hash-has-key? grants gid))
  (struct-copy model m
               [codes (for/hash ([(id c) (in-hash codes)] #:when (alive? (mcode-grant c))) (values id c))]
               [tokens (for/hash ([(id t) (in-hash tokens)] #:when (alive? (mtoken-grant t))) (values id t))]
               [grants grants] [clients clients]))

;; Model -> Model
;; the periodic sweep that every authorize and token request starts with (`maybe-sweep!`)
(define (maybe-sweep m)
  (define last (model-last-sweep m))
  (if (or (not last) (>= (- (model-now m) last) sweep-interval))
      (sweep-model (struct-copy model m [last-sweep (model-now m)]))
      m))

;; Model Natural -> Model
;; the grant gone with its codes and tokens
(define (drop-grant m gid)
  (struct-copy model m
               [grants (hash-remove (model-grants m) gid)]
               [codes (for/hash ([(id c) (in-hash (model-codes m))] #:unless (= (mcode-grant c) gid)) (values id c))]
               [tokens (for/hash ([(id t) (in-hash (model-tokens m))] #:unless (= (mtoken-grant t) gid)) (values id t))]))

;; ---------------------------------------------------------------------------------------------
;; Steps

;; Model Command -> (values Model Symbol)
;; the model after the command and what the real server must answer: 'ok or 'no-client (connect),
;; 'ok or 'invalid-grant (exchange, refresh), 'principal or 'unauthorized (use), 'revoked or
;; 'not-found (revoke), 'done, or 'skip when the command has nothing to act on
(define (model-step m cmd)
  (match cmd
    [(? connect?) (step-connect m cmd)]
    [(? exchange?) (if (command-target m cmd) (step-exchange (maybe-sweep m) cmd) (values m 'skip))]
    [(? refresh?) (if (command-target m cmd) (step-refresh (maybe-sweep m) cmd) (values m 'skip))]
    [(? use?) (if (command-target m cmd) (step-use m cmd) (values m 'skip))]
    [(? revoke?) (if (command-target m cmd) (step-revoke m cmd) (values m 'skip))]
    [(bump s) (values (struct-copy model m [epochs (hash-update (model-epochs m) (modulo s 2) add1 0)]) 'done)]
    [(wait dt) (values (struct-copy model m [now (+ (model-now m) dt)]) 'done)]
    [(sweep) (values (sweep-model m) 'done)]
    [(register c) (values (put-client m (modulo c 2) #t) 'done)]
    [(flip c) (step-flip m (modulo c 2))]))

;; Model Natural Boolean -> Model
;; the client (re)registered now, keeping its right to refresh
(define (put-client m slot exists?)
  (define c (hash-ref (model-clients m) slot))
  (struct-copy model m [clients (hash-set (model-clients m) slot (mclient exists? (model-now m) (mclient-refresh? c)))]))

;; Model Natural -> (values Model Symbol)
(define (step-flip m slot)
  (define c (hash-ref (model-clients m) slot))
  (if (mclient-exists? c)
      (values (struct-copy model m [clients (hash-set (model-clients m) slot (struct-copy mclient c [refresh? (not (mclient-refresh? c))]))]) 'done)
      (values m 'skip)))

;; Model Connect -> (values Model Symbol)
(define (step-connect m0 cmd)
  (define m (maybe-sweep m0))
  (define slot (modulo (connect-client cmd) 2))
  (define subject (modulo (connect-subject cmd) 2))
  (define-values (requested kept) (connect-scopes cmd))
  (define now (model-now m))
  (define gid (model-next-id m))
  (define g (mgrant gid subject slot kept (hash-ref (model-epochs m) subject 0) now #f))
  (define code (mcode (add1 gid) gid (+ now code-ttl) #f))
  (if (mclient-exists? (hash-ref (model-clients m) slot))
      (values (struct-copy model m
                           [grants (hash-set (model-grants m) gid g)]
                           [all-grants (hash-set (model-all-grants m) gid g)]
                           [codes (hash-set (model-codes m) (add1 gid) code)]
                           [grant-pool (append (model-grant-pool m) (list gid))]
                           [code-pool (append (model-code-pool m) (list (add1 gid)))]
                           [next-id (+ gid 2)])
              'ok)
      (values m 'no-client)))

;; Model Grant Natural -> Integer
;; when a token minted now with the lifetime ends: never past the grant's own end
(define (token-expiry m g ttl) (min (+ (model-now m) ttl) (+ (mgrant-created g) grant-lifetime)))

;; Model ModelGrant Boolean -> (values Model Symbol)
;; the grant's first or next pair of tokens, minted now and the grant marked used
(define (issue m g refresh-token? #:retire [old #f])
  (define tid (model-next-id m))
  (define access-rec (mtoken tid (mgrant-id g) 'access (mgrant-scopes g) (token-expiry m g access-ttl) #f))
  (define refresh-rec (mtoken (add1 tid) (mgrant-id g) 'refresh (mgrant-scopes g) (token-expiry m g refresh-ttl) #f))
  (define tokens0 (if old (hash-set (model-tokens m) (mtoken-id old) (struct-copy mtoken old [retired? #t])) (model-tokens m)))
  (define tokens1 (hash-set tokens0 tid access-rec))
  (values (struct-copy model m
                       [tokens (if refresh-token? (hash-set tokens1 (add1 tid) refresh-rec) tokens1)]
                       [grants (hash-set (model-grants m) (mgrant-id g) (struct-copy mgrant g [last-used (model-now m)]))]
                       [access-pool (append (model-access-pool m) (list tid))]
                       [refresh-pool (if refresh-token? (append (model-refresh-pool m) (list (add1 tid))) (model-refresh-pool m))]
                       [next-id (+ tid 2)])
          'ok))

;; Model Exchange -> (values Model Symbol)
;; a code is spent on first use, success or not; used again it revokes its grant; a failed first use
;; deletes the grant too
(define (step-exchange m cmd)
  (define code (hash-ref (model-codes m) (command-target m cmd) #f))
  (define now (model-now m))
  (cond
    [(not code) (values m 'invalid-grant)]
    [(mcode-used-at code) (values (drop-grant m (mcode-grant code)) 'invalid-grant)]
    [(<= (mcode-expires code) now) (values m 'invalid-grant)]
    [else
     (define g (hash-ref (model-grants m) (mcode-grant code)))
     (define used (struct-copy model m [codes (hash-set (model-codes m) (mcode-id code) (struct-copy mcode code [used-at now]))]))
     (if (and (eq? (exchange-variant cmd) 'ok) (current? m g))
         (issue used g (mclient-refresh? (hash-ref (model-clients m) (mgrant-client g))))
         (values (drop-grant used (mgrant-id g)) 'invalid-grant))]))

;; Model Refresh -> (values Model Symbol)
;; a retired refresh token revokes the grant; a live one is rotated if everything still holds
(define (step-refresh m cmd)
  (define old (hash-ref (model-tokens m) (command-target m cmd) #f))
  (define now (model-now m))
  (cond
    [(not old) (values m 'invalid-grant)]
    [(mtoken-retired? old) (values (drop-grant m (mtoken-grant old)) 'invalid-grant)]
    [(<= (mtoken-expires old) now) (values m 'invalid-grant)]
    [else
     (define g (hash-ref (model-grants m) (mtoken-grant old)))
     (define c (hash-ref (model-clients m) (mgrant-client g)))
     (if (and (eq? (refresh-variant cmd) 'ok) (mclient-exists? c) (mclient-refresh? c)
              (< now (+ (mgrant-created g) grant-lifetime)) (current? m g))
         (issue m g #t #:retire old)
         (values m 'invalid-grant))]))

;; Model Use -> (values Model Symbol)
;; the resource server looks the access token up; a valid one touches its grant when it was last
;; touched over `touch-interval` ago
(define (step-use m cmd)
  (define t (hash-ref (model-tokens m) (command-target m cmd) #f))
  (define now (model-now m))
  (define g (and t (hash-ref (model-grants m) (mtoken-grant t) #f)))
  (cond
    [(not (and g (not (<= (mtoken-expires t) now)) (current? m g))) (values m 'unauthorized)]
    [else
     (define touched (if (or (not (mgrant-last-used g)) (> (- now (mgrant-last-used g)) touch-interval))
                         (struct-copy mgrant g [last-used now])
                         g))
     (values (struct-copy model m [grants (hash-set (model-grants m) (mgrant-id g) touched)]) 'principal)]))

;; Model Revoke -> (values Model Symbol)
(define (step-revoke m cmd)
  (define gid (command-target m cmd))
  (define g (hash-ref (model-grants m) gid #f))
  (if (and g (= (mgrant-subject g) (revoke-subject m cmd)))
      (values (drop-grant m gid) 'revoked)
      (values m 'not-found)))

(module+ test
  (require rackunit)
  (define (run m cmds) (for/fold ([m m]) ([c (in-list cmds)]) (let-values ([(m2 _) (model-step m c)]) m2)))
  (define (outcome m cmd) (let-values ([(m2 o) (model-step m cmd)]) o))
  (define m0 (initial-model 0))

  (test-case "a code works once, then its replay revokes the grant"
    (define m1 (run m0 (list (connect 0 0 2 0) (exchange 0 'ok))))
    (check-equal? (length (tokened-grants m1)) 1)
    (check-equal? (outcome m1 (exchange 0 'ok)) 'invalid-grant)
    (check-equal? (hash-count (model-grants (run m1 (list (exchange 0 'ok))))) 0))

  (test-case "a used code is kept a day, so replaying it still revokes"
    (define m1 (run m0 (list (connect 0 0 2 0) (exchange 0 'ok) (wait 3601) (sweep))))
    (check-equal? (hash-count (model-codes m1)) 1)
    (check-equal? (hash-count (model-codes (run m1 (list (wait 86400) (sweep))))) 0))

  (test-case "tokens never outlive their grant"
    (define m1 (run m0 (list (connect 0 0 2 0) (wait 59) (exchange 0 'ok) (wait (* 29 86400)) (refresh 0 'ok) (wait (* 29 86400)) (refresh 1 'ok) (wait (* 29 86400)) (refresh 2 'ok))))
    (check-equal? (mtoken-expires (hash-ref (model-tokens m1) (last (model-refresh-pool m1))))
                  (+ (mgrant-created (hash-ref (model-grants m1) 0)) (* 90 86400))))

  (test-case "pools are empty, commands skip"
    (check-equal? (outcome m0 (use 3)) 'skip)
    (check-equal? (outcome m0 (flip 5)) 'done)))
