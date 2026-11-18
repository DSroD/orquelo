#lang racket/base
;; Staging of uploaded PDFs: validate into a tmp-* file in the upload directory. The file is
;; then handed to the Store (storage/store.rkt), which consumes it.
(require racket/contract/base racket/file "live/codes.rkt")
(provide max-pdf-bytes
         (contract-out
          [save-tmp-pdf! (-> path-string? input-port? (or/c path? string?))]))

;; Natural
(define max-pdf-bytes (* 100 1024 1024))

;; Path InputPort -> (or Path String)
;; copies `in` to a tmp file in dir: its path, or an error message (nothing is left on disk)
(define (save-tmp-pdf! dir in)
  (make-directory* dir)
  (define magic (read-bytes 5 in))
  (cond
    [(not (equal? magic #"%PDF-")) "file is not a PDF"]
    [else
     (define tmp (build-path dir (string-append "tmp-" (random-code))))
     (define size
       (call-with-output-file tmp #:exists 'error
         (λ (out)
           (write-bytes magic out)
           (let loop ([n 5])
             (define b (read-bytes 65536 in))
             (cond [(eof-object? b) n]
                   [(> (+ n (bytes-length b)) max-pdf-bytes) #f]
                   [else (write-bytes b out) (loop (+ n (bytes-length b)))])))))
     (cond [size tmp]
           [else (delete-file tmp) "PDF is larger than 100 MiB"])]))

(module+ test
  (require rackunit)
  (define (with-dir f) (define d (make-temporary-file "orquelo-up~a" 'directory)) (dynamic-wind void (λ () (f d)) (λ () (delete-directory/files d))))
  (test-case "valid pdf is staged as a tmp file"
    (with-dir (λ (d)
      (define tmp (save-tmp-pdf! d (open-input-bytes #"%PDF-1.7 hello")))
      (check-true (path? tmp))
      (check-equal? (file->bytes tmp) #"%PDF-1.7 hello")
      (check-equal? (file-size tmp) 14))))
  (test-case "non-pdf rejected, nothing left behind"
    (with-dir (λ (d)
      (check-equal? (save-tmp-pdf! d (open-input-bytes #"GIF89a....")) "file is not a PDF")
      (check-equal? (save-tmp-pdf! d (open-input-bytes #"")) "file is not a PDF")
      (check-equal? (directory-list d) '())))))
