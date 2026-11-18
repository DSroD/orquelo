#lang racket/base
;; A small S3 client with AWS Signature V4 signing; see client.rkt for the operations.
(require "client.rkt")
(provide (all-from-out "client.rkt"))
