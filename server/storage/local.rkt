#lang racket/base
;; The local-disk Store: one plain file per key inside a directory.
(require racket/contract/base racket/file "store.rkt")
(provide (contract-out [local-store (-> path-string? store?)]))

;; PathString -> Store
;; a Store keeping its files in `dir` (created if missing)
(define (local-store dir)
  (make-directory* dir)
  (define (at key) (build-path dir key))
  (make-store (λ (key file) (put! (at key) file))
              (λ (key) (open (at key)))
              (λ (key) (delete! (at key)))
              (λ (from to) (copy! dir (at from) (at to)))))

;; Path Path -> Natural
;; moves `file` to `dest`: a rename, so `file` must be on the same filesystem; the size
(define (put! dest file)
  (define size (file-size file))
  (rename-file-or-directory file dest)
  size)

;; Path Path Path -> Void
;; copies `from` to `to` atomically: a reader sees the old file or the whole new one, never part
;; of it. The copy is made beside `to` (same filesystem) and renamed over it.
(define (copy! dir from to)
  (define tmp (make-temporary-file "copy~a" from dir))
  (with-handlers ([exn:fail? (λ (e) (delete-file tmp) (raise e))])
    (rename-file-or-directory tmp to #t)))

;; Path -> (or InputPort #f)
(define (open path)
  (with-handlers ([not-found? (λ (_) #f)])
    (open-input-file path)))

;; Path -> Void
;; deletes the file if present
(define (delete! path)
  (with-handlers ([not-found? void])
    (delete-file path)))

;; Any -> Boolean
;; is `v` the exception for a file that does not exist?
(define (not-found? v)
  (and (exn:fail:filesystem:errno? v)
       (equal? (exn:fail:filesystem:errno-errno v) '(2 . posix))))

(module+ test
  (require rackunit)
  (define (with-dir f)
    (define d (make-temporary-file "orquelo-local~a" 'directory))
    (dynamic-wind void (λ () (f d)) (λ () (delete-directory/files d))))
  (define (staged d content)
    (define p (build-path d "tmp-staged"))
    (display-to-file content p)
    p)
  (define k1 "1-abcdefghij.pdf")
  (define k2 "2-klmnopqrst.pdf")
  (define (slurp s key)
    (define in (store-open s key))
    (begin0 (and in (read-bytes 1000 in)) (when in (close-input-port in))))

  (test-case "put! moves the file in and returns its size"
    (with-dir (λ (d)
      (define s (local-store d))
      (define tmp (staged d "%PDF-1.7 hello"))
      (check-equal? (store-put! s k1 tmp) 14)
      (check-false (file-exists? tmp))
      (check-equal? (slurp s k1) #"%PDF-1.7 hello"))))
  (test-case "open is #f for a missing key"
    (with-dir (λ (d) (check-false (store-open (local-store d) k1)))))
  (test-case "copy! duplicates the content"
    (with-dir (λ (d)
      (define s (local-store d))
      (store-put! s k1 (staged d "abc"))
      (store-copy! s k1 k2)
      (check-equal? (slurp s k2) #"abc")
      (check-equal? (slurp s k1) #"abc"))))
  (test-case "delete! is idempotent"
    (with-dir (λ (d)
      (define s (local-store d))
      (store-put! s k1 (staged d "abc"))
      (store-delete! s k1)
      (store-delete! s k1)
      (check-false (store-open s k1)))))
  (test-case "the directory is created on demand"
    (with-dir (λ (d)
      (local-store (build-path d "a" "b"))
      (check-true (directory-exists? (build-path d "a" "b"))))))
  (test-case "copy! leaves no temporary file behind and replaces an existing target"
    (with-dir (λ (d)
      (define s (local-store d))
      (store-put! s k1 (staged d "new"))
      (store-put! s k2 (staged d "old"))
      (store-copy! s k1 k2)
      (check-equal? (slurp s k2) #"new")
      (check-equal? (sort (map path->string (directory-list d)) string<?) (list k1 k2)))))
  (test-case "copy! of a missing source raises and leaves nothing behind"
    (with-dir (λ (d)
      (check-exn exn:fail:filesystem? (λ () (store-copy! (local-store d) k1 k2)))
      (check-equal? (directory-list d) '()))))
  (test-case "open and delete! tell a missing file from other failures"
    (with-dir (λ (d)
      (define s (local-store d))
      (make-directory (build-path d k1))
      (check-exn exn:fail:filesystem? (λ () (store-delete! s k1)))))))
