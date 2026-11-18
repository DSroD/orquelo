#lang racket/base
;; Storage configuration from the environment, and the Store it describes.
;;   STORAGE=local (default)  files in UPLOAD_DIR
;;   STORAGE=s3               objects in S3_BUCKET at S3_ENDPOINT, signed for S3_REGION
;;                            with S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY; S3_PATH_STYLE=1 for
;;                            path-style addressing (MinIO, Ceph, Contabo). UPLOAD_DIR stages uploads.
;; S3_ENDPOINT is exactly http(s)://host[:port], with at most one trailing "/": no user info,
;; path, query or fragment, and the host is a name or an IPv4 address (IPv6 literals are rejected,
;; so the Host header never needs brackets). http is accepted for local development servers.
(require racket/contract/base racket/string "../env.rkt" "../s3/main.rkt" "local.rkt" "s3.rkt" "store.rkt")
(provide (contract-out
          [struct local-storage ([dir path-string?])]
          [struct s3-storage ([bucket s3-bucket?])]
          [storage-config? (-> any/c boolean?)]
          [load-storage-config (-> (hash/c string? string?) storage-config?)]
          [storage-config->store (-> storage-config? store?)]))

;; A StorageConfig is one of
;;   (local-storage PathString)   the directory holding the files
;;   (s3-storage S3Bucket)        the bucket holding the objects
(struct local-storage (dir))
(struct s3-storage (bucket))

;; Any -> Boolean
(define (storage-config? v) (or (local-storage? v) (s3-storage? v)))

;; Env -> StorageConfig
;; reads and validates the storage settings; raises on anything missing or invalid
(define (load-storage-config env)
  (case (env-ref env "STORAGE" "local")
    [("local") (local-storage (env-require env "UPLOAD_DIR"))]
    [("s3") (s3-storage (s3-bucket-from-env env))]
    [else (error 'storage "STORAGE must be local or s3")]))

;; Env -> S3Bucket
(define (s3-bucket-from-env env)
  (define endpoint (parse-endpoint (env-require env "S3_ENDPOINT") (env-require env "S3_REGION")
                                   (equal? (env-ref env "S3_PATH_STYLE") "1")))
  (when (and (eq? (s3-endpoint-scheme endpoint) 'http)
             (string-prefix? (string-downcase (env-ref env "PUBLIC_BASE_URL" "")) "https://"))
    (error 'storage "S3_ENDPOINT must be https when PUBLIC_BASE_URL is https"))
  (s3-bucket endpoint
             (s3-credentials (env-require env "S3_ACCESS_KEY_ID") (env-require env "S3_SECRET_ACCESS_KEY"))
             (env-require env "S3_BUCKET")))

;; String String Boolean -> S3Endpoint
;; the endpoint at `url` (see the header); the port defaults to the scheme's
(define (parse-endpoint url region path-style?)
  (define m (regexp-match #px"^(?i:(https?))://([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?/?$" url))
  (define port (and m (cadddr m) (string->number (cadddr m))))
  (unless (and m (or (not port) (<= 1 port 65535)))
    (error 'storage "S3_ENDPOINT must look like https://host[:port]"))
  (define scheme (string->symbol (string-downcase (cadr m))))
  (s3-endpoint scheme (caddr m) (or port (if (eq? scheme 'https) 443 80)) region path-style?
               default-connect-timeout default-idle-timeout))

;; StorageConfig -> Store
(define (storage-config->store cfg)
  (cond [(local-storage? cfg) (local-store (local-storage-dir cfg))]
        [else (s3-store (s3-storage-bucket cfg))]))

(module+ test
  (require rackunit racket/sequence)
  (define local-env (hash "UPLOAD_DIR" "/u"))
  (define s3-env (hash "STORAGE" "s3" "UPLOAD_DIR" "/u" "S3_ENDPOINT" "https://eu2.contabostorage.com"
                       "S3_REGION" "eu2" "S3_BUCKET" "orquelo" "S3_ACCESS_KEY_ID" "id"
                       "S3_SECRET_ACCESS_KEY" "secret" "S3_PATH_STYLE" "1"))
  (define (with env . kvs) (for/fold ([h env]) ([kv (in-slice 2 kvs)]) (hash-set h (car kv) (cadr kv))))

  (test-case "local is the default"
    (check-equal? (local-storage-dir (load-storage-config local-env)) "/u")
    (check-exn #rx"UPLOAD_DIR" (λ () (load-storage-config (hash))))
    (check-exn #rx"STORAGE" (λ () (load-storage-config (with local-env "STORAGE" "gcs")))))
  (test-case "s3 settings"
    (define b (s3-storage-bucket (load-storage-config s3-env)))
    (define e (s3-bucket-endpoint b))
    (check-equal? (list (s3-endpoint-scheme e) (s3-endpoint-host e) (s3-endpoint-port e)
                        (s3-endpoint-region e) (s3-endpoint-path-style? e) (s3-bucket-name b))
                  '(https "eu2.contabostorage.com" 443 "eu2" #t "orquelo")))
  (test-case "explicit port, virtual-hosted default"
    (define e (s3-bucket-endpoint (s3-storage-bucket
                                   (load-storage-config (with s3-env "S3_ENDPOINT" "http://127.0.0.1:7079" "S3_PATH_STYLE" "")))))
    (check-equal? (list (s3-endpoint-port e) (s3-endpoint-path-style? e)) '(7079 #f)))
  (test-case "required s3 variables"
    (for ([k '("S3_ENDPOINT" "S3_REGION" "S3_BUCKET" "S3_ACCESS_KEY_ID" "S3_SECRET_ACCESS_KEY")])
      (check-exn (regexp k) (λ () (load-storage-config (hash-remove s3-env k))))))
  (test-case "bad endpoints"
    (for ([bad '("eu2.contabostorage.com" "ftp://h" "https://h/bucket" "" "https://h//" "https://h/x/"
                 "https://u:p@h" "https://u@h" "https://h?x=1" "https://h/?x=1" "https://h#f"
                 "https://[::1]" "https://[::1]:9000" "https://h:0" "https://h:65536" "https://h:"
                 "https:///")])
      (check-exn #rx"S3_ENDPOINT" (λ () (load-storage-config (with s3-env "S3_ENDPOINT" bad))) bad)))
  (test-case "one trailing slash, scheme case and the default timeouts are accepted"
    (define e (s3-bucket-endpoint (s3-storage-bucket
                                   (load-storage-config (with s3-env "S3_ENDPOINT" "HTTPS://h.example:8443/")))))
    (check-equal? (list (s3-endpoint-scheme e) (s3-endpoint-host e) (s3-endpoint-port e)
                        (s3-endpoint-connect-timeout e) (s3-endpoint-idle-timeout e))
                  (list 'https "h.example" 8443 default-connect-timeout default-idle-timeout)))
  (test-case "plain http endpoint is refused behind an https base URL"
    (define env (with s3-env "S3_ENDPOINT" "http://minio:9000" "PUBLIC_BASE_URL" "https://x.cz"))
    (check-exn #rx"https" (λ () (load-storage-config env)))
    (check-not-exn (λ () (load-storage-config (with env "PUBLIC_BASE_URL" "http://localhost:8080")))))
  (test-case "a Store is built for each backend"
    (check-true (store? (storage-config->store (load-storage-config s3-env))))))
