#lang racket/base
;; The open-source edition: local accounts with password login, limits from the environment and the
;; `user` and `db` commands.
(require racket/contract/base "../edition.rkt" "../config.rkt" "../db-cli.rkt" "../user-cli.rkt"
         "../auth/throttle.rkt" "../http/password-routes.rkt" "../domain.rkt" "../db/repo.rkt")
(provide (contract-out
          [env-limits (-> config? limits-of/c)]
          [core-edition edition?]))

;; Config -> LimitsOf
;; every user gets the same limits: MAX_UPLOAD_BYTES per PDF, STORAGE_QUOTA_BYTES in total (unset: unlimited)
;; and no plan
(define (env-limits cfg)
  (define l (limits (config-max-upload-bytes cfg) (config-storage-quota cfg) #f))
  (λ (c id) l))

;; Edition
(define core-edition
  (edition "core" core-streams
           (list (make-user-command core-streams #t) (make-db-command core-streams))
           (λ (env cfg)
             (plugin (env-limits cfg) (make-password-routes (make-throttle) (config-trust-proxy cfg))))))
