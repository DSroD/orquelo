#lang racket/base
;; Properties of base64url, the opaque token format and PKCE against independent references.
(require rackcheck rackunit racket/list
         "../base64url.rkt" "../token-format.rkt" "../pkce.rkt" "prop.rkt" "reference.rkt" "gen.rkt")

(define unreserved (string->list "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))
(define b64-chars (string->list "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"))
(define outsiders (list #\+ #\/ #\= #\space #\é #\٣ #\Ａ #\newline #\nul))

;; (listof Char) Natural -> Gen
;; strings of exactly n characters drawn from cs
(define (gen:exactly-of cs n) (gen:map (gen:tuple* (make-list n (gen:one-of cs))) list->string))
;; (listof Gen) -> Gen
;; a list with one value from each generator
(define (gen:tuple* gs) (if (null? gs) (gen:const '()) (gen:bind (car gs) (λ (x) (gen:map (gen:tuple* (cdr gs)) (λ (r) (cons x r)))))))

;; String Natural Char -> String
(define (set-char s i c) (string-append (substring s 0 i) (string c) (substring s (add1 i))))

;; String -> String
(define (pkce-ref verifier) (base64url-ref (sha256-bytes (string->bytes/utf-8 verifier))))

;; -> Gen
;; mostly arbitrary bytes; sometimes bytes at the edges of 6-bit groups (0, 1, 63, 64, 252, 255)
(define gen:bytes-wide
  (gen:frequency (list (cons 4 (gen:bytes #:max-length 100))
                       (cons 1 (gen:map (gen:list (gen:one-of '(0 255 63 64 252 1)) #:max-length 40) list->bytes)))))

;; base64url-encode gives exactly the text of the arithmetic reference, which settles its length and
;; alphabet too
(test-case "base64url-encode agrees with an independent implementation on any bytes"
  (check-property
   (prop-config 600)
   (property ([bs gen:bytes-wide])
     (equal? (base64url-encode bs) (base64url-ref bs)))))

;; An opaque token is 43 base64url characters (256 bits). A token is looked up only if it looks like
;; one we minted, so anything else is refused before it reaches the store.
(test-case "a token is looked up only if it looks like one we minted: 43 base64url characters"
  (define key (token-format-key opaque-format))
  ;; mostly real-looking tokens or near-misses: a real one (3), one with a character swapped for a
  ;; forbidden one (2), the wrong length (1), a real one plus a trailing newline (1), arbitrary junk (1)
  (define gen:token-like
    (gen:frequency
     (list (cons 3 (gen:exactly-of b64-chars 43))
           (cons 2 (gen:bind (gen:exactly-of b64-chars 43)
                             (λ (s) (gen:map (gen:tuple (gen:integer-in 0 42) (gen:one-of (cons #\. outsiders)))
                                             (λ (t) (set-char s (car t) (cadr t)))))))
           (cons 1 (gen:map (gen:integer-in 0 60) (λ (n) (make-string n #\a))))
           (cons 1 (gen:map (gen:exactly-of b64-chars 43) (λ (s) (string-append s "\n"))))
           (cons 1 (gen:bad-string 50)))))
  ;; the format's key accepts exactly the 43-character base64url strings
  (check-property
   (prop-config 800)
   (property ([s gen:token-like])
     (equal? (and (key s) #t) (base64url-string? s 43))))
  ;; minted tokens are recognised by the format and do not repeat
  (check-property
   (prop-config 100)
   (property ([_ (gen:integer-in 0 1)])
     (define a ((token-format-mint opaque-format)))
     (define b ((token-format-mint opaque-format)))
     (and (equal? (key a) a) (equal? (key b) b) (not (equal? a b))))))

(test-case "PKCE (S256) accepts a verifier only with its own challenge"
  ;; the RFC 7636 appendix B example
  (check-true (s256-matches? "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"))
  (define gen:verifier (gen:bind (gen:integer-in 43 128) (λ (n) (gen:exactly-of unreserved n))))
  ;; a verifier matches the challenge computed independently (its shape is covered by the last test case)
  (check-property
   (prop-config 400)
   (property ([v gen:verifier])
     (s256-matches? v (pkce-ref v))))
  ;; changing one character of the challenge breaks the match, unless the character is unchanged
  (check-property
   (prop-config 400)
   (property ([v gen:verifier] [i (gen:integer-in 0 42)] [c (gen:one-of b64-chars)])
     (define good (pkce-ref v))
     (equal? (s256-matches? v (set-char good i c)) (char=? c (string-ref good i)))))
  ;; a challenge cut short or padded at the end does not match
  (check-property
   (prop-config 400)
   (property ([v gen:verifier] [k (gen:integer-in 1 5)])
     (define good (pkce-ref v))
     (not (or (s256-matches? v (substring good 0 (- 43 k)))
              (s256-matches? v (string-append good (make-string k #\A)))))))
  ;; a verifier with a character outside the allowed set is refused, even with its own challenge
  (check-property
   (prop-config 400)
   (property ([v gen:verifier] [i (gen:integer-in 0 42)] [c (gen:one-of outsiders)])
     (define bad (set-char v i c))
     (not (s256-matches? bad (pkce-ref bad)))))
  ;; a verifier shorter than 43 or longer than 128 characters is refused, even with its own challenge
  (check-property
   (prop-config 200)
   (property ([n (gen:one-of '(0 1 42 129 130 300))] [v (gen:exactly-of unreserved 130)])
     (define short-or-long (substring (string-append v v v) 0 n))
     (not (s256-matches? short-or-long (pkce-ref short-or-long))))))

;; a challenge is 43 base64url characters; the generator mixes valid ones (2), runs of "B" of length
;; 40..46, which are valid only at 43 (2), and arbitrary junk (1)
(test-case "a PKCE challenge is exactly 43 base64url characters"
  (check-property
   (prop-config 500)
   (property ([s (gen:frequency (list (cons 2 (gen:exactly-of b64-chars 43))
                                      (cons 2 (gen:map (gen:integer-in 40 46) (λ (n) (make-string n #\B))))
                                      (cons 1 (gen:bad-string 45))))])
     (equal? (s256-challenge? s) (base64url-string? s 43)))))
