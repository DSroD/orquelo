#lang racket/base
;; A generic OAuth 2.1 authorization server library (authorization code with PKCE, public
;; clients, client ID metadata documents and dynamic registration, opaque bearer tokens). It
;; knows nothing of the application embedding it: the app supplies an `oauth-app`, a store and
;; the consent UI. `server.rkt` documents the handlers and calls.
(require "server.rkt" "data.rkt" "store.rkt" "token-format.rkt" "metadata.rkt" "cimd.rkt" "uri.rkt" "ip.rkt")
(provide (all-from-out "server.rkt" "data.rkt" "store.rkt" "token-format.rkt" "metadata.rkt" "cimd.rkt" "uri.rkt" "ip.rkt"))
