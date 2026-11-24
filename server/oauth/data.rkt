#lang racket/base
;; The data the OAuth server works with. A Subject is whatever the app calls a user (Orquelo: the
;; user id); the library only compares subjects with equal? and hands them back to the app.
;; Times are whole seconds (epoch seconds), as read from the app's clock.
(require racket/contract/base)
(provide (contract-out
          [struct client ([id string?] [kind (or/c 'metadata-document 'registered)] [name string?]
                          [uri (or/c string? #f)] [logo-uri (or/c string? #f)]
                          [redirect-uris (listof string?)] [refresh? boolean?]
                          [created exact-integer?] [expires (or/c exact-integer? #f)])]
          [struct pending ([id-hash bytes?] [client-id string?] [redirect-uri string?]
                           [explicit-redirect? boolean?]
                           [scopes (listof string?)] [state (or/c string? #f)] [challenge string?]
                           [resource string?] [expires exact-integer?])]
          [struct grant ([id string?] [subject any/c] [client-id string?] [scopes (listof string?)]
                         [epoch exact-nonnegative-integer?] [created exact-integer?]
                         [last-used (or/c exact-integer? #f)])]
          [struct code-record ([hash bytes?] [grant-id string?] [redirect-uri string?]
                               [explicit-redirect? boolean?] [challenge string?]
                               [resource string?] [scopes (listof string?)] [expires exact-integer?])]
          [struct token-record ([hash bytes?] [grant-id string?] [kind (or/c 'access 'refresh)]
                                [scopes (listof string?)] [resource string?] [expires exact-integer?])]
          [struct reused ([grant-id string?])]
          [struct principal ([subject any/c] [grant-id string?] [client-id string?] [scopes (listof string?)])]
          [struct pending-info ([id string?] [client-name string?] [client-host (or/c string? #f)]
                                [client-uri (or/c string? #f)] [verified? boolean?]
                                [redirect-host string?] [redirect-host-differs? boolean?]
                                [scopes (listof (cons/c string? boolean?))])]
          [struct grant-info ([id string?] [client-name string?] [client-host (or/c string? #f)]
                              [client-uri (or/c string? #f)] [verified? boolean?] [scopes (listof string?)]
                              [created exact-integer?] [last-used (or/c exact-integer? #f)] [current? boolean?])]
          [struct fetched ([status exact-integer?] [content-type (or/c string? #f)]
                           [cache-control (or/c string? #f)] [body bytes?])]
          [struct oauth-error ([code string?] [description string?] [status (integer-in 400 599)])]
          [struct oauth-app ([issuer string?] [resource string?] [scopes (listof (cons/c string? string?))]
                             [consent-path (-> string? string?)]
                             [subject-current? (-> any/c exact-nonnegative-integer? boolean?)]
                             [fetch-document (-> string? fetched?)] [clock (-> exact-integer?)])]))

;; A Client is a (client String (or 'metadata-document 'registered) String (or String #f)
;;                       (or String #f) (listof String) Boolean Integer (or Integer #f))
;; id (the CIMD URL, or a generated id for a registered client), kind, the name the client gave
;; itself (NOT verified), client URI and logo URI (kept only when on the client_id's own host),
;; redirect URIs, whether it may hold refresh tokens, when we learned of it, and when a cached
;; metadata document goes stale (#f for a registered client, which never does)
(struct client (id kind name uri logo-uri redirect-uris refresh? created expires) #:transparent)

;; A Pending is a (pending Bytes String String Boolean (listof String) (or String #f) String String Integer)
;; an authorization request awaiting the user's decision: SHA-256 of its public id, client id,
;; redirect URI, whether the request named it (else it was the client's only registered one),
;; requested scopes, the client's state, the S256 challenge, the resource and expiry
(struct pending (id-hash client-id redirect-uri explicit-redirect? scopes state challenge resource expires)
  #:transparent)

;; A Grant is a (grant String Subject String (listof String) Natural Integer (or Integer #f))
;; one approval: id, subject, client id, scopes the user allowed, the subject's epoch when it was
;; given, when it was created and when it was last used
(struct grant (id subject client-id scopes epoch created last-used) #:transparent)

;; A CodeRecord is a (code-record Bytes String String Boolean String String (listof String) Integer)
;; SHA-256 of the authorization code, grant id, redirect URI, whether the authorization request
;; named it, S256 challenge, resource, scopes, expiry
(struct code-record (hash grant-id redirect-uri explicit-redirect? challenge resource scopes expires)
  #:transparent)

;; A TokenRecord is a (token-record Bytes String (or 'access 'refresh) (listof String) String Integer)
;; SHA-256 of the token's lookup key, grant id, kind, scopes, the resource (audience) it is bound to, expiry
(struct token-record (hash grant-id kind scopes resource expires) #:transparent)

;; A Reused is a (reused String)
;; what a store answers when a single-use credential is presented twice: the grant it belonged to
(struct reused (grant-id) #:transparent)

;; A Principal is a (principal Subject String String (listof String))
;; who a valid access token speaks for: subject, grant id, client id, scopes
(struct principal (subject grant-id client-id scopes) #:transparent)

;; A PendingInfo is a (pending-info String String (or String #f) (or String #f) Boolean String Boolean
;;                                  (listof (cons String Boolean)))
;; what the consent page shows: request id, the client's self-chosen name (display only), the
;; client's host (the only verified fact: the host its metadata document was fetched from; #f for
;; a registered client), its client URI, verified? (is `client-host` set), the host the user will
;; be sent back to, whether that differs from the client's host, and each scope of the app with
;; whether the client asked for it
(struct pending-info (id client-name client-host client-uri verified? redirect-host redirect-host-differs? scopes)
  #:transparent)

;; A GrantInfo is a (grant-info String String (or String #f) (or String #f) Boolean (listof String)
;;                              Integer (or Integer #f) Boolean)
;; one connected app: grant id, client name (self-chosen), client host (as above), client URI,
;; verified?, scopes, created, last used, and whether it still works (#f once the subject's
;; epoch moved on)
(struct grant-info (id client-name client-host client-uri verified? scopes created last-used current?)
  #:transparent)

;; A Fetched is a (fetched Natural (or String #f) (or String #f) Bytes)
;; an HTTP reply to a metadata fetch: status, Content-Type, Cache-Control and a body of at most 5 KiB
(struct fetched (status content-type cache-control body) #:transparent)

;; An OAuthError is an (oauth-error String String Natural)
;; an RFC 6749 / 7591 error: code, human description, HTTP status
(struct oauth-error (code description status) #:transparent)

;; An OAuthApp is an (oauth-app String String (listof (cons String String)) (String -> String)
;;                              (Subject Natural -> Boolean) (String -> Fetched) (-> Integer))
;; what the application supplies: the issuer URL (an origin, no path), the one protected resource
;; (its identifier and token audience), scopes with descriptions, the consent page path for a
;; pending id, whether a subject still has this epoch, the metadata fetch, and the clock in
;; whole seconds
(struct oauth-app (issuer resource scopes consent-path subject-current? fetch-document clock) #:transparent)
