#lang racket/base
;; The model-based lifecycle property: a random list of commands (connect, exchange, refresh, use,
;; revoke, bump, wait, sweep, ...) runs against the real server over a store and against the pure
;; model of lifecycle-model.rkt. After each command the outcome class must equal the model's and
;; the connected apps and stored grants must equal the model's. On top of that, invariants are
;; checked on the real outputs alone (test-only: never required from main.rkt):
;;   I1 token scopes are within the grant's, which are within the request's, within the app's
;;   I2 every token is bound to the app's resource (I7: and ends no later than its grant does)
;;   I3 a used code, or a refresh token that was rotated, never succeeds again
;;   I4 nothing authenticates once its grant is gone, its subject's epoch has moved or it has expired
;;   I5 a principal's fields equal the grant's
;;   I6 nothing raises and nothing answers with a 5xx
(require racket/contract/base racket/list racket/match racket/set racket/string rackcheck web-server/http
         "../data.rkt" "../store.rkt" "../server.rkt" "../token-format.rkt"
         "driver.rkt" "lifecycle-model.rkt" "prop.rkt")
(provide
 (contract-out
  [lifecycle-property (->* ((-> oauth-store?) exact-positive-integer?) (#:deadline-ms exact-positive-integer?) any)]
  [run-commands (-> (-> oauth-store?) list? void?)]
  [gen:command gen?]
  [scripts (listof (cons/c string? list?))]))

;; the real subjects (user ids, which the Postgres tests create) of subject slots 0 and 1
(define subjects '(7 8))
(define wrong-verifier (make-string 43 #\A))
(define wrong-redirect "https://app.example/elsewhere")

;; Natural -> Subject
(define (subject-of slot) (list-ref subjects slot))
;; Natural -> String
(define (client-of slot) (list-ref client-ids slot))

;; An Env is the driver's memory of what the real server issued, keyed by the model's ids:
;;   codes       code id -> the code
;;   tokens      token id -> the token
;;   token-info  token id -> (list grant-id expiry kind): the model grant it belongs to, when it ends
;;   real-gids   model grant id -> the store's grant id;  model-gids is the inverse
;;   requested   model grant id -> the scopes its request asked for
;;   code-grants code id -> model grant id
;;   spent       code or refresh token string -> #t once it can never work again
;;   dead        token ids already seen to be refused
(struct env (codes tokens token-info real-gids model-gids requested code-grants spent dead))
(define (make-env) (env (make-hash) (make-hash) (make-hash) (make-hash) (make-hash) (make-hash) (make-hash) (make-hash) (make-hash)))

;; String Any ... -> Nothing
(define (fail! fmt . args) (error 'lifecycle (apply format fmt args)))

;; String Any Any -> Void
(define (expect! what actual expected)
  (unless (equal? actual expected) (fail! "~a: expected ~s, got ~s" what expected actual)))

;; Response -> Symbol
;; 'ok or 'invalid-grant for a token response; anything else (a 5xx included) is a failure
(define (token-outcome r)
  (match (response-code r)
    [200 'ok]
    [400 (if (equal? (hash-ref (json-of r) 'error #f) "invalid_grant") 'invalid-grant (fail! "token error ~a" (body-of r)))]
    [code (fail! "unexpected status ~a" code)]))

;; Env Natural -> Void
;; the model grant's real counterpart, found as the subject's grant the env does not know yet
(define (learn-grant! st env mgid subject-slot)
  (define fresh (for/list ([g (in-list (store-grants-of (stage-store st) (subject-of subject-slot)))]
                           #:unless (hash-has-key? (env-model-gids env) (grant-id g)))
                  (grant-id g)))
  (unless (= (length fresh) 1) (fail! "expected exactly one new grant, found ~a" (length fresh)))
  (hash-set! (env-real-gids env) mgid (car fresh))
  (hash-set! (env-model-gids env) (car fresh) mgid))

;; Stage Env Model Model Connect -> Symbol
(define (perform-connect! st env m m2 cmd expected)
  (define-values (requested kept) (connect-scopes cmd))
  (define code (connect! st (client-of (modulo (connect-client cmd) 2)) (subject-of (modulo (connect-subject cmd) 2))
                         requested kept))
  (define actual (if code 'ok 'no-client))
  (expect! "connect" actual expected)
  (when code
    (define mgid (last (model-grant-pool m2)))
    (learn-grant! st env mgid (modulo (connect-subject cmd) 2))
    (hash-set! (env-requested env) mgid requested)
    (hash-set! (env-codes env) (last (model-code-pool m2)) code)
    (hash-set! (env-code-grants env) (last (model-code-pool m2)) mgid))
  actual)

;; Stage Env String Natural (or 'access 'refresh) (listof String) Natural -> Void
;; I1, I2 and the clamp of I7 for a token the server just issued, read back from the store
(define (check-issued! st env token kind mgid scopes expires-in)
  (define store (stage-store st))
  (define now (stage-now st))
  (define h (hash-token token))
  (define found (if (eq? kind 'access) (store-access-ref store h now) (store-refresh-ref store h now)))
  (unless (and (pair? found) (token-record? (car found))) (fail! "an issued ~a token is not in the store" kind))
  (define rec (car found))
  (define g (cdr found))
  (expect! "grant of the token" (grant-id g) (hash-ref (env-real-gids env) mgid))
  (expect! "I2 resource" (token-record-resource rec) app-resource)
  (expect! "token scopes" (token-record-scopes rec) scopes)
  (define requested (hash-ref (env-requested env) mgid))
;; kept next to the model comparisons above: it holds without trusting the model
  (unless (and (subset? (list->set (token-record-scopes rec)) (list->set (grant-scopes g)))
               (subset? (list->set (grant-scopes g)) (list->set requested))
               (subset? (list->set requested) (list->set app-scope-names)))
    (fail! "I1 scopes: token ~s grant ~s requested ~s" (token-record-scopes rec) (grant-scopes g) requested))
  (unless (<= (token-record-expires rec) (+ (grant-created g) (* 90 24 3600))) (fail! "I7 a token outlives its grant"))
  (expect! "expires_in" (- (token-record-expires rec) now) expires-in))

;; Stage Env Model Model Natural JSExpr -> Void
;; remembers the tokens of a successful response (new in the pools of m2) after checking them
(define (record-issue! st env m m2 mgid j)
  (define now (stage-now st))
  (define access-id (last (model-access-pool m2)))
  (define access (hash-ref (model-tokens m2) access-id))
  (define refresh? (> (length (model-refresh-pool m2)) (length (model-refresh-pool m))))
  (expect! "refresh token presence" (hash-has-key? j 'refresh_token) refresh?)
  (define scopes (mtoken-scopes access))
  (expect! "scope" (hash-ref j 'scope) (string-join scopes " "))
  (check-issued! st env (hash-ref j 'access_token) 'access mgid scopes (- (mtoken-expires access) now))
  (hash-set! (env-tokens env) access-id (hash-ref j 'access_token))
  (hash-set! (env-token-info env) access-id (list mgid (mtoken-expires access) 'access))
  (when refresh?
    (define refresh-id (last (model-refresh-pool m2)))
    (define refresh (hash-ref (model-tokens m2) refresh-id))
    (check-issued! st env (hash-ref j 'refresh_token) 'refresh mgid scopes (- (mtoken-expires refresh) now))
    (hash-set! (env-tokens env) refresh-id (hash-ref j 'refresh_token))
    (hash-set! (env-token-info env) refresh-id (list mgid (mtoken-expires refresh) 'refresh))))

;; Stage Env Model Model Exchange -> Symbol
(define (perform-exchange! st env m m2 cmd expected)
  (define cid (command-target m cmd))
  (define code (hash-ref (env-codes env) cid))
  (define mgid (hash-ref (env-code-grants env) cid))
  (define slot (mgrant-client (hash-ref (model-all-grants m) mgid)))
  (define own (client-of slot))
  (define r (match (exchange-variant cmd)
              ['ok (exchange-code st code #:client own)]
              ['bad-verifier (exchange-code st code #:client own #:verifier wrong-verifier)]
              ['bad-client (exchange-code st code #:client (client-of (- 1 slot)))]
              ['bad-redirect (exchange-code st code #:client own #:redirect wrong-redirect)]))
  (define actual (token-outcome r))
  (when (and (eq? actual 'ok) (hash-ref (env-spent env) code #f)) (fail! "I3 a used code worked again"))
  (hash-set! (env-spent env) code #t)
  (expect! "exchange" actual expected)
  (when (eq? actual 'ok) (record-issue! st env m m2 mgid (json-of r)))
  actual)

;; Stage Env Model Model Refresh -> Symbol
(define (perform-refresh! st env m m2 cmd expected)
  (define tid (command-target m cmd))
  (define token (hash-ref (env-tokens env) tid))
  (define mgid (car (hash-ref (env-token-info env) tid)))
  (define slot (mgrant-client (hash-ref (model-all-grants m) mgid)))
  (define r (refresh-with st token #:client (client-of (if (eq? (refresh-variant cmd) 'ok) slot (- 1 slot)))))
  (define actual (token-outcome r))
  (when (and (eq? actual 'ok) (hash-ref (env-spent env) token #f)) (fail! "I3 a used refresh token worked again"))
  (expect! "refresh" actual expected)
  (when (eq? actual 'ok)
    (hash-set! (env-spent env) token #t)
    (record-issue! st env m m2 mgid (json-of r)))
  actual)

;; Stage Env Model Use Symbol -> Symbol
(define (perform-use! st env m cmd expected)
  (define tid (command-target m cmd))
  (define result (authenticate-with st (hash-ref (env-tokens env) tid)))
  (define actual
    (cond [(principal? result) 'principal]
          [(= (response-code result) 401) 'unauthorized]
          [else (fail! "authenticate answered ~a" (response-code result))]))
  (expect! "use" actual expected)
  (when (principal? result)
    (define t (hash-ref (model-tokens m) tid))
    (define mg (hash-ref (model-grants m) (mtoken-grant t)))
    (expect! "principal subject" (principal-subject result) (subject-of (mgrant-subject mg)))
    (expect! "principal client" (principal-client-id result) (client-of (mgrant-client mg)))
    (expect! "principal scopes" (principal-scopes result) (mtoken-scopes t))
    (expect! "principal grant" (principal-grant-id result) (hash-ref (env-real-gids env) (mgrant-id mg)))
    (check-principal-matches-grant! st result))
  actual)

;; Stage Principal -> Void
;; I5: the principal speaks for what the stored grant says
(define (check-principal-matches-grant! st p)
  (define g (store-grant-ref (stage-store st) (principal-grant-id p)))
  (unless g (fail! "I5 the principal's grant is not stored"))
  (expect! "I5 subject" (principal-subject p) (grant-subject g))
  (expect! "I5 client" (principal-client-id p) (grant-client-id g))
;; kept: the model comparison in perform-use! does not read the stored grant's scopes
  (unless (subset? (list->set (principal-scopes p)) (list->set (grant-scopes g))) (fail! "I5 scopes beyond the grant's")))

;; Stage Env Model Model Command Symbol -> Symbol
;; runs the command against the real server and checks the outcome against `expected`
(define (perform! st env m m2 cmd expected)
  (define slots (model-clients m))
  (match cmd
    [(? connect?) (perform-connect! st env m m2 cmd expected)]
    [(? exchange?) (perform-exchange! st env m m2 cmd expected)]
    [(? refresh?) (perform-refresh! st env m m2 cmd expected)]
    [(? use?) (perform-use! st env m cmd expected)]
    [(? revoke?)
     (define ok? (revoke! (stage-server st) (subject-of (revoke-subject m cmd))
                          (hash-ref (env-real-gids env) (command-target m cmd))))
     (expect! "revoke" (if ok? 'revoked 'not-found) expected)
     expected]
    [(bump s) (stage-bump-epoch! st (subject-of (modulo s 2))) expected]
    [(wait dt) (stage-advance! st dt) expected]
    [(sweep) (sweep! (stage-server st)) expected]
    [(register c)
     (define c* (hash-ref slots (modulo c 2)))
     (stage-put-client! st (client-of (modulo c 2)) (mclient-refresh? c*) (stage-now st))
     expected]
    [(flip c)
     (define c* (hash-ref slots (modulo c 2)))
     (stage-put-client! st (client-of (modulo c 2)) (not (mclient-refresh? c*)) (mclient-created c*))
     expected]))

;; Stage Env Model -> Void
;; the connected apps and the stored grants of each subject are the model's; every access token
;; whose grant is gone, whose epoch moved or that expired is refused (I4, checked once per token)
(define (check-state! st env m)
  (define model-gids (env-model-gids env))
  (define (mgid-of real) (hash-ref model-gids real (λ () (fail! "the store holds a grant the model never made: ~a" real))))
  (define stored (make-hash))
  (for ([slot (in-range 2)])
    (define subject (subject-of slot))
    (define grants (store-grants-of (stage-store st) subject))
    (for ([g (in-list grants)]) (hash-set! stored (grant-id g) g))
    (expect! (format "stored grants of subject ~a" slot)
             (sort (map (λ (g) (mgid-of (grant-id g))) grants) <)
             (sort (for/list ([g (in-hash-values (model-grants m))] #:when (= (mgrant-subject g) slot)) (mgrant-id g)) <))
    (expect! (format "connected apps of subject ~a" slot)
             (sort (for/list ([i (in-list (subject-grants (stage-server st) subject))])
                     (list (mgid-of (grant-info-id i)) (grant-info-scopes i) (grant-info-created i)
                           (grant-info-last-used i) (grant-info-current? i)))
                   < #:key car)
             (sort (for/list ([g (in-list (tokened-grants m))] #:when (= (mgrant-subject g) slot))
                     (list (mgrant-id g) (mgrant-scopes g) (mgrant-created g) (mgrant-last-used g) (current? m g)))
                   < #:key car)))
  (for ([(tid info) (in-hash (env-token-info env))]
        #:when (eq? (caddr info) 'access)
        #:unless (hash-ref (env-dead env) tid #f))
    (define g (hash-ref stored (hash-ref (env-real-gids env) (car info)) #f))
    (when (or (<= (cadr info) (stage-now st)) (not g) (not (= (grant-epoch g) (stage-epoch st (grant-subject g)))))
      (hash-set! (env-dead env) tid #t)
      (when (principal? (authenticate-with st (hash-ref (env-tokens env) tid)))
        (fail! "I4 a token of a gone, outdated or expired grant authenticates")))))

;; (-> OAuthStore) (listof Command) -> Void
;; runs the commands on a fresh stage over a fresh store, failing at the first disagreement
(define (run-commands make-store cmds)
  (define st (make-stage (make-store)))
  (define env (make-env))
  (for/fold ([m (initial-model (stage-now st))]) ([cmd (in-list cmds)] [i (in-naturals)])
    (with-handlers ([exn:fail? (λ (e) (error 'lifecycle "command ~a ~s: ~a" i cmd (exn-message e)))])
      (define-values (m2 expected) (model-step m cmd))
      (cond [(eq? expected 'skip) m]
            [else (perform! st env m m2 cmd expected)
                  (check-state! st env m2)
                  m2])))
  (void))

;; ---------------------------------------------------------------------------------------------
;; Scripts

(define day 86400)

;; (listof (cons String (listof Command)))
;; fixed command lists for the edges the random lists rarely reach
(define scripts
  (list
   (cons "a replayed code revokes the grant, even a day after use"
         (list (connect 0 0 2 0) (exchange 0 'ok) (use 0) (wait day) (exchange 0 'ok) (use 0)
               (connect 1 0 2 0) (exchange 1 'ok) (wait (add1 day)) (exchange 1 'ok) (use 1)))
   (cons "a rotated refresh token revokes the grant when replayed"
         (list (connect 0 0 2 0) (exchange 0 'ok) (refresh 0 'ok) (refresh 0 'ok) (use 0) (use 1) (refresh 1 'ok)))
   (cons "the grant ends 90 days after approval, however often it is refreshed"
         (list (connect 0 0 2 0) (exchange 0 'ok)
               (wait (* 29 day)) (refresh 0 'ok) (wait (* 29 day)) (refresh 1 'ok) (wait (* 29 day)) (refresh 2 'ok)
               (use 3) (wait (* 3 day)) (use 3) (refresh 3 'ok) (sweep) (use 3)))
   (cons "refresh follows the client's right to refresh and the subject's epoch"
         (list (connect 0 0 2 0) (exchange 0 'ok) (flip 0) (refresh 0 'ok) (flip 0) (refresh 0 'ok)
               (bump 0) (refresh 1 'ok) (use 0) (use 1)))
   (cons "wrong details burn a code, and the other client may not refresh"
         (list (connect 0 0 2 0) (exchange 0 'bad-verifier) (exchange 0 'ok)
               (connect 0 0 1 0) (exchange 1 'ok) (refresh 0 'other-client) (refresh 0 'ok)))
   (cons "unused clients are swept after a day, used ones are not"
         (list (connect 0 0 2 0) (exchange 0 'ok) (wait (* 2 day)) (connect 0 1 1 0) (connect 0 0 1 0)
               (register 1) (connect 0 1 1 0) (exchange 1 'ok)))
   (cons "grants never exchanged go after fifteen minutes, with their codes"
         (list (connect 0 0 2 0) (wait 901) (connect 1 0 2 0) (exchange 0 'ok) (exchange 1 'ok) (use 0)))))

;; ---------------------------------------------------------------------------------------------
;; Generators

;; -> Gen
;; the generators below pick a slot (0 or 1), a position in a pool, and waits around the lifetimes
;; in the model (minutes, an hour, a day, 30 and 90 days)
(define gen:slot (gen:integer-in 0 1))
(define gen:index (gen:integer-in 0 7))
(define gen:small-wait (gen:one-of (list 1 5 30 59 60 61 120 299 300 301 599 600 601)))
(define gen:mid-wait (gen:one-of (list 899 900 901 3599 3600 3601 86399 86400 86401)))
(define gen:huge-wait (gen:one-of (list* (- (* 30 86400) 1) (* 30 86400) (add1 (* 30 86400))
                                         (- (* 90 86400) 1) (* 90 86400) (list (add1 (* 90 86400))))))

;; -> Gen
;; one command, favouring the ones that move credentials around
(define gen:command
  (gen:frequency
   (list (cons 7 (gen:let ([s gen:slot] [c gen:slot] [r (gen:integer-in 0 2)] [k (gen:integer-in 0 2)]) (connect s c r k)))
         (cons 7 (gen:let ([i gen:index] [v (gen:frequency (list (cons 8 (gen:one-of '(ok)))
                                                                (cons 3 (gen:one-of '(bad-verifier bad-client bad-redirect)))))])
                   (exchange i v)))
         (cons 8 (gen:let ([i gen:index] [v (gen:frequency (list (cons 8 (gen:one-of '(ok))) (cons 1 (gen:one-of '(other-client)))))])
                   (refresh i v)))
         (cons 8 (gen:let ([i gen:index]) (use i)))
         (cons 2 (gen:let ([i gen:index] [o (gen:frequency (list (cons 5 (gen:one-of '(#f))) (cons 1 (gen:one-of '(#t)))))]) (revoke i o)))
         (cons 1 (gen:let ([s gen:slot]) (bump s)))
         (cons 7 (gen:let ([dt gen:small-wait]) (wait dt)))
         (cons 3 (gen:let ([dt gen:mid-wait]) (wait dt)))
         (cons 1 (gen:let ([dt gen:huge-wait]) (wait dt)))
         (cons 1 (gen:const (sweep)))
         (cons 1 (gen:let ([c gen:slot]) (register c)))
         (cons 1 (gen:let ([c gen:slot]) (flip c))))))

;; (-> OAuthStore) Natural [#:deadline-ms Natural] -> Void
;; checks the lifecycle property over `tests` random command lists, each on a fresh store
(define (lifecycle-property make-store tests #:deadline-ms [deadline-ms 10000])
  (check-property
   (prop-config tests #:deadline-ms deadline-ms)
   (property ([cmds (gen:list gen:command #:max-length 40)])
     (run-commands make-store cmds)
     #t)))
