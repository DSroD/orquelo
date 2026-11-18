#lang racket/base
;; The S3 Store: each key is an object in one bucket.
(require racket/contract/base "../s3/main.rkt" "store.rkt")
(provide (contract-out [s3-store (-> s3-bucket? store?)]))

;; S3Bucket -> Store
(define (s3-store bucket)
  (make-store (λ (key file) (put! bucket key file))
              (λ (key) (get-object bucket key))
              (λ (key) (delete-object! bucket key))
              (λ (from to) (copy-object! bucket from to))))

;; S3Bucket Key Path -> Natural
;; uploads `file`, then deletes it; the size
(define (put! bucket key file)
  (define size (file-size file))
  (put-object! bucket key file)
  (delete-file file)
  size)

(module+ test
  (require rackunit)
  (test-case "s3-store builds a Store (operations are exercised by tests/s3-test.rkt)"
    (check-true (store? (s3-store (s3-bucket (s3-endpoint 'http "127.0.0.1" 1 "r" #t
                                                        default-connect-timeout default-idle-timeout)
                                              (s3-credentials "k" "s") "bkt"))))))
