#lang racket/base
;; Where the OAuth server keeps its state: an `oauth-store` is a struct of procedures, so a
;; database-backed store can be passed in. `make-memory-store` is the reference implementation;
;; `store-suite.rkt` is the contract every store must pass. A store has no clock: every operation
;; that cares about time is given `now`, in the same seconds as the app's clock.
(require racket/contract/base racket/list "data.rkt" "base64url.rkt")
(provide (contract-out
          [struct oauth-store
            ([client-ref (-> string? (or/c client? #f))]
             [client-put! (-> client? void?)]
             [pending-put! (-> pending? void?)]
             [pending-ref (-> bytes? exact-integer? (or/c pending? #f))]
             [pending-take! (-> bytes? exact-integer? (or/c pending? #f))]
             [grant-create! (-> any/c string? (listof string?) exact-nonnegative-integer? exact-integer? grant?)]
             [grant-ref (-> string? (or/c grant? #f))]
             [grants-of (-> any/c (listof grant?))]
             [grant-delete! (-> any/c string? boolean?)]
             [grant-touch! (-> string? exact-integer? void?)]
             [code-put! (-> code-record? void?)]
             [code-consume! (-> bytes? exact-integer? (or/c code-record? reused? #f))]
             [token-put! (-> token-record? boolean?)]
             [access-ref (-> bytes? exact-integer? (or/c (cons/c token-record? grant?) #f))]
             [refresh-ref (-> bytes? exact-integer? (or/c (cons/c token-record? grant?) reused? #f))]
             [refresh-rotate! (-> bytes? exact-integer? string? (listof token-record?)
                                  (or/c grant? reused? #f))]
             [sweep! (-> exact-integer? void?)]
             [atomically (-> (-> any) any)])]
          [make-memory-store (-> oauth-store?)])
         store-client-ref store-client-put! store-pending-put! store-pending-ref store-pending-take!
         store-grant-create! store-grant-ref store-grants-of store-grant-delete! store-grant-touch!
         store-code-put! store-code-consume! store-token-put! store-access-ref store-refresh-ref
         store-refresh-rotate! store-sweep! store-atomically)

;; An OAuthStore is an (oauth-store Procedure ...), one procedure per operation. A store is plain
;; persistence: its procedures never call back into the application (no hooks, no policy checks),
;; so a database-backed store can run each one in a short transaction.
;;   client-ref             id -> Client or #f (stale cached documents included; see `client-expires`)
;;   client-put!            insert or replace by id
;;   pending-put!           store a pending authorization request
;;   pending-ref            by id hash; #f once expired
;;   pending-take!          the pending request, removed (single use); #f when absent or expired
;;   grant-create!          subject, client id, scopes, epoch, now -> a new Grant with a fresh id. Every
;;                          approval is its own grant: nothing is shared with, or replaced by, others
;;   grant-ref              by id
;;   grants-of              all grants of a subject
;;   grant-delete!          subject, id -> was there such a grant of that subject; its tokens and codes go too
;;   grant-touch!           records `last-used`
;;   code-put!              store an authorization code (its grant must exist)
;;   code-consume!          atomically use a code once: the record; (reused grant-id) when it was used
;;                          before (even if it has expired since); #f when unknown or expired
;;   token-put!             store an access or refresh token; #f (and nothing stored) when its grant no
;;                          longer exists, e.g. revoked meanwhile
;;   access-ref             hash, now -> the live access token and its grant, or #f
;;   refresh-ref            hash, now -> the live, not yet retired refresh token and its grant; (reused
;;                          grant-id) for a retired one (even if expired since); #f when unknown or expired
;;   refresh-rotate!        hash, now, expected grant id, new tokens -> atomically retire a live refresh
;;                          token that belongs to that grant and store the new tokens; the touched Grant.
;;                          A retired token gives (reused grant-id); unknown, expired, another grant's or
;;                          with its grant gone gives #f and changes nothing
;;   sweep!                 drop expired pending requests, codes and tokens (a retired refresh token
;;                          goes when it expires), and clients that nothing refers to: cached ones past
;;                          their expiry, registered ones created over 30 days ago; and grants that
;;                          hold no token and were created over 15 minutes ago (an approval whose code
;;                          was never exchanged, or whose exchange failed)
;;   atomically             run a thunk so that its store operations happen together or not at all: when
;;                          the thunk raises (or escapes), everything it did is undone
(struct oauth-store (client-ref client-put! pending-put! pending-ref pending-take! grant-create!
                     grant-ref grants-of grant-delete! grant-touch! code-put! code-consume! token-put!
                     access-ref refresh-ref refresh-rotate! sweep! atomically))

;; the accessors applied, so callers write (store-code-consume! st hash now)
(define-syntax-rule (define-callers [caller accessor] ...)
  (begin (define (caller st . args) (apply (accessor st) args)) ...))
(define-callers
  [store-client-ref oauth-store-client-ref] [store-client-put! oauth-store-client-put!]
  [store-pending-put! oauth-store-pending-put!] [store-pending-ref oauth-store-pending-ref]
  [store-pending-take! oauth-store-pending-take!] [store-grant-create! oauth-store-grant-create!]
  [store-grant-ref oauth-store-grant-ref] [store-grants-of oauth-store-grants-of]
  [store-grant-delete! oauth-store-grant-delete!] [store-grant-touch! oauth-store-grant-touch!]
  [store-code-put! oauth-store-code-put!] [store-code-consume! oauth-store-code-consume!]
  [store-token-put! oauth-store-token-put!] [store-access-ref oauth-store-access-ref]
  [store-refresh-ref oauth-store-refresh-ref] [store-refresh-rotate! oauth-store-refresh-rotate!]
  [store-sweep! oauth-store-sweep!] [store-atomically oauth-store-atomically])

(define token-less-grant-lifetime (* 15 60))
(define registered-client-lifetime (* 30 24 60 60))

;; -> OAuthStore
;; a store in memory, safe for concurrent threads
(define (make-memory-store)
  (define clients (make-hash))   ; id -> Client
  (define pendings (make-hash))  ; id hash -> Pending
  (define grants (make-hash))    ; id -> Grant
  (define codes (make-hash))     ; hash -> (mcons CodeRecord used?)
  (define access (make-hash))    ; hash -> TokenRecord
  (define refresh (make-hash))   ; hash -> (mcons TokenRecord retired?)
  (define tables (list clients pendings grants codes access refresh))
  (define lock (make-semaphore 1))
  (define holder (make-thread-cell #f))

  ;; (listof (Hash Any Any)) -> (listof (Hash Any Any))
  ;; copies of the tables, with the mutable rows copied too
  (define (snapshot)
    (for/list ([t (in-list tables)])
      (define c (make-hash))
      (for ([(k v) (in-hash t)]) (hash-set! c k (if (mpair? v) (mcons (mcar v) (mcdr v)) v)))
      c))
  (define (restore! saved)
    (for ([t (in-list tables)] [c (in-list saved)])
      (hash-clear! t)
      (for ([(k v) (in-hash c)]) (hash-set! t k v))))

  ;; the lock is re-entrant per thread, so an operation may run inside `atomically`; only the
  ;; outermost call keeps a snapshot, to undo everything if the thunk does not return
  (define (atomically thunk)
    (cond [(thread-cell-ref holder) (thunk)]
          [else
           (semaphore-wait lock)
           (thread-cell-set! holder #t)
           (define saved (snapshot))
           (define done? #f)
           (dynamic-wind
            void
            (λ () (begin0 (thunk) (set! done? #t)))
            (λ ()
              (unless done? (restore! saved))
              (thread-cell-set! holder #f)
              (semaphore-post lock)))]))
  (define-syntax-rule (locked body ...) (atomically (λ () body ...)))

  (define (expired? expires now) (<= expires now))
  (define (live-grant id) (hash-ref grants id #f))

  (define (grant-create! subject client-id scopes epoch now)
    (locked
     (define g (grant (random-base64url 16) subject client-id scopes epoch now #f))
     (hash-set! grants (grant-id g) g)
     g))

  (define (drop-credentials! gid)
    (for ([table (list codes access refresh)])
      (for ([k (in-list (hash-keys table))])
        (define v (hash-ref table k))
        (define r (if (mpair? v) (mcar v) v))
        (when (equal? gid (if (code-record? r) (code-record-grant-id r) (token-record-grant-id r)))
          (hash-remove! table k)))))

  (define (grant-delete! subject id)
    (locked
     (define g (live-grant id))
     (and g (equal? (grant-subject g) subject)
          (begin (hash-remove! grants id) (drop-credentials! id) #t))))

  (define (code-consume! h now)
    (locked
     (define row (hash-ref codes h #f))
     (cond [(not row) #f]
           [(mcdr row) (reused (code-record-grant-id (mcar row)))]
           [(expired? (code-record-expires (mcar row)) now) #f]
           [else (set-mcdr! row #t) (mcar row)])))

  (define (token-put! t)
    (locked
     (and (live-grant (token-record-grant-id t))
          (begin
            (if (eq? (token-record-kind t) 'access)
                (hash-set! access (token-record-hash t) t)
                (hash-set! refresh (token-record-hash t) (mcons t #f)))
            #t))))

  (define (access-ref h now)
    (locked
     (define rec (hash-ref access h #f))
     (define g (and rec (not (expired? (token-record-expires rec) now)) (live-grant (token-record-grant-id rec))))
     (and g (cons rec g))))

  (define (refresh-ref h now)
    (locked
     (define row (hash-ref refresh h #f))
     (define g (and row (live-grant (token-record-grant-id (mcar row)))))
     (cond [(not g) #f]
           [(mcdr row) (reused (grant-id g))]
           [(expired? (token-record-expires (mcar row)) now) #f]
           [else (cons (mcar row) g)])))

  (define (refresh-rotate! h now expected-gid new-tokens)
    (locked
     (define found (refresh-ref h now))
     (cond [(reused? found) found]
           [(and found (equal? (grant-id (cdr found)) expected-gid))
            (define touched (struct-copy grant (cdr found) [last-used now]))
            (set-mcdr! (hash-ref refresh h) #t)
            (hash-set! grants (grant-id touched) touched)
            (for ([t (in-list new-tokens)]) (token-put! t))
            touched]
           [else #f])))

  (define (sweep! now)
    (locked
     (for ([(k v) (in-hash pendings)] #:when (expired? (pending-expires v) now)) (hash-remove! pendings k))
     (for ([(k v) (in-hash codes)] #:when (expired? (code-record-expires (mcar v)) now)) (hash-remove! codes k))
     (for ([(k v) (in-hash access)] #:when (expired? (token-record-expires v) now)) (hash-remove! access k))
     (for ([(k v) (in-hash refresh)] #:when (expired? (token-record-expires (mcar v)) now)) (hash-remove! refresh k))
     (define with-tokens
       (for/hash ([t (in-sequences (in-hash-values access) (map mcar (hash-values refresh)))])
         (values (token-record-grant-id t) #t)))
     (for ([(id g) (in-hash (hash-copy grants))]
           #:unless (hash-ref with-tokens id #f)
           #:when (<= (+ (grant-created g) token-less-grant-lifetime) now))
       (hash-remove! grants id)
       (drop-credentials! id))
     (define in-use
       (append (map grant-client-id (hash-values grants)) (map pending-client-id (hash-values pendings))))
     (for ([(k c) (in-hash clients)]
           #:unless (member k in-use)
           #:when (if (client-expires c)
                      (expired? (client-expires c) now)
                      (expired? (+ (client-created c) registered-client-lifetime) now)))
       (hash-remove! clients k))))

  (oauth-store
   (λ (id) (locked (hash-ref clients id #f)))
   (λ (c) (locked (hash-set! clients (client-id c) c)))
   (λ (p) (locked (hash-set! pendings (pending-id-hash p) p)))
   (λ (h now) (locked (let ([p (hash-ref pendings h #f)]) (and p (not (expired? (pending-expires p) now)) p))))
   (λ (h now) (locked (let ([p (hash-ref pendings h #f)])
                        (hash-remove! pendings h)
                        (and p (not (expired? (pending-expires p) now)) p))))
   grant-create!
   (λ (id) (locked (live-grant id)))
   (λ (subject) (locked (filter (λ (g) (equal? (grant-subject g) subject)) (hash-values grants))))
   grant-delete!
   (λ (id now) (locked (let ([g (live-grant id)]) (when g (hash-set! grants id (struct-copy grant g [last-used now]))))))
   (λ (c) (locked (hash-set! codes (code-record-hash c) (mcons c #f))))
   code-consume!
   token-put!
   access-ref
   refresh-ref
   refresh-rotate!
   sweep!
   atomically))
