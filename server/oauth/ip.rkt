#lang racket/base
;; Is an IP address one a CIMD fetch may talk to? Used as the http-client's peer check, so it
;; sees the address actually connected to. IPv6 is allow-listed (global unicast 2000::/3 minus
;; documentation and Teredo) and the IPv4 inside mapped, NAT64 and 6to4 addresses is judged as
;; IPv4. Anything that does not parse is refused.
(require racket/contract/base racket/match racket/list racket/string)
(provide (contract-out [public-address? (-> string? boolean?)]))

;; String -> (or Natural #f)
;; a dotted-quad IPv4 address as a 32-bit number; leading zeros are refused as ambiguous
(define (parse-ipv4 s)
  (match (regexp-match #px"^([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})$" s)
    [(list _ octets ...)
     (define ns (map string->number octets))
     (and (andmap (λ (o) (or (= (string-length o) 1) (not (char=? (string-ref o 0) #\0)))) octets)
          (andmap (λ (n) (<= n 255)) ns)
          (for/fold ([acc 0]) ([n (in-list ns)]) (+ (* acc 256) n)))]
    [_ #f]))

;; String -> (or Natural #f)
(define (hex-group s)
  (and (regexp-match? #px"^[0-9a-fA-F]{1,4}$" s) (string->number s 16)))

;; String Boolean -> (or (listof Natural) #f)
;; the 16-bit groups of colon-separated text; the last may be a dotted quad when `v4-tail?`
(define (parse-groups s v4-tail?)
  (cond
    [(string=? s "") '()]
    [else
     (define parts (string-split s ":" #:trim? #f))
     (define v4 (and v4-tail? (parse-ipv4 (last parts))))
     (define groups
       (if v4
           (append (map hex-group (drop-right parts 1)) (list (quotient v4 65536) (remainder v4 65536)))
           (map hex-group parts)))
     (and (andmap values groups) groups)]))

;; String -> (or Natural #f)
;; an IPv6 address (with "::" compression and an optional dotted-quad tail) as a 128-bit number
(define (parse-ipv6 s)
  (define groups
    (match (regexp-split #rx"::" s)
      [(list whole) (let ([g (parse-groups whole #t)]) (and g (= (length g) 8) g))]
      [(list head tail)
       (define h (parse-groups head #f))
       (define t (parse-groups tail #t))
       (and h t (<= (+ (length h) (length t)) 7)
            (append h (make-list (- 8 (length h) (length t)) 0) t))]
      [_ #f]))
  (and groups (for/fold ([acc 0]) ([g (in-list groups)]) (+ (* acc 65536) g))))

;; Natural Natural Natural Natural -> Boolean
;; is `n` (of `bits` bits) inside the block `base`/`prefix`
(define (in-block? n base prefix bits)
  (define drop (- bits prefix))
  (= (arithmetic-shift n (- drop)) (arithmetic-shift base (- drop))))

(define private-v4-blocks
  (for/list ([b (in-list '(("0.0.0.0" 8) ("10.0.0.0" 8) ("100.64.0.0" 10) ("127.0.0.0" 8)
                           ("169.254.0.0" 16) ("172.16.0.0" 12) ("192.0.0.0" 24) ("192.0.2.0" 24)
                           ("192.88.99.0" 24) ("192.168.0.0" 16) ("198.18.0.0" 15) ("198.51.100.0" 24)
                           ("203.0.113.0" 24) ("224.0.0.0" 4) ("240.0.0.0" 4)))])
    (cons (parse-ipv4 (first b)) (second b))))

;; Natural -> Boolean
(define (public-v4? n)
  (for/and ([b (in-list private-v4-blocks)]) (not (in-block? n (car b) (cdr b) 32))))

(define low32 #xffffffff)

;; Natural -> Boolean
(define (public-v6? n)
  (define (in? base prefix) (in-block? n (parse-ipv6 base) prefix 128))
  (cond
    [(or (in? "::ffff:0:0" 96) (in? "64:ff9b::" 96)) (public-v4? (bitwise-and n low32))]
    [(in? "2002::" 16) (public-v4? (bitwise-and (arithmetic-shift n -80) low32))]
    [else (and (in? "2000::" 3)
               (for/and ([b (in-list reserved-v6-blocks)]) (not (in? (car b) (cdr b)))))]))

;; global unicast space that is not for public hosts: IETF protocol assignments (2001::/23, which
;; holds Teredo), benchmarking, ORCHID, documentation
(define reserved-v6-blocks
  '(("2001::" . 23) ("2001:2::" . 48) ("2001:10::" . 28) ("2001:20::" . 28) ("2001:db8::" . 32) ("3fff::" . 20)))

;; String -> Boolean
;; may we connect to this address: a global unicast IPv4 or IPv6 address (see the module comment)
(define (public-address? s)
  (cond [(parse-ipv4 s) => public-v4?]
        [(parse-ipv6 s) => public-v6?]
        [else #f]))

;; what the property tests (tests/ip-prop-test.rkt) reach into
(module+ for-test
  (provide parse-ipv4 parse-ipv6 private-v4-blocks reserved-v6-blocks))

(module+ test
  (require rackunit)
  (define public '("8.8.8.8" "1.1.1.1" "93.184.216.34" "100.63.255.255" "172.15.0.1" "172.32.0.1"
                   "198.17.0.1" "198.20.0.1" "2001:4860:4860::8888" "2606:4700:4700::1111" "2a00:1450:4001::200e"
                   "::ffff:8.8.8.8" "::ffff:808:808" "64:ff9b::8.8.8.8" "2002:808:808::1"))
  (define private '("0.0.0.0" "0.1.2.3" "10.1.2.3" "100.64.0.1" "100.127.255.255" "127.0.0.1" "127.255.0.1"
                    "169.254.169.254" "172.16.0.1" "172.31.255.255" "192.0.0.8" "192.0.2.1" "192.168.1.1"
                    "198.18.0.1" "198.19.255.255" "198.51.100.7" "203.0.113.9" "224.0.0.1" "239.1.1.1"
                    "240.0.0.1" "255.255.255.255"
                    "::" "::1" "fc00::1" "fd12:3456::1" "fe80::1" "ff02::1" "2001:db8::1" "2001::1" "2001:30::1" "2001:1ff::1"
                    "192.88.99.1" "3fff::1" "3fff:fff::1" "2001:2::1" "2001:10::1" "2001:1f::1" "2001:20::1" "2001:2f::1" "5f00::1"
                    "::ffff:127.0.0.1" "::ffff:10.0.0.1" "::ffff:7f00:1" "::ffff:169.254.169.254"
                    "64:ff9b::10.0.0.1" "64:ff9b::7f00:1" "2002:7f00:1::1" "::8.8.8.8"
                    "1::2::3" "1:2:3:4:5:6:7:8:9" "12345::1" "gggg::1" "1.2.3" "1.2.3.256" "010.0.0.1"
                    "" "example.com" "::ffff:1.2.3" "1:2:3:4:5:6:7::8"))
  (for ([a public]) (check-true (public-address? a) a))
  (for ([a private]) (check-false (public-address? a) a)))
