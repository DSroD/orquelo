#lang racket/base
;; A minimal HTTP/1.1 exchange: one request per connection ("Connection: close"), a body sent with
;; an explicit Content-Length (net/http-client can only send chunked bodies from a port, which
;; S3 rejects), and a streamed response body. TLS uses the system trust store and verifies the
;; server's certificate and host name, which is also the name sent for SNI.
;;
;; Failures are exn:fail:s3 (see errors.rkt): a connect that takes longer than the connect timeout
;; or a read that stalls longer than the idle timeout raises exn:fail:s3:timeout; a reply that
;; is malformed, too large or cut short raises exn:fail:s3:protocol.
(require racket/contract/base racket/list racket/port racket/tcp openssl "errors.rkt")
(provide (contract-out
          [struct response ([status exact-integer?]
                            [headers (listof (cons/c string? string?))]
                            [body input-port?])]
          [http-request (->* (boolean? string? (integer-in 1 65535) string? string?
                                       (listof (cons/c string? string?)))
                             ((or/c #f bytes? path?)
                              #:connect-timeout timeout? #:idle-timeout timeout?)
                             response?)]
          [response-header (-> response? string? (or/c string? #f))]
          [response-body-bytes! (->* (response?) (exact-nonnegative-integer?) bytes?)]
          [timeout? (-> any/c boolean?)]
          [default-connect-timeout timeout?]
          [default-idle-timeout timeout?]))

;; A Response is a (response Status Headers InputPort), where
;;   Status  is the HTTP status code,
;;   Headers is a (listof (cons String String)) of lowercase name and value,
;;   the body port reads exactly the response body; closing it closes the connection.
(struct response (status headers body))

;; A Timeout is a positive Real: seconds.
(define (timeout? v) (and (real? v) (positive? v)))
(define default-connect-timeout 10)
(define default-idle-timeout 30)

(define max-line-bytes 8192)
(define max-header-count 100)

;; Boolean String Port String String Headers [(or Bytes Path #f)] [#:connect-timeout Timeout]
;;   [#:idle-timeout Timeout] -> Response
;; sends one request to host:port (over TLS when `tls?`) and reads the status line and headers.
;; `target` is the request target, already percent-encoded; `headers` must include Host.
;; Content-Length is set from `body`, which is not read into memory when it is a path.
;; The connection lives on in the response body; it is closed when the body port is closed.
(define (http-request tls? host port method target headers [body #f]
                      #:connect-timeout [connect-timeout default-connect-timeout]
                      #:idle-timeout [idle-timeout default-idle-timeout])
  (define cust (make-custodian))
  (define handed-over? #f)
  (dynamic-wind
   void
   (λ ()
     (define-values (in out) (connect tls? host port connect-timeout cust))
     (write-head out method target (append headers (framing-headers body)))
     (write-body out body)
     (begin0 (read-response (idle-timeout-port in idle-timeout) method cust)
             (set! handed-over? #t)))
   (λ () (unless handed-over? (custodian-shutdown-all cust)))))

;; Boolean String Port Timeout Custodian -> (values InputPort OutputPort)
;; connects within `timeout` seconds; the ports belong to `cust`
(define (connect tls? host port timeout cust)
  (define result (make-channel))
  (parameterize ([current-custodian cust])
    (thread (λ ()
              (channel-put result
                           (with-handlers ([exn:fail? values])
                             (call-with-values (λ () (if tls?
                                                         (ssl-connect host port (ssl-secure-client-context))
                                                         (tcp-connect host port)))
                                               list))))))
  (define r (sync/timeout timeout result))
  (cond [(not r) (raise-timeout-error "connecting to ~a:~a timed out after ~as" host port timeout)]
        [(exn? r) (raise r)]
        [else (apply values r)]))

;; InputPort Timeout -> InputPort
;; `in`, except that a read waiting longer than `timeout` seconds for data raises a timeout
(define (idle-timeout-port in timeout)
  (define (read-in buf)
    (or (sync/timeout timeout (read-bytes-avail!-evt buf in))
        (raise-timeout-error "no data from the server for ~as" timeout)))
  (make-input-port 'http-response read-in #f void))

;; Bytes/Path/#f -> Headers
(define (framing-headers body)
  (list (cons "Connection" "close")
        (cons "Content-Length" (number->string (body-length body)))))

;; (or Bytes Path #f) -> Natural
(define (body-length body)
  (cond [(not body) 0]
        [(bytes? body) (bytes-length body)]
        [else (file-size body)]))

;; OutputPort String String Headers -> Void
(define (write-head out method target headers)
  (fprintf out "~a ~a HTTP/1.1\r\n" method target)
  (for ([h (in-list headers)])
    (check-header-field h)
    (fprintf out "~a: ~a\r\n" (car h) (cdr h)))
  (write-bytes #"\r\n" out))

;; (cons String String) -> Void
;; refuses a header that could smuggle a line break into the request
(define (check-header-field h)
  (when (regexp-match? #rx"[\r\n]" (string-append (car h) (cdr h)))
    (error 'http-request "line break in header ~s" (car h))))

;; OutputPort (or Bytes Path #f) -> Void
(define (write-body out body)
  (cond [(bytes? body) (write-bytes body out)]
        [(path? body) (call-with-input-file body (λ (in) (copy-port in out)))])
  (flush-output out))

;; InputPort String Custodian -> Response
(define (read-response in method cust)
  (define status (read-status in))
  (define headers (read-headers in))
  (response status headers (body-port in method status headers cust)))

;; InputPort -> String
;; the next line without its terminator (LF or CRLF); at most `max-line-bytes` long
(define (read-head-line in)
  (define out (open-output-bytes))
  (let loop ([n 0])
    (define b (read-byte in))
    (cond [(eof-object? b) (raise-protocol-error "the response ended inside its head")]
          [(= b 10) (void)]
          [(= n max-line-bytes) (raise-protocol-error "response head line longer than ~a bytes" max-line-bytes)]
          [else (write-byte b out) (loop (add1 n))]))
  (regexp-replace #rx"\r$" (bytes->string/latin-1 (get-output-bytes out)) ""))

;; InputPort -> Natural
(define (read-status in)
  (define line (read-head-line in))
  (define m (regexp-match #px"^HTTP/1\\.[01] (\\d{3})(?: |$)" line))
  (unless m (raise-protocol-error "malformed status line ~s" line))
  (string->number (cadr m)))

;; InputPort -> Headers
;; the header fields up to the blank line, at most `max-header-count` of them
(define (read-headers in)
  (let loop ([acc '()])
    (define line (read-head-line in))
    (cond [(string=? line "") (reverse acc)]
          [(= (length acc) max-header-count)
           (raise-protocol-error "more than ~a response headers" max-header-count)]
          [(regexp-match #px"^([!#$%&'*+.^_`|~0-9A-Za-z-]+):[ \t]*(.*?)[ \t]*$" line)
           => (λ (m) (loop (cons (cons (string-downcase (cadr m)) (caddr m)) acc)))]
          [else (raise-protocol-error "malformed header line ~s" line)])))

;; Headers -> (or Natural #f)
;; the Content-Length, #f when absent; repeated fields must agree
(define (content-length headers)
  (define raw (for/list ([h (in-list headers)] #:when (string=? (car h) "content-length")) (cdr h)))
  (for ([v (in-list raw)])
    (unless (regexp-match? #px"^[0-9]+$" v) (raise-protocol-error "invalid Content-Length ~s" v)))
  (define lengths (remove-duplicates (map string->number raw)))
  (cond [(null? lengths) #f]
        [(null? (cdr lengths)) (car lengths)]
        [else (raise-protocol-error "conflicting Content-Length headers")]))

;; InputPort String Natural Headers Custodian -> InputPort
;; a port over exactly the response body, closing the connection when closed
(define (body-port in method status headers cust)
  (define len (content-length headers))
  (cond
    [(assoc "transfer-encoding" headers)
     (raise-protocol-error "chunked responses are not supported")]
    [(or (string=? method "HEAD") (memv status '(204 304)) (eqv? len 0))
     (custodian-shutdown-all cust)
     (open-input-bytes #"")]
    [else (counted-port in len cust)]))

;; InputPort (or Natural #f) Custodian -> InputPort
;; the next `length` bytes of `in` (all of them when #f); the port ends at that count, and
;; raises when `in` ends first. Closing it shuts `cust`, the owner of the connection.
(define (counted-port in length cust)
  (define remaining length)
  (define (read-in buf)
    (cond
      [(eqv? remaining 0) eof]
      [else
       (define n (read-bytes-avail! buf in 0 (if remaining (min remaining (bytes-length buf)) (bytes-length buf))))
       (cond [(not (eof-object? n)) (when remaining (set! remaining (- remaining n))) n]
             [remaining (raise-protocol-error "the response body ended ~a bytes early" remaining)]
             [else eof])]))
  (make-input-port 'http-body read-in #f (λ () (custodian-shutdown-all cust))))

;; Response String -> (or String #f)
(define (response-header r name)
  (define h (assoc (string-downcase name) (response-headers r)))
  (and h (cdr h)))

;; Response [Natural] -> Bytes
;; reads and closes the body; at most `limit` bytes (default 1 MiB) are returned
(define (response-body-bytes! r [limit (* 1024 1024)])
  (define in (response-body r))
  (dynamic-wind
   void
   (λ () (let ([bs (read-bytes limit in)]) (if (eof-object? bs) #"" bs)))
   (λ () (close-input-port in))))

(module+ test
  (require rackunit racket/file)

  ;; String -> (values Natural (-> Bytes))
  ;; a one-shot TCP server that reads one request (head + Content-Length body), replies with
  ;; `reply`, waits `linger` seconds, and closes; the thunk waits for the request it received
  (define (serve-once reply #:linger [linger 0])
    (define listener (tcp-listen 0 4 #t "127.0.0.1"))
    (define-values (_h port _rh _rp) (tcp-addresses listener #t))
    (define received (make-channel))
    (thread
     (λ ()
       (define-values (in out) (tcp-accept listener))
       (define head (let loop ([acc '()])
                      (define l (read-line in 'return-linefeed))
                      (if (or (eof-object? l) (string=? l "")) (reverse acc) (loop (cons l acc)))))
       (define len (for/or ([l head]) (cond [(regexp-match #px"(?i:^content-length: (\\d+))" l) => (λ (m) (string->number (cadr m)))] [else #f])))
       (define body (read-bytes (or len 0) in))
       (write-bytes reply out)
       (flush-output out)
       (sleep linger)
       (close-output-port out) (close-input-port in) (tcp-close listener)
       (channel-put received (cons head body))))
    (values port (λ () (channel-get received))))

  (define (host-header port) (list (cons "Host" (format "127.0.0.1:~a" port))))

  (test-case "request with a bytes body, response with Content-Length"
    (define-values (port received)
      (serve-once #"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nETag: \"x\"\r\n\r\nhello"))
    (define r (http-request #f "127.0.0.1" port "PUT" "/b/k" (host-header port) #"abc"))
    (check-equal? (response-status r) 200)
    (check-equal? (response-header r "ETag") "\"x\"")
    (check-equal? (response-body-bytes! r) #"hello")
    (define req (received))
    (check-equal? (car (car req)) "PUT /b/k HTTP/1.1")
    (check-not-false (member "Content-Length: 3" (car req)))
    (check-equal? (cdr req) #"abc"))

  (test-case "a path body is sent from the file"
    (define f (make-temporary-file))
    (call-with-output-file f #:exists 'truncate (λ (o) (write-bytes #"file-content" o)))
    (define-values (port received) (serve-once #"HTTP/1.1 204 No Content\r\n\r\n"))
    (define r (http-request #f "127.0.0.1" port "PUT" "/k" (host-header port) f))
    (check-equal? (response-status r) 204)
    (check-equal? (cdr (received)) #"file-content")
    (delete-file f))

  (test-case "a body without Content-Length runs to EOF; HEAD has no body"
    (define-values (p1 _r1) (serve-once #"HTTP/1.1 200 OK\r\n\r\nuntil-eof"))
    (check-equal? (response-body-bytes! (http-request #f "127.0.0.1" p1 "GET" "/" (host-header p1)))
                  #"until-eof")
    (define-values (p2 _r2) (serve-once #"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n"))
    (check-equal? (response-body-bytes! (http-request #f "127.0.0.1" p2 "HEAD" "/" (host-header p2)))
                  #""))

  (test-case "malformed and unsupported responses raise"
    (define-values (p1 _r1) (serve-once #"garbage\r\n\r\n"))
    (check-exn #rx"malformed status line" (λ () (http-request #f "127.0.0.1" p1 "GET" "/" (host-header p1))))
    (define-values (p2 _r2) (serve-once #"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"))
    (check-exn #rx"chunked" (λ () (http-request #f "127.0.0.1" p2 "GET" "/" (host-header p2)))))

  (test-case "header injection is refused before anything is sent"
    (define-values (port _r) (serve-once #"HTTP/1.1 200 OK\r\n\r\n"))
    (check-exn #rx"line break"
               (λ () (http-request #f "127.0.0.1" port "GET" "/" (list (cons "X" "a\r\nEvil: 1"))))))

  (define (get-from reply . kw)
    (define-values (port _r) (serve-once reply))
    (http-request #f "127.0.0.1" port "GET" "/" (host-header port)))

  (test-case "Content-Length must be digits; repeats must agree"
    (for ([bad '("+5" "5, 5" "-1" "0x5" "5 5" "")])
      (check-exn exn:fail:s3:protocol?
                 (λ () (get-from (string->bytes/utf-8 (format "HTTP/1.1 200 OK\r\nContent-Length: ~a\r\n\r\nhello" bad))))))
    (check-exn #rx"conflicting"
               (λ () (get-from #"HTTP/1.1 200 OK\r\nContent-Length: 5\r\ncontent-length: 6\r\n\r\nhello")))
    (check-equal? (response-body-bytes!
                   (get-from #"HTTP/1.1 200 OK\r\nContent-Length: 5\r\ncontent-length: 5\r\n\r\nhello"))
                  #"hello"))

  (test-case "a body cut short raises instead of returning less"
    (define r (get-from #"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"))
    (check-exn exn:fail:s3:protocol? (λ () (response-body-bytes! r))))

  (test-case "a head cut short, with an oversized line, or with too many headers raises"
    (check-exn exn:fail:s3:protocol? (λ () (get-from #"HTTP/1.1 200 OK\r\nA: b\r\n")))
    (check-exn #rx"longer than"
               (λ () (get-from (bytes-append #"HTTP/1.1 200 OK\r\nA: " (make-bytes 9000 97) #"\r\n\r\n"))))
    (check-exn #rx"more than"
               (λ () (get-from (bytes-append #"HTTP/1.1 200 OK\r\n"
                                             (apply bytes-append (for/list ([i 101]) #"A: b\r\n"))
                                             #"\r\n")))))

  (test-case "a stalled server trips the idle timeout, in the head and in the body"
    (define (stalled reply)
      (define-values (port _r) (serve-once reply #:linger 2))
      (http-request #f "127.0.0.1" port "GET" "/" (host-header port) #:idle-timeout 0.2))
    (check-exn exn:fail:s3:timeout? (λ () (stalled #"HTTP/1.1 200 OK\r\nContent-Le")))
    (define r (stalled #"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"))
    (check-exn exn:fail:s3:timeout? (λ () (response-body-bytes! r))))

  (test-case "connecting to a closed port raises"
    (define l (tcp-listen 0 1 #t "127.0.0.1"))
    (define-values (_h port _a _b) (tcp-addresses l #t))
    (tcp-close l)
    (check-exn exn:fail:network? (λ () (http-request #f "127.0.0.1" port "GET" "/" '()))))
)
