#lang racket/base
;; The OAuth store (oauth/store.rkt) on Postgres. Times are epoch seconds in bigint columns; a
;; subject is a user id. Single-use credentials are spent by a conditional UPDATE, and a rotation
;; locks the grant row first (the order a grant delete takes it in), so racing callers cannot both win.
(require racket/contract/base racket/match racket/vector db db/util/postgresql "query.rkt"
         "../oauth/data.rkt" "../oauth/store.rkt" "../oauth/base64url.rkt")
(provide (contract-out [make-pg-oauth-store (-> connection? oauth-store?)]))

;; PgArray -> (listof String)
(define (strings a) (pg-array->list a))

;; --- clients

(define client-cols "client_id, kind, name, client_uri, logo_uri, redirect_uris, refresh, created_at, expires_at")

;; Vector -> Client
;; the client of a row of `client-cols`
(define (row->client r)
  (match-define (vector id kind name uri logo uris refresh? created expires) r)
  (client id (string->symbol kind) name (sql-null->false uri) (sql-null->false logo) (strings uris)
          refresh? created (sql-null->false expires)))

;; Connection String -> (or Client #f)
;; the client with this id
(define-query (select-client c id) #:maybe-row row->client
  "SELECT " client-cols " FROM oauth_clients WHERE client_id=$1")

;; Connection String String String (or String #f) (or String #f) PgArray Boolean Integer (or Integer #f) -> Void
;; inserts the client or replaces the one with its id
(define-query (upsert-client! c id kind name [uri #:nullable] [logo #:nullable] uris refresh? created
                              [expires #:nullable])
  #:exec
  "INSERT INTO oauth_clients (" client-cols ") VALUES ($1, $2, $3, $4, $5, $6::text[], $7, $8, $9)
   ON CONFLICT (client_id) DO UPDATE SET kind=EXCLUDED.kind, name=EXCLUDED.name,
     client_uri=EXCLUDED.client_uri, logo_uri=EXCLUDED.logo_uri, redirect_uris=EXCLUDED.redirect_uris,
     refresh=EXCLUDED.refresh, created_at=EXCLUDED.created_at, expires_at=EXCLUDED.expires_at")

;; Connection Client -> Void
;; stores the client, replacing any with its id
(define (put-client! c cl)
  (match-define (client id kind name uri logo uris refresh? created expires) cl)
  (upsert-client! c id (symbol->string kind) name uri logo (list->pg-array uris) refresh? created expires))

;; Connection -> Natural
;; how many registered clients no grant refers to
(define-query (count-unused-registered c) #:value
  "SELECT count(*) FROM oauth_clients k WHERE k.kind='registered'
     AND NOT EXISTS (SELECT 1 FROM oauth_grants g WHERE g.client_id=k.client_id)")

;; --- pending requests

(define pending-cols "id_hash, client_id, redirect_uri, explicit_redirect, scopes, state, challenge, resource, expires_at")

;; Vector -> Pending
;; the pending request of a row of `pending-cols`
(define (row->pending r)
  (match-define (vector h cid redirect explicit? scopes state challenge resource expires) r)
  (pending h cid redirect explicit? (strings scopes) (sql-null->false state) challenge resource expires))

;; Connection Bytes String String Boolean PgArray (or String #f) String String Integer -> Void
;; inserts the pending request or replaces the one with its id hash
(define-query (upsert-pending! c h cid redirect explicit? scopes [state #:nullable] challenge resource expires)
  #:exec
  "INSERT INTO oauth_pending (" pending-cols ") VALUES ($1, $2, $3, $4, $5::text[], $6, $7, $8, $9)
   ON CONFLICT (id_hash) DO UPDATE SET client_id=EXCLUDED.client_id, redirect_uri=EXCLUDED.redirect_uri,
     explicit_redirect=EXCLUDED.explicit_redirect, scopes=EXCLUDED.scopes, state=EXCLUDED.state,
     challenge=EXCLUDED.challenge, resource=EXCLUDED.resource, expires_at=EXCLUDED.expires_at")

;; Connection Bytes Integer -> (or Pending #f)
;; the pending request unless it has expired
(define-query (select-pending c h now) #:maybe-row row->pending
  "SELECT " pending-cols " FROM oauth_pending WHERE id_hash=$1 AND expires_at > $2")

;; Connection Bytes -> (or Pending #f)
;; removes the pending request and returns it, expired or not
(define-query (delete-pending! c h) #:maybe-row row->pending
  "DELETE FROM oauth_pending WHERE id_hash=$1 RETURNING " pending-cols)

;; Connection Pending -> Void
;; stores the pending request, replacing any with its id hash
(define (put-pending! c p)
  (match-define (pending h cid redirect explicit? scopes state challenge resource expires) p)
  (upsert-pending! c h cid redirect explicit? (list->pg-array scopes) state challenge resource expires))

;; Connection Bytes Integer -> (or Pending #f)
;; the pending request, removed even when it has expired
(define (take-pending! c h now)
  (define p (delete-pending! c h))
  (and p (> (pending-expires p) now) p))

;; --- grants

(define grant-cols "id, user_id, client_id, scopes, session_epoch, created_at, last_used_at")
(define g-grant-cols "g.id, g.user_id, g.client_id, g.scopes, g.session_epoch, g.created_at, g.last_used_at")

;; Vector -> Grant
;; the grant of a row of `grant-cols`
(define (row->grant r)
  (match-define (vector id user cid scopes epoch created last-used) r)
  (grant id user cid (strings scopes) epoch created (sql-null->false last-used)))

;; Connection String Integer String PgArray Natural Integer -> Natural
;; inserts a grant (its user must exist) and says how many rows went in: 0 when the client is gone.
;; The key share lock keeps a concurrent sweep from deleting the client in between
(define-query (insert-grant! c id user cid scopes epoch created) #:count
  "INSERT INTO oauth_grants (id, user_id, client_id, scopes, session_epoch, created_at)
   SELECT $1::text, $2::bigint, client_id, $4::text[], $5::bigint, $6::bigint
   FROM oauth_clients WHERE client_id=$3::text FOR KEY SHARE")

;; Connection String -> (or Grant #f)
;; the grant with this id
(define-query (select-grant c id) #:maybe-row row->grant
  "SELECT " grant-cols " FROM oauth_grants WHERE id=$1")

;; Connection Integer -> (listof Grant)
;; the grants of a user, oldest first
(define-query (select-grants-of c user) #:rows row->grant
  "SELECT " grant-cols " FROM oauth_grants WHERE user_id=$1 ORDER BY created_at, id")

;; Connection String Integer -> Natural
;; deletes the grant if it is the user's (its credentials go with it); how many rows went
(define-query (delete-grant! c id user) #:count
  "DELETE FROM oauth_grants WHERE id=$1 AND user_id=$2")

;; Connection String Integer -> (or Grant #f)
;; records the time the grant was last used; the grant, or #f when there is none
(define-query (touch-grant! c id now) #:maybe-row row->grant
  "UPDATE oauth_grants SET last_used_at=$2 WHERE id=$1 RETURNING " grant-cols)

;; Connection Subject String (listof String) Natural Integer -> (or Grant #f)
;; a new grant under a random id; #f when the client is gone
(define (create-grant! c user cid scopes epoch now)
  (define id (random-base64url 16))
  (and (= (insert-grant! c id user cid (list->pg-array scopes) epoch now) 1)
       (grant id user cid scopes epoch now #f)))

;; --- codes

;; Connection Bytes String String Boolean String String PgArray Integer -> Void
;; inserts the code (unused) or replaces the one with its hash
(define-query (upsert-code! c h gid redirect explicit? challenge resource scopes expires) #:exec
  "INSERT INTO oauth_codes (code_hash, grant_id, redirect_uri, explicit_redirect, challenge, resource, scopes, expires_at)
   VALUES ($1, $2, $3, $4, $5, $6, $7::text[], $8)
   ON CONFLICT (code_hash) DO UPDATE SET grant_id=EXCLUDED.grant_id, redirect_uri=EXCLUDED.redirect_uri,
     explicit_redirect=EXCLUDED.explicit_redirect, challenge=EXCLUDED.challenge, resource=EXCLUDED.resource,
     scopes=EXCLUDED.scopes, expires_at=EXCLUDED.expires_at, used_at=NULL")

;; Vector -> CodeRecord
;; the code of a row of its columns
(define (row->code r)
  (match-define (vector h gid redirect explicit? challenge resource scopes expires) r)
  (code-record h gid redirect explicit? challenge resource (strings scopes) expires))

;; Vector -> (or CodeRecord Reused #f)
;; the answer to a consume from a row of the code's columns, whether it was used and whether it is live
(define (row->consumed r)
  (match-define (vector h gid _ _ _ _ _ _ used? live?) r)
  (cond [used? (reused gid)]
        [live? (row->code (vector-take r 8))]
        [else #f]))

;; Connection Bytes Integer -> (or CodeRecord Reused #f)
;; uses the code once, in one statement: it locks the row, so each racing caller reads it after the
;; previous one is done, and exactly one finds it unused
(define-query (consume-code! c h now) #:maybe-row row->consumed
  "WITH locked AS (
     SELECT code_hash, grant_id, redirect_uri, explicit_redirect, challenge, resource, scopes, expires_at,
            used_at IS NOT NULL AS used, expires_at > $2 AS live
       FROM oauth_codes WHERE code_hash=$1 FOR UPDATE),
   spent AS (
     UPDATE oauth_codes SET used_at=$2 FROM locked
      WHERE oauth_codes.code_hash=locked.code_hash AND NOT locked.used AND locked.live
      RETURNING oauth_codes.code_hash)
   SELECT code_hash, grant_id, redirect_uri, explicit_redirect, challenge, resource, scopes, expires_at, used, live
     FROM locked")

;; Connection CodeRecord -> Void
;; stores the code, unused, replacing any with its hash
(define (put-code! c r)
  (match-define (code-record h gid redirect explicit? challenge resource scopes expires) r)
  (upsert-code! c h gid redirect explicit? challenge resource (list->pg-array scopes) expires))

;; --- tokens

;; insert only while the grant exists; the key share lock keeps a concurrent delete from slipping between
;; Connection Bytes String PgArray String Integer -> Natural
;; stores the access token and says how many rows went in: 0 when the grant is gone
(define-query (insert-access! c h gid scopes resource expires) #:count
  "INSERT INTO oauth_access_tokens (token_hash, grant_id, scopes, resource, expires_at)
   SELECT $1::bytea, id, $3::text[], $4::text, $5::bigint FROM oauth_grants WHERE id=$2::text FOR KEY SHARE
   ON CONFLICT (token_hash) DO UPDATE SET grant_id=EXCLUDED.grant_id, scopes=EXCLUDED.scopes,
     resource=EXCLUDED.resource, expires_at=EXCLUDED.expires_at")

;; Connection Bytes String PgArray String Integer -> Natural
;; stores the refresh token, not retired, and says how many rows went in: 0 when the grant is gone
(define-query (insert-refresh! c h gid scopes resource expires) #:count
  "INSERT INTO oauth_refresh_tokens (token_hash, grant_id, scopes, resource, expires_at)
   SELECT $1::bytea, id, $3::text[], $4::text, $5::bigint FROM oauth_grants WHERE id=$2::text FOR KEY SHARE
   ON CONFLICT (token_hash) DO UPDATE SET grant_id=EXCLUDED.grant_id, scopes=EXCLUDED.scopes,
     resource=EXCLUDED.resource, expires_at=EXCLUDED.expires_at, retired_at=NULL")

;; (or 'access 'refresh) -> (Vector -> TokenRecord)
;; reads token_hash, grant_id, scopes, resource, expires_at
(define ((row->token kind) r)
  (match-define (vector h gid scopes resource expires) r)
  (token-record h gid kind (strings scopes) resource expires))

(define token-cols "t.token_hash, t.grant_id, t.scopes, t.resource, t.expires_at")

;; Vector -> (Pairof TokenRecord Grant)
(define (row->access+grant r)
  (cons ((row->token 'access) (vector-take r 5)) (row->grant (vector-drop r 5))))

;; Connection Bytes Integer -> (or (Pairof TokenRecord Grant) #f)
;; the access token unless it has expired, with its grant
(define-query (select-access c h now) #:maybe-row row->access+grant
  "SELECT " token-cols ", " g-grant-cols " FROM oauth_access_tokens t JOIN oauth_grants g ON g.id=t.grant_id
   WHERE t.token_hash=$1 AND t.expires_at > $2")

;; A RefreshRow is a (list TokenRecord Boolean Grant): the token, whether it is retired, its grant

;; Vector -> RefreshRow
;; the refresh token, whether it is retired and its grant, from a row
(define (row->refresh+grant r)
  (list ((row->token 'refresh) (vector-take r 5)) (not (sql-null? (vector-ref r 5))) (row->grant (vector-drop r 6))))

;; Connection Bytes -> (or RefreshRow #f)
;; the refresh token, retired or expired or not, with its grant
(define-query (select-refresh c h) #:maybe-row row->refresh+grant
  "SELECT " token-cols ", t.retired_at, " g-grant-cols " FROM oauth_refresh_tokens t
   JOIN oauth_grants g ON g.id=t.grant_id WHERE t.token_hash=$1")

;; Connection Bytes Integer -> Void
;; marks the refresh token retired
(define-query (retire-refresh! c h now) #:exec
  "UPDATE oauth_refresh_tokens SET retired_at=$2 WHERE token_hash=$1")

;; Connection Bytes -> (or String #f)
;; locks the grant of a refresh token (the lock a grant delete takes first, so a rotation and a
;; revocation cannot deadlock) and returns its id
(define-query (lock-grant-of-refresh! c h) #:maybe-value
  "SELECT id FROM oauth_grants WHERE id=(SELECT grant_id FROM oauth_refresh_tokens WHERE token_hash=$1) FOR UPDATE")

;; Connection TokenRecord -> Boolean
;; stored? (#f when its grant is gone)
(define (put-token! c t)
  (match-define (token-record h gid kind scopes resource expires) t)
  (define put! (if (eq? kind 'access) insert-access! insert-refresh!))
  (> (put! c h gid (list->pg-array scopes) resource expires) 0))

;; Connection Bytes Integer -> (or (Pairof TokenRecord Grant) Reused #f)
(define (refresh-ref c h now)
  (match (select-refresh c h)
    [#f #f]
    [(list _ #t g) (reused (grant-id g))]
    [(list t #f g) (and (> (token-record-expires t) now) (cons t g))]))

;; Connection Bytes Integer String (listof TokenRecord) -> (or Grant Reused #f)
;; the grant lock makes racing rotations of one token take turns, and the token is read again under it
(define (rotate-refresh! c h now expected-gid new-tokens)
  (call-with-transaction c
    (λ ()
      (and (lock-grant-of-refresh! c h)
           (match (refresh-ref c h now)
             [(? reused? r) r]
             [(cons _ g)
              #:when (equal? (grant-id g) expected-gid)
              (retire-refresh! c h now)
              (for ([t (in-list new-tokens)]) (put-token! c t))
              (touch-grant! c (grant-id g) now)]
             [_ #f])))))

;; --- sweep

;; Connection Integer -> Void
;; see `sweep!` in oauth/store.rkt. Not a transaction: every step only removes what is already
;; garbage, and one would take token locks before grant locks, the reverse of a grant delete
(define (sweep! c now)
    (query-exec c "DELETE FROM oauth_pending WHERE expires_at <= $1" now)
    (query-exec c "DELETE FROM oauth_codes WHERE expires_at <= $1 AND (used_at IS NULL OR used_at + $2::bigint <= $1)"
                now used-code-retention)
    (query-exec c "DELETE FROM oauth_access_tokens WHERE expires_at <= $1" now)
    (query-exec c "DELETE FROM oauth_refresh_tokens WHERE expires_at <= $1" now)
    (query-exec c "DELETE FROM oauth_grants g
                    WHERE g.created_at + $3::bigint <= $1::bigint
                       OR (g.created_at + $2::bigint <= $1::bigint
                           AND NOT EXISTS (SELECT 1 FROM oauth_access_tokens t WHERE t.grant_id=g.id)
                           AND NOT EXISTS (SELECT 1 FROM oauth_refresh_tokens t WHERE t.grant_id=g.id))"
                now token-less-grant-lifetime grant-lifetime)
    (query-exec c "DELETE FROM oauth_clients k
                    WHERE NOT EXISTS (SELECT 1 FROM oauth_grants g WHERE g.client_id=k.client_id)
                      AND NOT EXISTS (SELECT 1 FROM oauth_pending p WHERE p.client_id=k.client_id)
                      AND COALESCE(k.expires_at, k.created_at + $2::bigint) <= $1::bigint"
                now registered-client-lifetime))

;; Connection (-> A) -> A
;; runs the thunk in a transaction, or a savepoint inside one, and undoes it unless the thunk
;; returns: whatever it raises (`call-with-transaction` rolls back only for exn) or however it escapes
(define (atomically c thunk)
  (define done? #f)
  (start-transaction c)
  (dynamic-wind
   void
   (λ () (begin0 (thunk) (set! done? #t) (commit-transaction c)))
   (λ () (unless done? (rollback-transaction c)))))

;; Connection -> OAuthStore
;; a store in Postgres; each operation is one statement or a short transaction, and `atomically`
;; wraps its thunk in a transaction (nested ones become savepoints)
(define (make-pg-oauth-store c)
  (oauth-store
   (λ (id) (select-client c id))
   (λ (cl) (put-client! c cl))
   (λ () (count-unused-registered c))
   (λ (p) (put-pending! c p))
   (λ (h now) (select-pending c h now))
   (λ (h now) (take-pending! c h now))
   (λ (user cid scopes epoch now) (create-grant! c user cid scopes epoch now))
   (λ (id) (select-grant c id))
   (λ (user) (select-grants-of c user))
   (λ (user id) (> (delete-grant! c id user) 0))
   (λ (id now) (void (touch-grant! c id now)))
   (λ (r) (put-code! c r))
   (λ (h now) (consume-code! c h now))
   (λ (t) (put-token! c t))
   (λ (h now) (select-access c h now))
   (λ (h now) (refresh-ref c h now))
   (λ (h now gid new) (rotate-refresh! c h now gid new))
   (λ (now) (sweep! c now))
   (λ (thunk) (atomically c thunk))))
