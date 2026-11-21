#lang racket/base
;; The extension interface: an edition is the core server plus the pieces a product adds (migration
;; streams, CLI commands and, from `configure`, a plugin of limits, routes and optional admission).
(require racket/contract/base web-server/http db/base "config.rkt" "db/migrate.rkt" "domain.rkt" "http/deps.rkt")
(provide env/c routes/c audience-limit/c (struct-out limits) (struct-out migration-stream)
         (contract-out
          [struct plugin ([limits (-> connection? id/c limits?)]
                          [routes routes/c])]
          [struct (audience-plugin plugin) ([limits (-> connection? id/c limits?)]
                                           [routes routes/c]
                                           [limit audience-limit/c])]
          [struct (storage-plugin audience-plugin)
                   ([limits (-> connection? id/c limits?)] [routes routes/c] [limit audience-limit/c]
                    [disabled? (-> connection? id/c boolean?)]
                    [deck-removed! (-> connection? id/c void?)])]
          [struct route-kit ([deps deps?]
                             [signed-in (-> string? procedure? procedure?)]
                             [public (-> string? procedure? procedure?)]
                             [named (-> string? procedure? procedure?)]
                             [check-origin! (-> request? void?)])]
          [struct command ([name string?] [usage string?]
                           [run (-> (vectorof string?) env/c input-port? output-port? exact-integer?)])]
          [struct edition ([name string?] [streams (listof migration-stream?)] [commands (listof command?)]
                           [configure (-> env/c config? plugin?)])]))

;; Env is a (hash/c String String): the process environment
(define env/c (hash/c string? string?))

;; A Plugin is a (plugin LimitsOf Routes)
;; interp. what an edition adds to a running server: the limits of a user, and the routes tried before
;; the 404/static fallback. `routes` builds the dispatcher from the kit and fallback once at startup.
;; A RouteKit is a (route-kit Deps ...): the deps and the wrappers core uses for its own routes.
;; A Command is a (command String String Run): a CLI subcommand, its usage text and its runner.
;; An Edition is a (edition String [Listof MigrationStream] [Listof Command] (Env Config -> Plugin))
(struct plugin (limits routes))
;; An AudiencePlugin is an (audience-plugin LimitsOf Routes AudienceLimit).
;; interp. a plugin that also supplies the capacity of a presentation's sessions.
(struct audience-plugin plugin (limit))
;; A StoragePlugin adds a deck suspension check and a notification when its owner frees space.
(struct storage-plugin audience-plugin (disabled? deck-removed!))
(struct route-kit (deps signed-in public named check-origin!))
(struct command (name usage run))
(struct edition (name streams commands configure))

;; Routes is a (RouteKit Handler -> Handler): given the kit and the fallback, the dispatcher
(define routes/c (-> route-kit? (-> request? response?) (-> request? response?)))

;; AudienceLimit is (Connection PresentationId -> (or Natural #f)), where #f is unlimited.
(define audience-limit/c (-> connection? id/c (or/c natural-number/c #f)))
