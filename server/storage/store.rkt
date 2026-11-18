#lang racket/base
;; The storage interface for uploaded PDFs: a Store is a bundle of four operations over
;; Keys, implemented by storage/local.rkt and storage/s3.rkt. Everything outside server/storage/
;; reaches stored files only through this module.
(require racket/contract/base "../live/codes.rkt")
(provide (contract-out
          [store? (-> any/c boolean?)]
          [make-store (-> (-> pdf-key? path? exact-nonnegative-integer?)
                          (-> pdf-key? (or/c input-port? #f))
                          (-> pdf-key? void?)
                          (-> pdf-key? pdf-key? void?)
                          store?)]
          [store-put! (-> store? pdf-key? path? exact-nonnegative-integer?)]
          [store-open (-> store? pdf-key? (or/c input-port? #f))]
          [store-delete! (-> store? pdf-key? void?)]
          [store-copy! (-> store? pdf-key? pdf-key? void?)]
          [pdf-key? (-> any/c boolean?)]
          [new-pdf-key (-> exact-positive-integer? pdf-key?)]))

;; A Key is a String matching #px"^[0-9]+-[a-z2-7]{10}\\.pdf$": "<presentation id>-<session code>.pdf".
;; The pattern doubles as path-traversal protection: a Key is always a plain basename.
;;
;; A Store is a (store Put Open Delete Copy), where
;;   Put    : Key Path -> Natural             stores the file at Path under Key, consumes (moves or
;;                                            deletes) the file and returns its size in bytes;
;;                                            on failure the file is left in place
;;   Open   : Key -> (or InputPort #f)        a fresh port on the content, #f when Key is missing;
;;                                            the caller closes the port
;;   Delete : Key -> Void                     idempotent
;;   Copy   : Key Key -> Void                 copies the content of the first Key to the second
(struct store (put-proc open-proc delete-proc copy-proc) #:constructor-name make-store #:omit-define-syntaxes)

;; Any -> Boolean
;; is `v` a well-formed storage key?
(define (pdf-key? v)
  (and (string? v) (regexp-match? #px"^[0-9]+-[a-z2-7]{10}\\.pdf$" v)))

;; Natural -> Key
;; a fresh key for presentation `id`
(define (new-pdf-key id)
  (format "~a-~a.pdf" id (random-code)))

;; Store Key Path -> Natural
(define (store-put! s key file) ((store-put-proc s) key file))
;; Store Key -> (or InputPort #f)
(define (store-open s key) ((store-open-proc s) key))
;; Store Key -> Void
(define (store-delete! s key) ((store-delete-proc s) key))
;; Store Key Key -> Void
(define (store-copy! s from to) ((store-copy-proc s) from to))

(module+ test
  (require rackunit)
  (test-case "keys"
    (check-true (pdf-key? "7-abcdefghij.pdf"))
    (check-true (pdf-key? (new-pdf-key 42)))
    (check-regexp-match #px"^42-[a-z2-7]{10}\\.pdf$" (new-pdf-key 42))
    (for ([bad '("../etc/passwd" "1-abcdefghij.pdf/../x" "pending" "1-ABCDEFGHIJ.pdf" "-abcdefghij.pdf" 7)])
      (check-false (pdf-key? bad))))
  (test-case "operations dispatch to the procedures"
    (define s (make-store (λ (k p) 3) (λ (k) #f) (λ (k) (void)) (λ (a b) (void))))
    (check-equal? (store-put! s "1-abcdefghij.pdf" (string->path "/x")) 3)
    (check-false (store-open s "1-abcdefghij.pdf"))))
