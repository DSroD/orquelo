#lang racket/base
;; The exceptions raised by the HTTP client. One handler for exn:fail:http catches a failure of
;; the exchange: a peer refused by `#:check-peer`, a TLS failure (bad certificate or handshake),
;; and the subtypes below. It does not catch a TCP connect that fails (unknown host, connection
;; refused), which stays exn:fail:network, nor programming errors, which stay exn:fail:contract.
;;   exn:fail:http           the base type
;;   exn:fail:http:protocol  the reply is not the HTTP/1.1 the client understands: malformed or
;;                           conflicting headers, an oversized head, a body cut short, bad chunking
;;   exn:fail:http:timeout   connecting, or waiting for the server, took too long
(require racket/contract/base)
(provide (struct-out exn:fail:http)
         (struct-out exn:fail:http:protocol)
         (struct-out exn:fail:http:timeout)
         (contract-out
          [raise-http-error (->* (string?) #:rest list? none/c)]
          [raise-protocol-error (->* (string?) #:rest list? none/c)]
          [raise-timeout-error (->* (string?) #:rest list? none/c)]))

(struct exn:fail:http exn:fail ())
(struct exn:fail:http:protocol exn:fail:http ())
(struct exn:fail:http:timeout exn:fail:http ())

;; String Any ... -> Nothing
(define (raise-http-error fmt . args)
  (raise (exn:fail:http (apply format fmt args) (current-continuation-marks))))

;; String Any ... -> Nothing
(define (raise-protocol-error fmt . args)
  (raise (exn:fail:http:protocol (apply format fmt args) (current-continuation-marks))))

;; String Any ... -> Nothing
(define (raise-timeout-error fmt . args)
  (raise (exn:fail:http:timeout (apply format fmt args) (current-continuation-marks))))

(module+ test
  (require rackunit)
  (define (thrown thunk) (with-handlers ([exn:fail? values]) (thunk)))
  (test-case "the hierarchy"
    (check-pred exn:fail:http:protocol? (thrown (λ () (raise-protocol-error "bad ~a" 1))))
    (check-equal? (exn-message (thrown (λ () (raise-protocol-error "bad ~a" 1)))) "bad 1")
    (check-pred exn:fail:http? (thrown (λ () (raise-timeout-error "slow"))))
    (check-pred exn:fail:http:timeout? (thrown (λ () (raise-timeout-error "slow"))))
    (check-pred exn:fail:http? (thrown (λ () (raise-http-error "refused"))))
    (check-false (exn:fail:http:protocol? (thrown (λ () (raise-http-error "refused")))))
    (check-false (exn:fail:http:protocol? (thrown (λ () (raise-timeout-error "slow")))))))
