#lang racket/base
;; The caller's address, and the 429 response for a caller that must back off.
(require racket/contract/base racket/list racket/match racket/string web-server/http "json.rkt")
(provide (contract-out
          [client-ip (-> request? boolean? string?)]
          [rate-key (-> string? string?)]
          [throttled! (-> real? none/c)]
          [too-many-requests (-> exact-nonnegative-integer? response?)]
          [exn:throttled-seconds (-> exn:throttled? exact-nonnegative-integer?)])
         exn:throttled?)

;; Request Boolean -> String
;; the address the throttle counts failures against: the rightmost X-Forwarded-For entry (the one our
;; own ingress appended; earlier ones are client-controlled) when behind a trusted proxy, else the peer
(define (client-ip req trust-proxy?)
  (define xff (and trust-proxy? (headers-assq* #"X-Forwarded-For" (request-headers/raw req))))
  (define last-entry
    (and xff (let ([es (string-split (bytes->string/utf-8 (header-value xff) #\?) ",")])
               (and (pair? es) (string-trim (last es))))))
  (if (and last-entry (non-empty-string? last-entry)) last-entry (request-client-ip req)))

;; String -> String
;; the key a rate limit counts an address under: an IPv4 address as it is, an IPv6 one as its /64 (one
;; subscriber commonly holds a whole /64, so per-address buckets would give an attacker 2^64 of them).
;; An IPv4-mapped IPv6 address is the IPv4 one; text that is no address is kept as it is
(define (rate-key ip)
  (define addr (car (regexp-split #rx"%" ip)))
  (match (and (regexp-match? #rx":" addr) (ipv6-groups (string-trim addr)))
    [(list 0 0 0 0 0 #xffff hi lo) (format "~a.~a.~a.~a" (quotient hi 256) (remainder hi 256) (quotient lo 256) (remainder lo 256))]
    [(list a b c d _ ...) (format "~a:~a:~a:~a::/64" (number->string a 16) (number->string b 16) (number->string c 16) (number->string d 16))]
    [_ (string-trim ip)]))

;; String -> (or (Listof Natural) #f)
;; the eight 16-bit groups of an IPv6 address (a dotted-quad tail counts as two), #f when it is none
(define (ipv6-groups s)
  (define (groups part)
    (cond [(string=? part "") '()]
          [else (define items (string-split part ":" #:trim? #f))
                (define v4 (regexp-match #px"^([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})$" (last items)))
                (define nums (map (λ (g) (and (regexp-match? #px"^[0-9a-fA-F]{1,4}$" g) (string->number g 16)))
                                  (if v4 (drop-right items 1) items)))
                (define tail (if v4 (let ([o (map string->number (cdr v4))])
                                      (and (andmap (λ (n) (<= n 255)) o)
                                           (list (+ (* 256 (first o)) (second o)) (+ (* 256 (third o)) (fourth o)))))
                                 '()))
                (and (andmap values nums) tail (append nums tail))]))
  (match (regexp-split #rx"::" s)
    [(list whole) (let ([g (groups whole)]) (and g (= (length g) 8) g))]
    [(list head tail) (let ([h (groups head)] [t (groups tail)])
                        (and h t (<= (+ (length h) (length t)) 7)
                             (append h (make-list (- 8 (length h) (length t)) 0) t)))]
    [_ #f]))

;; An exn:throttled is a (exn:throttled String Marks Natural)
;; interpretation: a refusal, with the whole seconds the caller should wait
(struct exn:throttled exn:fail (seconds))

;; Real -> Nothing
;; 429 with Retry-After (whole seconds, rounded up)
(define (throttled! wait)
  (raise (exn:throttled "too many attempts, try again later" (current-continuation-marks) (inexact->exact (ceiling wait)))))

;; Natural -> Response
(define (too-many-requests seconds)
  (define r (error-response 429 "throttled" "too many attempts, try again later"))
  (struct-copy response r [headers (cons (header #"Retry-After" (string->bytes/utf-8 (number->string seconds))) (response-headers r))]))

(module+ test
  (require rackunit racket/promise net/url)
  (define (req . headers)
    (make-request #"POST" (string->url "/auth/password") (for/list ([h headers]) (make-header (car h) (cdr h)))
                  (delay '()) #f "10.0.0.9" 80 "10.0.0.9"))
  (test-case "client-ip: the peer, or the rightmost X-Forwarded-For entry behind a trusted proxy"
    (check-equal? (client-ip (req) #f) "10.0.0.9")
    (check-equal? (client-ip (req (cons #"X-Forwarded-For" #"1.1.1.1, 2.2.2.2")) #f) "10.0.0.9")
    (check-equal? (client-ip (req (cons #"X-Forwarded-For" #"6.6.6.6, 2.2.2.2")) #t) "2.2.2.2")
    (check-equal? (client-ip (req (cons #"X-Forwarded-For" #"3.3.3.3")) #t) "3.3.3.3")
    (check-equal? (client-ip (req) #t) "10.0.0.9"))
  (test-case "rate-key: IPv4 whole, IPv6 by its /64"
    (check-equal? (rate-key "10.0.0.9") "10.0.0.9")
    (check-equal? (rate-key "2001:db8:1:2:3:4:5:6") "2001:db8:1:2::/64")
    (check-equal? (rate-key "2001:DB8:1:2:ffff::1") "2001:db8:1:2::/64")
    (check-equal? (rate-key "2001:db8:1:2::") (rate-key "2001:db8:1:2:aaaa:bbbb:cccc:dddd"))
    (check-not-equal? (rate-key "2001:db8:1:3::1") (rate-key "2001:db8:1:2::1"))
    (check-equal? (rate-key "2001:db8::1") "2001:db8:0:0::/64")
    (check-equal? (rate-key "::1") "0:0:0:0::/64")
    (check-equal? (rate-key "::ffff:10.0.0.9") "10.0.0.9")
    (check-equal? (rate-key "fe80::1%eth0") "fe80:0:0:0::/64")
    (check-equal? (rate-key "not-an-address") "not-an-address")
    (check-equal? (rate-key "") ""))
  (test-case "throttled! rounds the wait up; too-many-requests carries Retry-After"
    (check-equal? (with-handlers ([exn:throttled? exn:throttled-seconds]) (throttled! 0.2)) 1)
    (define r (too-many-requests 7))
    (check-equal? (response-code r) 429)
    (check-equal? (header-value (headers-assq* #"Retry-After" (response-headers r))) #"7")))
