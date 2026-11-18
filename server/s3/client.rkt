#lang racket/base
;; A small S3 client: put, get, head, delete and copy of single objects, signed with
;; AWS Signature V4. Works with AWS and S3-compatible servers (path-style addressing for
;; MinIO, Ceph, Contabo, R2...). Objects are uploaded from files and downloaded as ports,
;; so no object is held in memory. Keys are restricted to A-Z a-z 0-9 . _ - and "/".
;;
;; Failures raise exn:fail:s3 or one of its subtypes (see errors.rkt for the details):
;;   exn:fail:s3:response  the server answered with an unexpected status (status, code)
;;   exn:fail:s3:protocol  the reply is malformed, oversized or cut short
;;   exn:fail:s3:timeout   connecting or waiting for data took too long
;; An invalid bucket, endpoint or key is a programming error and raises exn:fail:contract.
(require racket/contract/base racket/string
         "errors.rkt" "http.rkt" "sigv4.rkt")
(provide (struct-out exn:fail:s3)
         (struct-out exn:fail:s3:response)
         (struct-out exn:fail:s3:protocol)
         (struct-out exn:fail:s3:timeout)
         (contract-out
          [struct s3-endpoint ([scheme (or/c 'https 'http)] [host string?] [port (integer-in 1 65535)]
                               [region string?] [path-style? boolean?]
                               [connect-timeout timeout?] [idle-timeout timeout?])]
          [struct s3-credentials ([access-key-id string?] [secret-access-key string?])]
          [struct s3-bucket ([endpoint s3-endpoint?] [credentials s3-credentials?] [name string?])]
          [struct object-info ([size exact-nonnegative-integer?] [etag (or/c string? #f)])]
          [default-connect-timeout timeout?]
          [default-idle-timeout timeout?]
          [s3-key? (-> any/c boolean?)]
          [put-object! (-> s3-bucket? s3-key? path? void?)]
          [get-object (-> s3-bucket? s3-key? (or/c input-port? #f))]
          [head-object (-> s3-bucket? s3-key? (or/c object-info? #f))]
          [delete-object! (-> s3-bucket? s3-key? void?)]
          [copy-object! (-> s3-bucket? s3-key? s3-key? void?)]))

;; An S3Endpoint is an (s3-endpoint Scheme String Port String Boolean Timeout Timeout):
;;   the server's scheme, DNS name or IPv4 address (not an IPv6 literal) and TCP port, the
;;   region used for signing, whether buckets are addressed in the path (host/bucket/key)
;;   rather than the host (bucket.host/key), and the seconds allowed for connecting and for
;;   the server to go quiet while sending.
;; An S3Credentials is an (s3-credentials String String): access key id and secret access key.
;; An S3Bucket is an (s3-bucket S3Endpoint S3Credentials String): a bucket and how to reach it.
;;   The name follows the S3 rules (3-63 lowercase letters, digits, hyphens and dots, starting
;;   and ending with a letter or digit); with virtual-hosted addressing it has no dots, which
;;   would break the TLS certificate match.
;; An ObjectInfo is an (object-info Natural (or String #f)): size in bytes and entity tag.
;; A Key is a "/"-separated String of non-empty segments of A-Z a-z 0-9 . _ -, none of them
;;   "." or "..", so it neither starts nor ends with "/" and has no "//".
(struct s3-endpoint (scheme host port region path-style? connect-timeout idle-timeout)
  #:guard (λ (scheme host port region path-style? connect-timeout idle-timeout name)
            (unless (regexp-match? #px"^[A-Za-z0-9.-]+$" host)
              (raise-arguments-error name "host must be a DNS name or IPv4 address" "host" host))
            (values scheme host port region path-style? connect-timeout idle-timeout)))
(struct s3-credentials (access-key-id secret-access-key))
(struct s3-bucket (endpoint credentials name)
  #:guard (λ (endpoint credentials bucket-name name)
            (unless (regexp-match? #px"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$" bucket-name)
              (raise-arguments-error name "invalid bucket name" "name" bucket-name))
            (when (and (not (s3-endpoint-path-style? endpoint)) (string-contains? bucket-name "."))
              (raise-arguments-error name "a dotted bucket name needs path-style addressing"
                                     "name" bucket-name))
            (values endpoint credentials bucket-name)))
(struct object-info (size etag))

(define service "s3")

;; Any -> Boolean
(define (s3-key? v)
  (and (string? v)
       (for/and ([segment (in-list (regexp-split #rx"/" v))])
         (and (regexp-match? #px"^[A-Za-z0-9._-]+$" segment)
              (not (member segment '("." "..")))))))

;; --- operations ---

;; S3Bucket Key Path -> Void
;; uploads the file's content (streamed; its SHA-256 is signed, so the file must not change meanwhile)
(define (put-object! b key file)
  (define payload (call-with-input-file file hex-sha256))
  (define r (request b "PUT" key '() '() payload file))
  (expect-status! r key '(200)))

;; S3Bucket Key -> (or InputPort #f)
;; the object's content as a port the caller closes, #f when there is no such object
(define (get-object b key)
  (define r (request b "GET" key '() '() empty-payload-hash))
  (if (= (response-status r) 200)
      (response-body r)
      (missing-or-raise! r key)))

;; S3Bucket Key -> (or ObjectInfo #f)
(define (head-object b key)
  (define r (request b "HEAD" key '() '() empty-payload-hash))
  (case (response-status r)
    [(200) (object-info (content-length r) (response-header r "etag"))]
    [(404) #f]
    [else (raise-s3-error! r key)]))

;; Response -> Natural
;; the Content-Length of a HEAD response
(define (content-length r)
  (define v (response-header r "content-length"))
  (unless (and v (regexp-match? #px"^[0-9]+$" v))
    (raise-protocol-error "HEAD response without a valid Content-Length: ~s" v))
  (string->number v))

;; S3Bucket Key -> Void
;; deleting a missing object is not an error: S3 answers 204 for it too
(define (delete-object! b key)
  (define r (request b "DELETE" key '() '() empty-payload-hash))
  (expect-status! r key '(200 204)))

;; S3Bucket Key Key -> Void
;; copies an object within the bucket (a server-side copy)
(define (copy-object! b from to)
  (define source (string-append "/" (s3-bucket-name b) "/" (uri-encode from #:keep-slash? #t)))
  (define r (request b "PUT" to '() (list (cons "x-amz-copy-source" source)) empty-payload-hash))
  (define body (response-body-bytes! r))
  ;; S3 may answer 200 and still report a failure in the body
  (when (or (not (= (response-status r) 200)) (regexp-match? #rx#"<Error>" body))
    (raise-s3-error! r to body)))

;; --- requests ---

(define empty-payload-hash (hex-sha256 #""))

;; S3Bucket String Key (Listof (cons String String)) Headers String [(or Path #f)] -> Response
;; sends a signed request for the object `key`; `payload-hash` is the SHA-256 of `body`
(define (request b method key query extra-headers payload-hash [body #f])
  (define e (s3-bucket-endpoint b))
  (define headers (signed-headers b method key query extra-headers payload-hash (current-seconds)))
  (http-request (eq? (s3-endpoint-scheme e) 'https) (authority-host b) (s3-endpoint-port e)
                method (request-target (object-path b key) query) headers body
                #:connect-timeout (s3-endpoint-connect-timeout e)
                #:idle-timeout (s3-endpoint-idle-timeout e)))

;; S3Bucket Key Query Headers String Natural -> Headers
;; the headers to send: `extra-headers`, Host, x-amz-date, x-amz-content-sha256 and Authorization
(define (signed-headers b method key query extra-headers payload-hash now)
  (define e (s3-bucket-endpoint b))
  (define c (s3-bucket-credentials b))
  (define timestamp (amz-timestamp now))
  (define headers (append extra-headers
                          (list (cons "Host" (host-header b))
                                (cons "x-amz-date" timestamp)
                                (cons "x-amz-content-sha256" payload-hash))))
  (define canonical (canonical-request method (object-path b key) query headers payload-hash))
  (define scope (credential-scope timestamp (s3-endpoint-region e) service))
  (define signature (request-signature (s3-credentials-secret-access-key c) timestamp
                                       (s3-endpoint-region e) service canonical))
  (cons (cons "Authorization"
              (authorization-header (s3-credentials-access-key-id c) scope
                                    (signed-header-names headers) signature))
        headers))

;; S3Bucket Key -> String
;; the (unencoded) URI path of the object
(define (object-path b key)
  (if (s3-endpoint-path-style? (s3-bucket-endpoint b))
      (string-append "/" (s3-bucket-name b) "/" key)
      (string-append "/" key)))

;; S3Bucket -> String
;; the host name to connect to, to verify the TLS certificate against, and to send as Host:
;; the bucket joins the endpoint's host unless path-style
(define (authority-host b)
  (define e (s3-bucket-endpoint b))
  (if (s3-endpoint-path-style? e)
      (s3-endpoint-host e)
      (string-append (s3-bucket-name b) "." (s3-endpoint-host e))))

;; S3Bucket -> String
;; the Host header value: the authority host, with the port when it is not the scheme's default
(define (host-header b)
  (define e (s3-bucket-endpoint b))
  (if (= (s3-endpoint-port e) (if (eq? (s3-endpoint-scheme e) 'https) 443 80))
      (authority-host b)
      (format "~a:~a" (authority-host b) (s3-endpoint-port e))))

;; String Query -> String
;; the encoded request target, "path?query"
(define (request-target path query)
  (define encoded (uri-encode path #:keep-slash? #t))
  (if (null? query)
      encoded
      (string-append encoded "?" (string-join (for/list ([q (in-list query)])
                                                (string-append (uri-encode (car q)) "=" (uri-encode (cdr q))))
                                              "&"))))

;; --- errors ---

;; Response Key (Listof Natural) -> Void
(define (expect-status! r key ok)
  (if (memv (response-status r) ok)
      (void (response-body-bytes! r))
      (raise-s3-error! r key)))

;; Response Key -> #f
;; #f when `r` says the object does not exist (404 NoSuchKey), otherwise raises
(define (missing-or-raise! r key)
  (define body (response-body-bytes! r 65536))
  (if (and (= (response-status r) 404) (equal? (error-code body) "NoSuchKey"))
      #f
      (raise-s3-error! r key body)))

;; Response Key [Bytes] -> Nothing
;; raises an exn:fail:s3:response for an unexpected response, reading its (small) error document
(define (raise-s3-error! r key [body (response-body-bytes! r 65536)])
  (define code (error-code body))
  (raise (exn:fail:s3:response (format "S3 request for ~a failed: HTTP ~a~a" key (response-status r)
                                       (if code (string-append " " code) ""))
                               (current-continuation-marks) (response-status r) code)))

;; Bytes -> (or String #f)
;; the <Code> of an S3 error document
(define (error-code body)
  (define m (regexp-match #rx#"<Code>([^<]*)</Code>" body))
  (and m (bytes->string/utf-8 (cadr m) #\?)))

(module+ test
  (require rackunit)
  ;; The S3 documentation's "GET Object" example (see sigv4.rkt for the source), reproduced
  ;; through the client's own header construction: virtual-hosted style, a Range header.
  (define (endpoint scheme host port path-style?)
    (s3-endpoint scheme host port "us-east-1" path-style? default-connect-timeout default-idle-timeout))
  (define example-bucket
    (s3-bucket (endpoint 'https "s3.amazonaws.com" 443 #f)
               (s3-credentials "AKIAIOSFODNN7EXAMPLE" "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
               "examplebucket"))
  (define local-bucket
    (s3-bucket (endpoint 'http "127.0.0.1" 7079 #t) (s3-credentials "k" "s") "bkt"))

  (test-case "signed-headers reproduces the S3 documentation's GET Object signature"
    (define headers (signed-headers example-bucket "GET" "test.txt" '() '(("Range" . "bytes=0-9"))
                                    empty-payload-hash 1369353600))
    (check-equal? (cdr (assoc "Authorization" headers))
                  (string-append "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
                                 "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"
                                 "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")))

  (test-case "addressing: virtual-hosted vs path-style, default vs explicit port"
    (check-equal? (host-header example-bucket) "examplebucket.s3.amazonaws.com")
    (check-equal? (object-path example-bucket "a/b") "/a/b")
    (check-equal? (host-header local-bucket) "127.0.0.1:7079")
    (check-equal? (object-path local-bucket "a/b") "/bkt/a/b"))

  (test-case "virtual-hosted requests connect to the host the Host header names"
    (check-equal? (authority-host example-bucket) "examplebucket.s3.amazonaws.com")
    (check-equal? (authority-host local-bucket) "127.0.0.1")
    (define via-port (s3-bucket (endpoint 'http "localhost" 9000 #f) (s3-credentials "k" "s") "bkt"))
    (check-equal? (host-header via-port) "bkt.localhost:9000"))

  (test-case "bucket names are validated; dots need path-style"
    (define (bucket name path-style?)
      (s3-bucket (endpoint 'https "h.example" 443 path-style?) (s3-credentials "k" "s") name))
    (for ([ok '("abc" "my-bucket" "a1.b2")]) (check-not-exn (λ () (bucket ok #t))))
    (for ([bad '("ab" "UPPER" "-abc" "abc-" "a_b" "a/b" "" "a b")])
      (check-exn exn:fail:contract? (λ () (bucket bad #t)) bad))
    (check-not-exn (λ () (bucket "my-bucket" #f)))
    (check-exn #rx"path-style" (λ () (bucket "a1.b2" #f))))

  (test-case "endpoint hosts are names or IPv4 addresses"
    (check-not-exn (λ () (endpoint 'https "s3.eu-west-1.amazonaws.com" 443 #f)))
    (for ([bad '("::1" "[::1]" "h/x" "u@h" "")])
      (check-exn exn:fail:contract? (λ () (endpoint 'https bad 443 #f)) bad)))

  (test-case "request-target encodes the path and the query"
    (check-equal? (request-target "/bkt/a b" '()) "/bkt/a%20b")
    (check-equal? (request-target "/" '(("x" . "a&b"))) "/?x=a%26b"))

  (test-case "s3-key?"
    (for ([ok '("1-abcdefghij.pdf" "a/b.c" ".hidden" "A_b-c" "a..b" "a/.b/c.")])
      (check-true (s3-key? ok) ok))
    (for ([bad '("" "/" "/abs" "a/" "a//b" "a/./b" "." "./a" "a/../b" ".." "a/.." "a b" "a?b" "é" "a%2e" 5)])
      (check-false (s3-key? bad) (format "~s" bad))))

  (test-case "error documents"
    (check-equal? (error-code #"<?xml version=\"1.0\"?><Error><Code>NoSuchBucket</Code><Message>x</Message></Error>")
                  "NoSuchBucket")
    (check-false (error-code #""))
    (check-false (error-code #"<html>bad gateway</html>")))

  ;; Integer String Bytes -> Response
  (define (canned status headers body)
    (response status headers (open-input-bytes body)))
  (define (no-such code)
    (string->bytes/utf-8 (format "<Error><Code>~a</Code></Error>" code)))

  (test-case "only a NoSuchKey 404 means a missing object"
    (check-false (missing-or-raise! (canned 404 '() (no-such "NoSuchKey")) "k"))
    (for ([body (list (no-such "NoSuchBucket") #"" #"<html>not found</html>")])
      (check-exn (λ (e) (and (exn:fail:s3:response? e) (= (exn:fail:s3:response-status e) 404)))
                 (λ () (missing-or-raise! (canned 404 '() body) "k"))))
    (check-exn exn:fail:s3:response? (λ () (missing-or-raise! (canned 403 '() (no-such "NoSuchKey")) "k"))))

  (test-case "HEAD parsing is defensive about Content-Length"
    (check-equal? (content-length (canned 200 '(("content-length" . "14")) #"")) 14)
    (for ([bad '(() (("content-length" . "x")) (("content-length" . "-1")))])
      (check-exn exn:fail:s3:protocol? (λ () (content-length (canned 200 bad #"")))))))
