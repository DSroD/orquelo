#lang racket/base
;; How bearer tokens are minted and found again. The server only ever stores `hash-token` of the
;; lookup key, so a leaked table gives nothing usable. Opaque tokens are the only format today;
;; a signed (JWT) format would mint a self-contained string and key on its id, while the server
;; still checks the grant's liveness itself.
(require racket/contract/base "base64url.rkt")
(provide (contract-out
          [struct token-format ([mint (-> string?)] [key (-> string? (or/c string? #f))])]
          [opaque-format token-format?]
          [hash-token (-> string? bytes?)]))

;; A TokenFormat is a (token-format (-> String) (String -> (or String #f)))
;; `mint` makes a fresh token; `key` is the string a presented token is looked up by (#f when the
;; token is malformed and so cannot be genuine)
(struct token-format (mint key))

;; 32 random bytes as 43 base64url characters; the token is its own lookup key
(define opaque-format
  (token-format (λ () (random-base64url 32))
                (λ (s) (and (regexp-match? #px"^[A-Za-z0-9_-]{43}$" s) s))))

;; String -> Bytes
;; the SHA-256 digest under which a token's lookup key is stored
(define (hash-token key) (sha256-bytes (string->bytes/utf-8 key)))

(module+ test
  (require rackunit)
  (define t ((token-format-mint opaque-format)))
  (check-equal? (string-length t) 43)
  (check-equal? ((token-format-key opaque-format) t) t)
  (check-false ((token-format-key opaque-format) "short"))
  (check-false ((token-format-key opaque-format) (string-append (substring t 1) "+")))
  (check-not-equal? t ((token-format-mint opaque-format)))
  (check-equal? (bytes-length (hash-token t)) 32))
