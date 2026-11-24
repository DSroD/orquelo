#lang racket/base
;; Independent reference implementations the property tests compare the library against
;; (test-only: never required from main.rkt). Nothing here uses the code under test.
(require racket/list racket/string)
(provide base64url-ref base64url-string? rfc3986-ipv4? rfc3986-ipv6?
         ipv6-forms ipv4->string authority-host)

(define alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

;; Bytes -> String
;; unpadded base64url by plain arithmetic: the bytes as one big number, cut into 6-bit digits
(define (base64url-ref bs)
  (define n (bytes-length bs))
  (define bits (* 8 n))
  (define digits (quotient (+ bits 5) 6))
  (define big (for/fold ([acc 0]) ([b (in-bytes bs)]) (+ (* acc 256) b)))
  (define padded (* big (expt 2 (- (* 6 digits) bits))))
  (build-string digits
                (λ (i) (string-ref alphabet (remainder (quotient padded (expt 64 (- digits 1 i))) 64)))))

;; Any Natural -> Boolean
;; is `s` exactly `len` base64url characters
(define (base64url-string? s len)
  (and (string? s) (= (string-length s) len)
       (for/and ([c (in-string s)]) (and (for/or ([a (in-string alphabet)]) (char=? a c)) #t))))

;; RFC 3986 appendix A, spelled out
(define dec-octet "(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])")
(define ipv4-abnf (string-append dec-octet "(?:\\." dec-octet "){3}"))
(define h16 "[0-9A-Fa-f]{1,4}")
(define ls32 (string-append "(?:" h16 ":" h16 "|" ipv4-abnf ")"))
;; "[*n(h16 ":") h16]" in front of "::"
(define (upto n) (if (zero? n) "" (format "(?:(?:~a:){0,~a}~a)?" h16 (sub1 n) h16)))
(define ipv6-abnf
  (string-join
   (for/list ([alt (in-list
                    (list (string-append "(?:" h16 ":){6}" ls32)
                          (string-append "::(?:" h16 ":){5}" ls32)
                          (string-append (upto 1) "::(?:" h16 ":){4}" ls32)
                          (string-append (upto 2) "::(?:" h16 ":){3}" ls32)
                          (string-append (upto 3) "::(?:" h16 ":){2}" ls32)
                          (string-append (upto 4) "::" h16 ":" ls32)
                          (string-append (upto 5) "::" ls32)
                          (string-append (upto 6) "::" h16)
                          (string-append (upto 7) "::")))])
     (string-append "(?:" alt ")"))
   "|"))
(define ipv4-rx (pregexp (string-append "^" ipv4-abnf "$")))
(define ipv6-rx (pregexp (string-append "^(?:" ipv6-abnf ")$")))

;; String -> Boolean
(define (rfc3986-ipv4? s) (regexp-match? ipv4-rx s))
(define (rfc3986-ipv6? s) (regexp-match? ipv6-rx s))

;; Natural -> String
(define (ipv4->string n)
  (string-join (for/list ([sh '(24 16 8 0)]) (number->string (bitwise-and 255 (arithmetic-shift n (- sh))))) "."))

;; (listof String) (or (cons Natural Natural) #f) -> String
;; the items joined by ":", the half-open index range `run` replaced by "::"
(define (render items run)
  (if run
      (string-append (string-join (take items (car run)) ":") "::" (string-join (drop items (cdr run)) ":"))
      (string-join items ":")))

;; (listof Natural) -> (listof (cons Natural Natural))
;; every non-empty run of zero groups, as index ranges
(define (zero-runs gs)
  (for*/list ([i (in-range (length gs))] [j (in-range (add1 i) (add1 (length gs)))]
              #:when (andmap zero? (take (drop gs i) (- j i))))
    (cons i j)))

;; (listof Natural) -> (cons Natural Natural)
;; RFC 5952 section 4.2: the longest run of at least two zero groups, the first on a tie
(define (longest-run gs)
  (for/fold ([best #f]) ([r (zero-runs gs)] #:when (>= (- (cdr r) (car r)) 2))
    (if (or (not best) (> (- (cdr r) (car r)) (- (cdr best) (car best)))) r best)))

;; (listof Natural) -> (listof String)
;; every textual form of the eight 16-bit groups: unpadded, padded, upper case, RFC 5952, every
;; "::" placement over zero groups, and the same with the last two groups as a dotted quad
(define (ipv6-forms gs)
  (define (hex g pad?) (let ([s (number->string g 16)]) (if pad? (string-append (make-string (- 4 (string-length s)) #\0) s) s)))
  (define (items pad?) (for/list ([g gs]) (hex g pad?)))
  (define quad (ipv4->string (+ (* (list-ref gs 6) 65536) (list-ref gs 7))))
  (define head6 (take gs 6))
  (define (items6 pad?) (append (for/list ([g head6]) (hex g pad?)) (list quad)))
  (remove-duplicates
   (append
    (list (render (items #f) #f) (render (items #t) #f) (string-upcase (render (items #f) #f))
          (render (items6 #f) #f) (render (items6 #t) #f))
    (let ([r (longest-run gs)]) (if r (list (render (items #f) r)) '()))
    (for*/list ([r (zero-runs gs)] [pad? '(#f #t)]) (render (items pad?) r))
    (for/list ([r (zero-runs gs)]) (string-upcase (render (items #f) r)))
    (for*/list ([r (zero-runs head6)] [pad? '(#f #t)]) (render (items6 pad?) r)))))

;; String -> String
;; the host of an absolute URI: after "//", before any "/", "?" or "#", after the last "@" of the
;; authority, and without a port
(define (authority-host uri)
  (define after (cadr (regexp-match #rx"^[^:/?#]*:(?://)?(.*)$" uri)))
  (define authority (car (regexp-match #rx"^[^/?#]*" after)))
  (define hostport (last (string-split authority "@" #:trim? #f)))
  (cond [(regexp-match #rx"^(\\[[^]]*\\])" hostport) => cadr]
        [else (car (string-split hostport ":" #:trim? #f))]))

(module+ test
  (require rackunit)
  (check-equal? (base64url-ref (bytes 251 255 190)) "-_--")
  (check-equal? (base64url-ref #"a") "YQ")
  (check-true (rfc3986-ipv6? "::1"))
  (check-true (rfc3986-ipv6? "::ffff:1.2.3.4"))
  (check-false (rfc3986-ipv6? "1:2:3:4:5:6:7::8"))
  (check-false (rfc3986-ipv4? "01.2.3.4"))
  (check-equal? (authority-host "https://u:p@a.example:8080/x?y#z") "a.example")
  (check-equal? (authority-host "http://[::1]:80/") "[::1]")
  (check-not-false (member "2001:db8::1" (ipv6-forms '(#x2001 #xdb8 0 0 0 0 0 1))))
  (check-not-false (member "::1.2.3.4" (ipv6-forms '(0 0 0 0 0 0 #x102 #x304)))))
