#lang racket/base
;; Password hashing: scrypt through libcrypto's EVP_PBE_scrypt.
;; Stored form: $scrypt$ln=15,r=8,p=1$<b64 salt>$<b64 key>, base64 without padding.
;; The derivation runs on an OS thread so the other green threads keep serving (~60 ms each), with at
;; most `max-concurrent` of them (each needs about 256·r·2^ln bytes = 64 MiB) at a time.
(require (except-in racket/contract/base ->) (prefix-in c: (only-in racket/contract/base ->))
         racket/match racket/string racket/list racket/random net/base64
         ffi/unsafe ffi/unsafe/define ffi/unsafe/os-thread ffi/unsafe/os-async-channel openssl/libcrypto)
(provide (contract-out
          [hash-password (c:-> string? string?)]
          [check-password (c:-> string? (or/c string? #f) (or/c 'ok 'rehash #f))]
          [valid-new-password? (c:-> string? boolean?)]))

;; (ffi/unsafe also exports `->`, for _fun; contracts use the c: prefix)
(define cur-ln 15)
(define cur-r 8)
(define cur-p 1)
(define salt-length 16)
(define key-length 32)
(define max-ln 20) ; bounds on parsed parameters: a corrupt row must not cost gigabytes
(define max-r 16)
(define max-p 4)
(define max-concurrent 4)
(define min-password-bytes 10)
(define max-password-bytes 1024)

;; A ScryptHash is a (scrypt-hash Natural Natural Natural Bytes Bytes)
;; interpretation: cost exponent ln (N = 2^ln), block size r, parallelism p, salt, derived key
(struct scrypt-hash (ln r p salt key))

;; ------------------------------------------------------------------ libcrypto
(define-ffi-definer define-crypto libcrypto #:default-make-fail make-not-available)
(define-crypto EVP_PBE_scrypt
  (_fun #:blocking? #t _pointer _size _pointer _size _uint64 _uint64 _uint64 _uint64 _pointer _size -> _int))
(define-crypto CRYPTO_memcmp (_fun _bytes _bytes _size -> _int))

;; Bytes -> Pointer
;; a raw (non-GC) copy of `bs`, readable from an OS thread
(define (raw-copy bs)
  (define p (malloc (max 1 (bytes-length bs)) 'raw))
  (memcpy p bs (bytes-length bs))
  p)

;; Bytes Bytes Natural Natural Natural Natural -> Bytes
;; derives `len` bytes from password and salt; raises when libcrypto refuses the parameters
(define (scrypt pw salt ln r p len)
  (if (os-thread-enabled?)
      (call-limited (λ () (scrypt/os-thread pw salt ln r p len)))
      (scrypt/direct pw salt ln r p len)))

;; Natural Natural Natural -> Natural
;; memory libcrypto may use (OpenSSL needs 128·N·r plus slack, and the default limit is 32 MiB)
(define (maxmem ln r p) (* 256 r (+ p (expt 2 ln))))

;; Bytes Bytes Natural Natural Natural Natural -> Bytes
;; synchronous fallback: blocks every green thread for the duration
(define (scrypt/direct pw salt ln r p len)
  (define out (make-bytes len))
  (define rc (EVP_PBE_scrypt pw (bytes-length pw) salt (bytes-length salt)
                             (expt 2 ln) r p (maxmem ln r p) out len))
  (unless (= rc 1) (error 'scrypt "libcrypto call failed"))
  out)

;; Bytes Bytes Natural Natural Natural Natural -> Bytes
;; same, on a separate OS thread; the inputs and output live in raw memory, freed afterwards
(define (scrypt/os-thread pw salt ln r p len)
  (define ps (map raw-copy (list pw salt)))
  (define out (malloc len 'raw))
  (define done (make-os-async-channel))
  (dynamic-wind
   void
   (λ ()
     (define pw* (first ps))
     (define salt* (second ps))
     (define n (expt 2 ln))
     (define mem (maxmem ln r p))
     (define pwl (bytes-length pw))
     (define sl (bytes-length salt))
     (unless (call-in-os-thread
              (λ () (os-async-channel-put done (EVP_PBE_scrypt pw* pwl salt* sl n r p mem out len))))
       (error 'scrypt "cannot start an OS thread"))
     (define rc (sync done))
     (unless (= rc 1) (error 'scrypt "libcrypto call failed"))
     (define result (make-bytes len))
     (memcpy result out len)
     result)
   (λ () (for-each free ps) (free out))))

(define permits (make-semaphore max-concurrent))

;; (-> X) -> X
;; runs `thunk` holding one of the `max-concurrent` permits
(define (call-limited thunk)
  (call-with-semaphore permits thunk))

;; ------------------------------------------------------------------ encoding
;; Bytes -> String
(define (b64 bs) (bytes->string/latin-1 (base64-encode bs #"")) )

;; ScryptHash -> String
(define (encode-hash h)
  (match-define (scrypt-hash ln r p salt key) h)
  (define (unpadded bs) (string-trim (b64 bs) "=" #:left? #f #:repeat? #t))
  (format "$scrypt$ln=~a,r=~a,p=~a$~a$~a" ln r p (unpadded salt) (unpadded key)))

;; String -> (or ScryptHash #f)
;; #f when the string is malformed or a parameter is out of bounds
(define (parse-hash s)
  (match (regexp-match #px"^\\$scrypt\\$ln=(\\d{1,2}),r=(\\d{1,2}),p=(\\d{1,2})\\$([A-Za-z0-9+/]+)\\$([A-Za-z0-9+/]+)$" s)
    [(list _ ln r p salt key)
     (define-values (ln* r* p*) (apply values (map string->number (list ln r p))))
     (and (<= 1 ln* max-ln) (<= 1 r* max-r) (<= 1 p* max-p)
          (let ([salt* (unb64 salt)] [key* (unb64 key)])
            (and salt* key* (>= (bytes-length salt*) 8) (= (bytes-length key*) key-length)
                 (scrypt-hash ln* r* p* salt* key*))))]
    [_ #f]))

;; String -> (or Bytes #f)
;; decodes unpadded base64; #f when no whole bytes result
(define (unb64 s)
  (and (not (= 1 (remainder (string-length s) 4)))
       (base64-decode (string->bytes/latin-1 s))))

;; ------------------------------------------------------------------ interface
;; String -> String
;; the stored form of `password` under the current parameters and a fresh salt
(define (hash-password password)
  (define salt (crypto-random-bytes salt-length))
  (encode-hash (scrypt-hash cur-ln cur-r cur-p salt
                            (scrypt (string->bytes/utf-8 password) salt cur-ln cur-r cur-p key-length))))

;; A syntactically valid hash of an unguessable password, checked for unknown accounts so that
;; they cost the same as known ones
(define dummy-hash
  "$scrypt$ln=15,r=8,p=1$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

;; ScryptHash -> Boolean
(define (current-params? h)
  (and (= (scrypt-hash-ln h) cur-ln) (= (scrypt-hash-r h) cur-r) (= (scrypt-hash-p h) cur-p)
       (= (bytes-length (scrypt-hash-salt h)) salt-length)))

;; String (or String #f) -> (or 'ok 'rehash #f)
;; #f for a wrong password, and for no or a malformed stored hash (after a dummy check, same cost);
;; 'rehash when it matches but was made under other parameters
(define (check-password password stored)
  (define h (and stored (parse-hash stored)))
  (define target (or h (parse-hash dummy-hash)))
  (define derived (scrypt (string->bytes/utf-8 password) (scrypt-hash-salt target)
                          (scrypt-hash-ln target) (scrypt-hash-r target) (scrypt-hash-p target)
                          (bytes-length (scrypt-hash-key target))))
  (define same? (= 0 (CRYPTO_memcmp derived (scrypt-hash-key target) (bytes-length derived))))
  (cond [(not (and h same?)) #f]
        [(current-params? h) 'ok]
        [else 'rehash]))

;; String -> Boolean
;; a new password is 10 to 1024 UTF-8 bytes
(define (valid-new-password? s)
  (<= min-password-bytes (bytes-length (string->bytes/utf-8 s)) max-password-bytes))

(module+ test
  (require rackunit file/sha1)
  (define h hex-string->bytes)

  (test-case "RFC 7914 scrypt vectors"
    (check-equal? (scrypt #"" #"" 4 1 1 64)
                  (h "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906"))
    (check-equal? (scrypt #"password" #"NaCl" 10 8 16 64)
                  (h "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"))
    (check-equal? (scrypt #"pleaseletmein" #"SodiumChloride" 14 8 1 64)
                  (h "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887")))
  (test-case "the synchronous fallback agrees"
    (check-equal? (scrypt/direct #"password" #"NaCl" 10 8 16 64) (scrypt #"password" #"NaCl" 10 8 16 64)))
  (test-case "libcrypto refusing the parameters raises"
    (check-exn exn:fail? (λ () (scrypt #"x" #"y" 4 0 1 32))))

  (define stored (hash-password "correct horse"))
  (test-case "format and round trip"
    (check-regexp-match #px"^\\$scrypt\\$ln=15,r=8,p=1\\$[A-Za-z0-9+/]{22}\\$[A-Za-z0-9+/]{43}$" stored)
    (check-equal? (check-password "correct horse" stored) 'ok)
    (check-not-equal? stored (hash-password "correct horse")))
  (test-case "wrong password"
    (check-false (check-password "correct horsf" stored))
    (check-false (check-password "" stored)))
  (test-case "multibyte password"
    (check-equal? (check-password "pässwörd-日本語" (hash-password "pässwörd-日本語")) 'ok))
  (test-case "no or malformed stored hash gives #f, never raises"
    (for ([bad (list #f "" "garbage" "$scrypt$" "$scrypt$ln=15,r=8,p=1$AAAA$AAAA"
                     "$scrypt$ln=99,r=8,p=1$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                     "$scrypt$ln=15,r=8,p=9$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                     "$scrypt$ln=0,r=8,p=1$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                     "$scrypt$ln=15,r=8,p=1$A$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                     "$scrypt$ln=15,r=8,p=1$AAAAAAAAAAAAAAAAAAAAAA$!!!"
                     (string-append stored "x"))])
      (check-false (check-password "correct horse" bad) (format "~s" bad))))
  (test-case "dummy-hash parses with the current parameters"
    (define d (parse-hash dummy-hash))
    (check-true (and d (current-params? d))))
  (test-case "different parameters give 'rehash"
    (define salt (crypto-random-bytes salt-length))
    (define old (encode-hash (scrypt-hash 14 8 1 salt (scrypt #"pw" salt 14 8 1 key-length))))
    (check-equal? (check-password "pw" old) 'rehash)
    (check-false (check-password "px" old)))
  (test-case "valid-new-password? bounds"
    (check-false (valid-new-password? "123456789"))
    (check-true (valid-new-password? "1234567890"))
    (check-true (valid-new-password? (make-string 1024 #\a)))
    (check-false (valid-new-password? (make-string 1025 #\a)))
    (check-false (valid-new-password? "éééé"))   ; 4 chars, 8 bytes
    (check-true (valid-new-password? "ééééé"))
    (void))
  (test-case "hashing leaves other green threads running"
    (define ticks 0)
    (define t (thread (λ () (let loop () (sleep 0.001) (set! ticks (add1 ticks)) (loop)))))
    (define t0 (current-inexact-milliseconds))
    (hash-password "timing")
    (define ms (- (current-inexact-milliseconds) t0))
    (kill-thread t)
    (eprintf "ln=15 hash: ~a ms, ~a ticks of a 1 ms thread\n" (round ms) ticks)
    (check-true (> ticks 5)))
  (test-case "concurrent logins are all served"
    (define results (make-channel))
    (for ([_ 6]) (thread (λ () (channel-put results (check-password "correct horse" stored)))))
    (for ([_ 6]) (check-equal? (channel-get results) 'ok))))
