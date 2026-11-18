#lang racket/base
;; Environment-driven configuration. (load-config env) takes a hash of string -> string.
;; A Config is the validated server configuration (see the field contracts below).
(require racket/contract/base racket/string racket/list racket/match "env.rkt" "db/migrate.rkt" "storage/config.rkt" "storage/store.rkt")
(provide (contract-out
          [struct config ([database-url string?] [public-base-url string?] [static-dir string?] [upload-dir string?]
                          [migrations (listof migration-source?)] [session-secret bytes?] [port (integer-in 1 65535)]
                          [metrics-port (or/c (integer-in 1 65535) #f)]
                          [pool-size exact-positive-integer?]
                          [storage storage-config?]
                          [max-upload-bytes (integer-in 1 104857600)]
                          [storage-quota (or/c natural-number/c #f)]
                          [trust-proxy boolean?])]
          [load-config (->* ((hash/c string? string?)) ((listof migration-stream?)) config?)]
          [core-stream migration-stream?]
          [core-streams (listof migration-stream?)]
          [stream-sources (-> (hash/c string? string?) (listof migration-stream?) (listof migration-source?))]
          [minimal-env (hash/c string? string?)]
          [config-secure? (-> config? boolean?)]
          [config->store (-> config? store?)]))

(struct config (database-url public-base-url static-dir upload-dir migrations
                session-secret port
                metrics-port pool-size storage max-upload-bytes storage-quota trust-proxy)
  #:transparent)

;; String -> Boolean
(define (https? url) (string-prefix? (string-downcase url) "https://"))

;; String String -> Natural
;; the TCP port in `s`, the value of the variable `name`
(define (parse-port name s)
  (define n (string->number s))
  (unless (and (exact-integer? n) (<= 1 n 65535)) (error 'config "invalid ~a ~a" name s))
  n)

;; String -> Natural
;; the database pool size in POOL_SIZE (1..500)
(define (parse-pool-size s)
  (define n (string->number s))
  (unless (and (exact-integer? n) (<= 1 n 500)) (error 'config "invalid POOL_SIZE ~a" s))
  n)

;; The migrations core ships; editions append their own streams
(define core-stream (migration-stream "core" "MIGRATIONS_DIR" "server/migrations"))
(define core-streams (list core-stream))

;; String String -> Natural
;; the non-negative integer in `s`, the value of the variable `name`
(define (parse-natural name s)
  (define n (string->number s))
  (unless (exact-nonnegative-integer? n) (error 'config "invalid ~a ~a" name s))
  n)

;; String -> Natural
;; the largest accepted upload in MAX_UPLOAD_BYTES (1 byte to 100 MiB)
(define (parse-max-upload s)
  (define n (parse-natural "MAX_UPLOAD_BYTES" s))
  (unless (<= 1 n 104857600) (error 'config "invalid MAX_UPLOAD_BYTES ~a (1 to 104857600)" s))
  n)

;; (or String #f) -> Boolean
;; TRUST_PROXY: unset or 0 (no), 1 (yes); anything else raises
(define (parse-trust-proxy s)
  (match s
    [(or #f "0") #f]
    ["1" #t]
    [_ (error 'config "invalid TRUST_PROXY ~a (0 or 1)" s)]))

;; Env [Listof MigrationStream] -> [Listof MigrationSource]
;; each stream resolved to its directory: the stream's environment variable, else its default
(define (stream-sources env streams)
  (for/list ([s streams])
    (migration-source (migration-stream-name s)
                      (env-ref env (migration-stream-env-var s) (migration-stream-default-dir s)))))

;; Env [Listof MigrationStream] -> Config
;; reads and validates the environment (a hash of String -> String); raises on anything missing or invalid
(define (load-config env [streams core-streams])
  (define base (string-trim (env-require env "PUBLIC_BASE_URL") "/" #:left? #f))
  (define secret (env-require env "SESSION_SECRET"))
  (when (< (bytes-length (string->bytes/utf-8 secret)) 32)
    (error 'config "SESSION_SECRET must be at least 32 bytes"))
  (config (env-require env "DATABASE_URL") base
          (env-require env "STATIC_DIR") (env-require env "UPLOAD_DIR")
          (stream-sources env streams)
          (string->bytes/utf-8 secret)
          (parse-port "PORT" (env-ref env "PORT" "8080"))
          (let ([p (env-ref env "METRICS_PORT")]) (and p (parse-port "METRICS_PORT" p)))
          (parse-pool-size (env-ref env "POOL_SIZE" "20"))
          (load-storage-config env)
          (parse-max-upload (env-ref env "MAX_UPLOAD_BYTES" "104857600"))
          (let ([q (env-ref env "STORAGE_QUOTA_BYTES")]) (and q (parse-natural "STORAGE_QUOTA_BYTES" q)))
          (parse-trust-proxy (env-ref env "TRUST_PROXY"))))

;; Env
;; the smallest environment that loads; tests extend it with `hash-set`
(define minimal-env
  (hash "DATABASE_URL" "postgresql://u:p@h:5432/d" "PUBLIC_BASE_URL" "http://localhost:8080"
        "STATIC_DIR" "/s" "UPLOAD_DIR" "/u" "SESSION_SECRET" (make-string 32 #\x)))

;; Config -> Store
;; the PDF store the configuration selects (STORAGE=local|s3)
(define (config->store cfg) (storage-config->store (config-storage cfg)))

;; Config -> Boolean
;; are cookies Secure (https base URL)?
(define (config-secure? cfg) (https? (config-public-base-url cfg)))

(module+ test
  (require rackunit racket/sequence)
  (define base minimal-env)
  (define (with h . kvs) (for/fold ([h h]) ([kv (in-slice 2 kvs)]) (hash-set h (car kv) (cadr kv))))
  (test-case "minimal config"
    (define c (load-config base))
    (check-equal? (config-port c) 8080)
    (check-equal? (config-public-base-url c) "http://localhost:8080")
    (check-false (config-secure? c)))
  (test-case "metrics port"
    (check-false (config-metrics-port (load-config base)))
    (check-equal? (config-metrics-port (load-config (with base "METRICS_PORT" "9091"))) 9091)
    (check-exn #rx"METRICS_PORT" (λ () (load-config (with base "METRICS_PORT" "nope")))))
  (test-case "pool size"
    (check-equal? (config-pool-size (load-config base)) 20)
    (check-equal? (config-pool-size (load-config (with base "POOL_SIZE" "50"))) 50)
    (check-exn #rx"POOL_SIZE" (λ () (load-config (with base "POOL_SIZE" "0")))))
  (test-case "storage defaults to local files in UPLOAD_DIR"
    (check-equal? (local-storage-dir (config-storage (load-config base))) "/u")
    (check-exn #rx"S3_ENDPOINT" (λ () (load-config (with base "STORAGE" "s3")))))
  (test-case "required vars"
    (for ([k '("DATABASE_URL" "PUBLIC_BASE_URL" "STATIC_DIR" "UPLOAD_DIR" "SESSION_SECRET")])
      (check-exn exn:fail? (λ () (load-config (hash-remove base k))))))
  (test-case "short secret"
    (check-exn #rx"32 bytes" (λ () (load-config (with base "SESSION_SECRET" "short")))))
  (test-case "upload and storage limits"
    (define c (load-config base))
    (check-equal? (config-max-upload-bytes c) 104857600)
    (check-false (config-storage-quota c))
    (check-equal? (config-max-upload-bytes (load-config (with base "MAX_UPLOAD_BYTES" "1000"))) 1000)
    (for ([bad '("0" "104857601" "x" "-1")])
      (check-exn #rx"MAX_UPLOAD_BYTES" (λ () (load-config (with base "MAX_UPLOAD_BYTES" bad)))))
    (check-equal? (config-storage-quota (load-config (with base "STORAGE_QUOTA_BYTES" "5000"))) 5000)
    (check-exn #rx"STORAGE_QUOTA_BYTES" (λ () (load-config (with base "STORAGE_QUOTA_BYTES" "-5")))))
  (test-case "TRUST_PROXY is 0 or 1"
    (check-false (config-trust-proxy (load-config base)))
    (check-false (config-trust-proxy (load-config (with base "TRUST_PROXY" "0"))))
    (check-true (config-trust-proxy (load-config (with base "TRUST_PROXY" "1"))))
    (check-exn #rx"TRUST_PROXY" (λ () (load-config (with base "TRUST_PROXY" "yes")))))
  (test-case "https base is secure"
    (check-true (config-secure? (load-config (with base "PUBLIC_BASE_URL" "https://x.cz"))))))
