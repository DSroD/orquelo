#lang racket/base
;; Integration tests: the S3 client and the S3 Store against a real S3 endpoint.
;; Needs the S3_* environment (see scripts/with-ephemeral-s3); without S3_ENDPOINT it prints
;; S3-SKIPPED and passes, so CI must fail on that marker.
(require rackunit racket/file racket/port "../s3/main.rkt" "../storage/config.rkt" "../storage/store.rkt")

;; -> (Hashof String String)
(define (current-env)
  (for/hash ([n (in-list (environment-variables-names (current-environment-variables)))])
    (define k (bytes->string/utf-8 n #\?))
    (values k (bytes->string/utf-8 (or (environment-variables-ref (current-environment-variables) n) #"") #\?))))

;; Bytes -> Path
;; a temporary file with the given content
(define (temp-file content)
  (define f (make-temporary-file "orquelo-s3~a"))
  (call-with-output-file f #:exists 'truncate (λ (o) (write-bytes content o)))
  f)

;; S3Bucket Key -> (or Bytes #f)
(define (fetch bucket key)
  (define in (get-object bucket key))
  (and in (begin0 (port->bytes in) (close-input-port in))))

(define (code-of thunk)
  (with-handlers ([exn:fail:s3:response? exn:fail:s3:response-code]) (thunk) #f))

(module+ test
  (cond
    [(getenv "S3_ENDPOINT") (run-tests (s3-storage-bucket (load-storage-config (current-env))))]
    [else (eprintf "S3-SKIPPED s3-test: S3_ENDPOINT not set (use scripts/with-ephemeral-s3)\n")]))

;; S3Bucket -> Void
(define (run-tests bucket)
  (define prefix (format "test-~a/" (current-milliseconds)))
  (define (key name) (string-append prefix name))

  (test-case "put, head, get, delete"
    (define f (temp-file #"%PDF-1.7 hello"))
    (put-object! bucket (key "a.pdf") f)
    (check-equal? (object-info-size (head-object bucket (key "a.pdf"))) 14)
    (check-equal? (fetch bucket (key "a.pdf")) #"%PDF-1.7 hello")
    (delete-object! bucket (key "a.pdf"))
    (check-false (head-object bucket (key "a.pdf")))
    (check-false (get-object bucket (key "a.pdf")))
    (delete-file f))

  (test-case "delete of a missing object is not an error"
    (check-not-exn (λ () (delete-object! bucket (key "never-existed")))))

  (test-case "a multi-megabyte object streams both ways intact"
    (define content (make-bytes (* 6 1024 1024) 97))
    (bytes-set! content 1000 0)
    (define f (temp-file content))
    (put-object! bucket (key "big") f)
    (check-equal? (fetch bucket (key "big")) content)
    (delete-object! bucket (key "big"))
    (delete-file f))

  (test-case "copy-object! duplicates; a missing source fails"
    (define f (temp-file #"copy me"))
    (put-object! bucket (key "src") f)
    (copy-object! bucket (key "src") (key "dst"))
    (check-equal? (fetch bucket (key "dst")) #"copy me")
    (check-equal? (code-of (λ () (copy-object! bucket (key "nope") (key "dst2")))) "NoSuchKey")
    (for-each (λ (k) (delete-object! bucket (key k))) '("src" "dst"))
    (delete-file f))

  (test-case "nested keys with dots, dashes and underscores"
    (define f (temp-file #"x"))
    (put-object! bucket (key "dir/sub/a_b-c.d.pdf") f)
    (check-equal? (fetch bucket (key "dir/sub/a_b-c.d.pdf")) #"x")
    (delete-object! bucket (key "dir/sub/a_b-c.d.pdf"))
    (delete-file f))

  (test-case "errors carry the status and code"
    (define f (temp-file #"x"))
    (define wrong-bucket (struct-copy s3-bucket bucket [name "no-such-bucket-orquelo"]))
    (check-equal? (code-of (λ () (put-object! wrong-bucket (key "x") f))) "NoSuchBucket")
    (define bad-creds (struct-copy s3-bucket bucket [credentials (s3-credentials "orquelo" "wrong")]))
    (check-equal? (code-of (λ () (get-object bad-creds (key "x")))) "SignatureDoesNotMatch")
    (delete-file f))

  (test-case "the Store round-trips and consumes the staged file"
    (define store (storage-config->store (s3-storage bucket)))
    (define k1 (new-pdf-key 9001))
    (define k2 (new-pdf-key 9002))
    (define f (temp-file #"%PDF-1.4 store"))
    (check-equal? (store-put! store k1 f) 14)
    (check-false (file-exists? f))
    (define in (store-open store k1))
    (check-equal? (port->bytes in) #"%PDF-1.4 store")
    (close-input-port in)
    (store-copy! store k1 k2)
    (let ([p (store-open store k2)]) (check-true (input-port? p)) (close-input-port p))
    (store-delete! store k1)
    (store-delete! store k2)
    (store-delete! store k2)
    (check-false (store-open store k1))
    (check-false (store-open store k2))))
