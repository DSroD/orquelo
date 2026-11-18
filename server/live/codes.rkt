#lang racket/base
;; Session codes (10 chars, base32 a-z2-7) and participant UUIDs (v4).
(require racket/contract/base racket/random racket/string racket/list)
(provide (contract-out
          [random-code (-> string?)]
          [random-uuid-v4 (-> string?)]
          [valid-code? (-> any/c boolean?)]
          [valid-uuid? (-> any/c boolean?)]))

(define alphabet "abcdefghijklmnopqrstuvwxyz234567")

;; -> String
;; ten random base32 characters
(define (random-code)
  (define bs (crypto-random-bytes 10))
  (list->string (for/list ([b (in-bytes bs)]) (string-ref alphabet (bitwise-and b 31)))))

;; Bytes -> String
(define (hex bs) (apply string-append (for/list ([b (in-bytes bs)]) (string-append (if (< b 16) "0" "") (number->string b 16)))))

;; -> String
(define (random-uuid-v4)
  (define bs (crypto-random-bytes 16))
  (bytes-set! bs 6 (bitwise-ior #x40 (bitwise-and (bytes-ref bs 6) #x0f)))
  (bytes-set! bs 8 (bitwise-ior #x80 (bitwise-and (bytes-ref bs 8) #x3f)))
  (define h (hex bs))
  (string-join (list (substring h 0 8) (substring h 8 12) (substring h 12 16) (substring h 16 20) (substring h 20)) "-"))

;; Any -> Boolean
(define (valid-code? s) (and (string? s) (regexp-match? #px"^[a-z2-7]{10}$" s)))
;; Any -> Boolean
(define (valid-uuid? s)
  (and (string? s) (regexp-match? #px"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$" s)))

(module+ test
  (require rackunit)
  (test-case "code alphabet and length"
    (for ([_ 200])
      (check-true (valid-code? (random-code)))))
  (test-case "codes differ"
    (check-not-equal? (random-code) (random-code)))
  (test-case "validators"
    (check-false (valid-code? "abcde2345"))
    (check-false (valid-code? "abcde23458"))
    (check-false (valid-code? "ABCDE23456"))
    (check-false (valid-code? #f)))
  (test-case "uuid v4"
    (for ([_ 200]) (check-true (valid-uuid? (random-uuid-v4))))
    (check-false (valid-uuid? "not-a-uuid"))
    (check-false (valid-uuid? "12345678-1234-1234-1234-123456789abc"))))
