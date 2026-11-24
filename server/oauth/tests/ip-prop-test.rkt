#lang racket/base
;; Properties of the IP parser and classifier: textual forms, agreement with RFC 3986, and the
;; reserved blocks.
(require rackcheck rackunit racket/list racket/string
         (submod "../ip.rkt" for-test) "../ip.rkt" "prop.rkt" "reference.rkt")

;; -> Gen
;; one 16-bit group: often zero (so "::" has runs to cover), small, any, or a well-known prefix
(define gen:group
  (gen:frequency (list (cons 4 (gen:const 0)) (cons 2 (gen:integer-in 1 15)) (cons 2 (gen:integer-in 0 65535))
                       (cons 1 (gen:one-of '(#xffff #x100 #xfe80 #x2001 #xdb8 #x64 #xff9b #x2002))))))
(define gen:groups (gen:map (gen:tuple gen:group gen:group gen:group gen:group gen:group gen:group gen:group gen:group) values))
;; -> Gen
;; one IPv4 octet: any, or one at a boundary of the decimal grammar
(define gen:octet (gen:frequency (list (cons 3 (gen:integer-in 0 255)) (cons 1 (gen:one-of '(0 1 9 10 99 100 199 200 249 250 255))))))
(define gen:octets (gen:map (gen:tuple gen:octet gen:octet gen:octet gen:octet) values))

;; (listof Natural) -> Natural
(define (groups->n gs) (for/fold ([acc 0]) ([g gs]) (+ (* acc 65536) g)))
;; Natural -> (listof Natural)
(define (n->groups n) (for/list ([i (in-range 7 -1 -1)]) (bitwise-and #xffff (arithmetic-shift n (* -16 i)))))
;; (listof Natural) -> Natural
(define (octets->n os) (for/fold ([acc 0]) ([o os]) (+ (* acc 256) o)))
;; (listof (or Natural String)) -> String
(define (quad os) (string-join (map (λ (o) (if (string? o) o (number->string o))) os) "."))

;; Natural Natural Natural Natural -> Natural
;; `r` with the top `prefix` bits (of `bits`) taken from `base`
(define (in-block-of base prefix bits r)
  (define low (- bits prefix))
  (+ (arithmetic-shift (arithmetic-shift base (- low)) low) (bitwise-and r (sub1 (expt 2 low)))))
;; Natural Natural Natural Natural -> Boolean
(define (inside? n base prefix bits)
  (= (arithmetic-shift n (- (- bits prefix))) (arithmetic-shift base (- (- bits prefix)))))

(define tokens '("0" "1" "a" "F" "ff" "1234" "12345" "255" "256" "25" "01" ":" "::" ":" ":" "." "." "g" " " "1.2.3.4" "10" "2" "0000"))
;; -> Gen
;; random concatenations of address fragments: digits, hex, colons, dots, a stray "g" or space
(define gen:soup (gen:map (gen:list (gen:one-of tokens) #:max-length 14) (λ (ts) (string-append* ts))))

;; Gen: a valid form of an address, with one character deleted, duplicated or replaced
(define gen:mutated
  (gen:let ([gs gen:groups] [k gen:natural] [i gen:natural] [how (gen:one-of '(drop dup swap))] [c (gen:one-of (string->list ":.0g1a"))]
            [v4? gen:boolean] [os gen:octets])
    (define forms (ipv6-forms gs))
    (define s (if v4? (quad os) (list-ref forms (modulo k (length forms)))))
    (define j (modulo i (string-length s)))
    (case how
      [(drop) (string-append (substring s 0 j) (substring s (add1 j)))]
      [(dup) (string-append (substring s 0 j) (string (string-ref s j)) (substring s j))]
      [else (string-append (substring s 0 j) (string c) (substring s (add1 j)))])))

(test-case "every way of writing an IPv6 address parses to that address"
  ;; the second conjunct checks that the forms we generate really are RFC 3986 IPv6, which the
  ;; "accept exactly" test case below only reaches by chance for unmodified forms
  (check-property
   (prop-config 1500)
   (property ([gs gen:groups])
     (define n (groups->n gs))
     (for/and ([f (ipv6-forms gs)]) (and (equal? (parse-ipv6 f) n) (rfc3986-ipv6? f))))))

(test-case "a dotted quad parses to its number, and an octet with a leading zero is refused"
  ;; the RFC 3986 conjuncts check the generated quads, as above
  (check-property
   (prop-config 1500)
   (property ([os gen:octets] [i (gen:integer-in 0 3)])
     (define s (quad os))
     (define padded (quad (for/list ([o os] [k (in-naturals)]) (if (= k i) (string-append "0" (number->string o)) o))))
     (and (equal? (parse-ipv4 s) (octets->n os)) (rfc3986-ipv4? s)
          (not (parse-ipv4 padded)) (not (rfc3986-ipv4? padded))))))

(test-case "the parsers accept exactly the text the RFC 3986 grammar accepts"
  ;; mostly valid forms with one character dropped, doubled or replaced (3), random fragments (2)
  (check-property
   (prop-config 4000)
   (property ([s (gen:frequency (list (cons 2 gen:soup) (cons 3 gen:mutated)))])
     (and (equal? (and (parse-ipv4 s) #t) (rfc3986-ipv4? s))
          (equal? (and (parse-ipv6 s) #t) (rfc3986-ipv6? s))))))

;; kept despite the equalities above: it covers arbitrary text, up to 30 random characters (1)
(test-case "public-address? answers true or false for any text and never raises"
  (check-property
   (prop-config 3000)
   (property ([s (gen:frequency (list (cons 2 gen:soup) (cons 3 gen:mutated) (cons 1 (gen:string gen:char #:max-length 30))))])
     (boolean? (public-address? s)))))

(test-case "addresses inside a reserved IPv4 block are refused"
  (check-property
   (prop-config 2000)
   (property ([i (gen:integer-in 0 (sub1 (length private-v4-blocks)))] [os gen:octets])
     (define b (list-ref private-v4-blocks i))
     (define n (in-block-of (car b) (cdr b) 32 (octets->n os)))
     (not (public-address? (ipv4->string n))))))

(test-case "addresses inside a reserved IPv6 block are refused"
  (check-property
   (prop-config 2000)
   (property ([i (gen:integer-in 0 (sub1 (length reserved-v6-blocks)))] [gs gen:groups] [k gen:natural])
     (define b (list-ref reserved-v6-blocks i))
     (define n (in-block-of (parse-ipv6 (car b)) (cdr b) 128 (groups->n gs)))
     (define forms (ipv6-forms (n->groups n)))
     (not (public-address? (list-ref forms (modulo k (length forms))))))))

(test-case "global unicast IPv6 addresses outside every reserved block are accepted"
  (define blocks (cons (cons "2002::" 16) reserved-v6-blocks))
  (check-property
   (prop-config 2000)
   (property ([gs (gen:filter (gen:map gen:groups (λ (gs) (cons (+ #x2000 (modulo (car gs) #x2000)) (cdr gs))))
                              (λ (gs) (not (for/or ([b blocks]) (inside? (groups->n gs) (parse-ipv6 (car b)) (cdr b) 128)))))]
              [k gen:natural])
     (define forms (ipv6-forms gs))
     (public-address? (list-ref forms (modulo k (length forms)))))))

(test-case "IPv6 outside 2000::/3 is refused, unless it embeds an IPv4 address"
  (check-property
   (prop-config 2000)
   (property ([gs (gen:filter gen:groups
                              (λ (gs) (let ([n (groups->n gs)])
                                        (not (or (inside? n (parse-ipv6 "2000::") 3 128)
                                                 (inside? n (parse-ipv6 "::ffff:0:0") 96 128)
                                                 (inside? n (parse-ipv6 "64:ff9b::") 96 128))))))])
     (not (public-address? (car (ipv6-forms gs)))))))

(test-case "IPv4 embedded in mapped, NAT64 and 6to4 addresses is judged as IPv4"
  (check-property
   (prop-config 2000)
   (property ([os gen:octets] [which (gen:one-of '(mapped nat64 6to4))])
     (define v4 (octets->n os))
     (define n (case which
                 [(mapped) (+ (parse-ipv6 "::ffff:0:0") v4)]
                 [(nat64) (+ (parse-ipv6 "64:ff9b::") v4)]
                 [else (+ (parse-ipv6 "2002::") (* v4 (expt 2 80)))]))
     (equal? (public-address? (car (ipv6-forms (n->groups n)))) (public-address? (quad os))))))
