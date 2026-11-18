#lang racket/base
;; AWS Signature Version 4 request signing, as pure functions (no IO, no clock).
;; https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv4-create-signed-request.html
(require racket/contract/base racket/format racket/string file/sha1)
(provide (contract-out
          [hex-sha256 (-> (or/c bytes? input-port?) string?)]
          [uri-encode (->* (string?) (#:keep-slash? boolean?) string?)]
          [amz-timestamp (-> exact-integer? string?)]
          [canonical-request (-> string? string? (listof (cons/c string? string?))
                                 (listof (cons/c string? string?)) string? string?)]
          [signed-header-names (-> (listof (cons/c string? string?)) string?)]
          [credential-scope (-> string? string? string? string?)]
          [request-signature (-> string? string? string? string? string? string?)]
          [authorization-header (-> string? string? string? string? string?)]))

;; A Headers is a (listof (cons String String)) of (name . value); names are matched
;; case-insensitively and signed in lowercase, values are trimmed with inner runs of white
;; space collapsed, and repeated names are merged into one comma-separated value.
;; A Timestamp is a String "YYYYMMDDTHHMMSSZ" (UTC); its first 8 characters are the Date.

;; (or Bytes InputPort) -> String
;; lowercase hex SHA-256; a port is read to EOF
(define (hex-sha256 data)
  (bytes->hex-string (sha256-bytes data)))

;; Bytes Bytes -> Bytes
;; HMAC-SHA256 (RFC 2104, 64-byte block)
(define (hmac-sha256 key message)
  (define block 64)
  (define k (let ([k (if (> (bytes-length key) block) (sha256-bytes key) key)])
              (bytes-append k (make-bytes (- block (bytes-length k)) 0))))
  (define (pad byte) (apply bytes (for/list ([b (in-bytes k)]) (bitwise-xor b byte))))
  (sha256-bytes (bytes-append (pad #x5c) (sha256-bytes (bytes-append (pad #x36) message)))))

;; String [#:keep-slash? Boolean] -> String
;; percent-encodes every byte of the UTF-8 form except A-Z a-z 0-9 - _ . ~ (uppercase hex);
;; "/" is also kept with #:keep-slash? (for paths)
(define (uri-encode s #:keep-slash? [keep-slash? #f])
  (string-append*
   (for/list ([b (in-bytes (string->bytes/utf-8 s))])
     (define c (integer->char b))
     (if (or (unreserved? c) (and keep-slash? (char=? c #\/)))
         (string c)
         (string-append "%" (~r b #:base '(up 16) #:min-width 2 #:pad-string "0"))))))

;; Char -> Boolean
(define (unreserved? c)
  (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (and (memv c '(#\- #\_ #\. #\~)) #t)))

;; Integer -> Timestamp
;; the UTC timestamp of Unix time `secs`
(define (amz-timestamp secs)
  (define d (seconds->date secs #f))
  (define (two n) (~r n #:min-width 2 #:pad-string "0"))
  (string-append (number->string (date-year d)) (two (date-month d)) (two (date-day d))
                 "T" (two (date-hour d)) (two (date-minute d)) (two (date-second d)) "Z"))

;; Headers -> Headers
;; lowercase names, trimmed values with inner white space runs collapsed, repeated names
;; merged with commas (in order of appearance), sorted by name
(define (normalize-headers headers)
  (define merged
    (for/fold ([acc (hash)]) ([h (in-list headers)])
      (hash-update acc (string-downcase (string-trim (car h)))
                   (λ (vs) (append vs (list (string-normalize-spaces (cdr h)))))
                   '())))
  (sort (for/list ([(name vs) (in-hash merged)]) (cons name (string-join vs ",")))
        string<? #:key car))

;; Headers -> String
;; the semicolon-separated, sorted, lowercase header names
(define (signed-header-names headers)
  (string-join (map car (normalize-headers headers)) ";"))

;; Headers -> String
(define (canonical-headers headers)
  (string-append* (for/list ([h (in-list (normalize-headers headers))])
                    (string-append (car h) ":" (cdr h) "\n"))))

;; (Listof (cons String String)) -> String
;; query parameters, encoded and sorted by encoded name, then by encoded value, joined as
;; name=value&... (sorting the joined strings would put "a-b=" before "a=")
(define (canonical-query params)
  (define encoded (for/list ([p (in-list params)]) (cons (uri-encode (car p)) (uri-encode (cdr p)))))
  (define (pair<? x y)
    (or (string<? (car x) (car y))
        (and (string=? (car x) (car y)) (string<? (cdr x) (cdr y)))))
  (string-join (for/list ([p (in-list (sort encoded pair<?))]) (string-append (car p) "=" (cdr p))) "&"))

;; String String Headers Headers String -> String
;; method, path (already a valid URI path, encoded once as S3 expects), query parameters
;; (decoded), headers to sign, hex SHA-256 of the payload
(define (canonical-request method path query headers payload-hash)
  (string-join (list method (uri-encode path #:keep-slash? #t) (canonical-query query)
                     (canonical-headers headers)
                     (signed-header-names headers) payload-hash)
               "\n"))

;; Timestamp String String -> String
;; the credential scope "<date>/<region>/<service>/aws4_request"
(define (credential-scope timestamp region service)
  (string-join (list (substring timestamp 0 8) region service "aws4_request") "/"))

;; Timestamp String String -> String
;; the string to sign for a canonical request, given the credential scope
(define (string-to-sign timestamp scope canonical)
  (string-join (list "AWS4-HMAC-SHA256" timestamp scope (hex-sha256 (string->bytes/utf-8 canonical)))
               "\n"))

;; String String String String -> Bytes
;; the derived signing key: secret access key, date (YYYYMMDD), region, service
(define (signing-key secret date region service)
  (for/fold ([k (string->bytes/utf-8 (string-append "AWS4" secret))])
            ([part (in-list (list date region service "aws4_request"))])
    (hmac-sha256 k (string->bytes/utf-8 part))))

;; String Timestamp String String String -> String
;; the lowercase hex signature of a canonical request: secret access key, timestamp, region, service
(define (request-signature secret timestamp region service canonical)
  (define scope (credential-scope timestamp region service))
  (define key (signing-key secret (substring timestamp 0 8) region service))
  (bytes->hex-string (hmac-sha256 key (string->bytes/utf-8 (string-to-sign timestamp scope canonical)))))

;; String String String String -> String
;; the Authorization header value: access key id, credential scope, signed header names, signature
(define (authorization-header access-key scope names signature)
  (string-append "AWS4-HMAC-SHA256 Credential=" access-key "/" scope
                 ",SignedHeaders=" names ",Signature=" signature))

(module+ test
  (require rackunit)
  ;; Vectors:
  ;;  [suite] the AWS Signature V4 test suite,
  ;;          https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html
  ;;          (credentials AKIDEXAMPLE / wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY, region us-east-1,
  ;;          service "service", timestamp 20150830T123600Z)
  ;;  [s3]    the examples in "Signature Calculations for the Authorization Header", Amazon S3 API
  ;;          Reference, https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
  ;;          (credentials AKIAIOSFODNN7EXAMPLE / wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY,
  ;;          region us-east-1, service s3, timestamp 20130524T000000Z)
  (define empty-hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  (define suite-secret "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
  (define suite-time "20150830T123600Z")
  (define s3-secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
  (define s3-time "20130524T000000Z")

  (test-case "hex-sha256 and hmac-sha256 (RFC 4231 test case 2)"
    (check-equal? (hex-sha256 #"") empty-hash)
    (check-equal? (hex-sha256 (open-input-bytes #"")) empty-hash)
    (check-equal? (bytes->hex-string (hmac-sha256 #"Jefe" #"what do ya want for nothing?"))
                  "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    ;; RFC 4231 test case 6: a key longer than the block size is hashed first
    (check-equal? (bytes->hex-string (hmac-sha256 (make-bytes 131 #xaa)
                                           #"Test Using Larger Than Block-Size Key - Hash Key First"))
                  "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"))

  (test-case "uri-encode"
    (check-equal? (uri-encode "AZaz09-_.~") "AZaz09-_.~")
    (check-equal? (uri-encode "a b$c/d") "a%20b%24c%2Fd")
    (check-equal? (uri-encode "a b$c/d" #:keep-slash? #t) "a%20b%24c/d")
    (check-equal? (uri-encode "é") "%C3%A9"))

  (test-case "amz-timestamp"
    (check-equal? (amz-timestamp 0) "19700101T000000Z")
    (check-equal? (amz-timestamp 1369353600) s3-time)
    (check-equal? (amz-timestamp 1440938160) suite-time))

  (test-case "[suite] get-vanilla"
    (define creq (canonical-request "GET" "/" '()
                                    '(("Host" . "example.amazonaws.com") ("X-Amz-Date" . "20150830T123600Z"))
                                    empty-hash))
    (check-equal? creq (string-append "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\n"
                                      "host;x-amz-date\n" empty-hash))
    (define scope (credential-scope suite-time "us-east-1" "service"))
    (check-equal? scope "20150830/us-east-1/service/aws4_request")
    (check-equal? (string-to-sign suite-time scope creq)
                  (string-append "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n"
                                 "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63"))
    (define signature (request-signature suite-secret suite-time "us-east-1" "service" creq))
    (check-equal? signature "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    (check-equal? (authorization-header "AKIDEXAMPLE" scope "host;x-amz-date" signature)
                  (string-append "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request,"
                                 "SignedHeaders=host;x-amz-date,"
                                 "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")))

  (test-case "[suite] get-vanilla-query-order-key-case"
    (define creq (canonical-request "GET" "/" '(("Param2" . "value2") ("Param1" . "value1"))
                                    '(("Host" . "example.amazonaws.com") ("X-Amz-Date" . "20150830T123600Z"))
                                    empty-hash))
    (check-regexp-match #rx"^GET\n/\nParam1=value1&Param2=value2\n" creq)
    (check-equal? (request-signature suite-secret suite-time "us-east-1" "service" creq)
                  "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"))

  (test-case "[suite] post-x-www-form-urlencoded"
    (define payload (hex-sha256 #"Param1=value1"))
    (check-equal? payload "9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e")
    (define creq (canonical-request "POST" "/" '()
                                    '(("Content-Type" . "application/x-www-form-urlencoded")
                                      ("Host" . "example.amazonaws.com") ("X-Amz-Date" . "20150830T123600Z"))
                                    payload))
    (check-equal? (request-signature suite-secret suite-time "us-east-1" "service" creq)
                  "ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a"))

  (test-case "[s3] GET Object with a Range header"
    (define creq (canonical-request "GET" "/test.txt" '()
                                    '(("Host" . "examplebucket.s3.amazonaws.com") ("Range" . "bytes=0-9")
                                      ("x-amz-content-sha256" . "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
                                      ("x-amz-date" . "20130524T000000Z"))
                                    empty-hash))
    (check-equal? (request-signature s3-secret s3-time "us-east-1" "s3" creq)
                  "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))

  (test-case "[s3] PUT Object: an encoded key and several signed headers"
    (define payload (hex-sha256 #"Welcome to Amazon S3."))
    (check-equal? payload "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
    (define headers `(("Date" . "Fri, 24 May 2013 00:00:00 GMT") ("Host" . "examplebucket.s3.amazonaws.com")
                      ("x-amz-date" . ,s3-time) ("x-amz-storage-class" . "REDUCED_REDUNDANCY")
                      ("x-amz-content-sha256" . ,payload)))
    (check-equal? (signed-header-names headers) "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class")
    (define creq (canonical-request "PUT" "/test$file.text" '() headers payload))
    (check-regexp-match #rx"^PUT\n/test%24file.text\n\n" creq)
    (check-equal? (request-signature s3-secret s3-time "us-east-1" "s3" creq)
                  "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"))

  (test-case "[s3] GET Bucket Lifecycle: a valueless query parameter"
    (define creq (canonical-request "GET" "/" '(("lifecycle" . ""))
                                    `(("Host" . "examplebucket.s3.amazonaws.com")
                                      ("x-amz-content-sha256" . ,empty-hash) ("x-amz-date" . ,s3-time))
                                    empty-hash))
    (check-equal? (request-signature s3-secret s3-time "us-east-1" "s3" creq)
                  "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"))

  (test-case "canonical-query sorts by encoded name, then by encoded value"
    (check-equal? (canonical-query '(("a-b" . "1") ("a" . "2"))) "a=2&a-b=1")
    (check-equal? (canonical-query '(("a" . "2") ("a" . "1") ("A" . "x"))) "A=x&a=1&a=2")
    (check-equal? (canonical-query '(("é" . "1") ("z" . "1"))) "%C3%A9=1&z=1"))

  (test-case "normalize-headers trims, collapses spaces and merges repeated names"
    (check-equal? (normalize-headers '(("X-B" . "  a   b ") ("x-a" . "1") ("X-b" . "c")))
                  '(("x-a" . "1") ("x-b" . "a b,c")))
    (check-equal? (signed-header-names '(("B" . "1") ("b" . "2") ("A" . "3"))) "a;b")))
