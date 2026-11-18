#lang racket/base
;; The exceptions raised by the S3 client. All are exn:fail:s3, so one handler catches any
;; failure of the client itself (programming errors such as a bad argument stay exn:fail:contract):
;;   exn:fail:s3           the base type
;;   exn:fail:s3:response  the server answered with an error status; carries the HTTP status
;;                         and the <Code> of the error document (e.g. "NoSuchBucket"), if any
;;   exn:fail:s3:protocol  the reply is not the HTTP/1.1 the client understands: malformed or
;;                         conflicting headers, an oversized head, a body cut short, chunked encoding
;;   exn:fail:s3:timeout   connecting, or waiting for the server, took longer than the endpoint allows
(require racket/contract/base)
(provide (struct-out exn:fail:s3)
         (struct-out exn:fail:s3:response)
         (struct-out exn:fail:s3:protocol)
         (struct-out exn:fail:s3:timeout)
         (contract-out
          [raise-protocol-error (->* (string?) #:rest list? none/c)]
          [raise-timeout-error (->* (string?) #:rest list? none/c)]))

(struct exn:fail:s3 exn:fail ())
;; An exn:fail:s3:response adds (or Natural #f) status and (or String #f) code.
(struct exn:fail:s3:response exn:fail:s3 (status code))
(struct exn:fail:s3:protocol exn:fail:s3 ())
(struct exn:fail:s3:timeout exn:fail:s3 ())

;; String Any ... -> Nothing
(define (raise-protocol-error fmt . args)
  (raise (exn:fail:s3:protocol (apply format fmt args) (current-continuation-marks))))

;; String Any ... -> Nothing
(define (raise-timeout-error fmt . args)
  (raise (exn:fail:s3:timeout (apply format fmt args) (current-continuation-marks))))

(module+ test
  (require rackunit)
  (test-case "the hierarchy"
    (define (thrown thunk) (with-handlers ([exn:fail? values]) (thunk)))
    (check-pred exn:fail:s3:protocol? (thrown (λ () (raise-protocol-error "bad ~a" 1))))
    (check-equal? (exn-message (thrown (λ () (raise-protocol-error "bad ~a" 1)))) "bad 1")
    (check-pred exn:fail:s3? (thrown (λ () (raise-timeout-error "slow"))))
    (check-pred exn:fail:s3:timeout? (thrown (λ () (raise-timeout-error "slow"))))
    (check-false (exn:fail:s3:protocol? (thrown (λ () (raise-timeout-error "slow")))))))
