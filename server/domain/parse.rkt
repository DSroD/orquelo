#lang racket/base
(require racket/contract/base)
(provide (contract-out
          [struct (exn:domain exn:fail) ([message string?] [continuation-marks continuation-mark-set?] [field symbol?])]
          [domain-error! (-> symbol? string? none/c)]))

;; A DomainError is an (exn:domain String ContinuationMarkSet Symbol).
;; interp. input that cannot be represented by the domain, with the offending field.
(struct exn:domain exn:fail (field) #:transparent)

;; Symbol String -> Nothing
;; reports why input cannot become a domain value
(define (domain-error! field message)
  (raise (exn:domain message (current-continuation-marks) field)))
