#lang racket/base
;; A minimal HTTP/1.1 exchange: one request per connection ("Connection: close"), a body sent with
;; an explicit Content-Length (net/http-client can only send chunked bodies from a port, which
;; S3 rejects), and a streamed response body (Content-Length, chunked or until EOF). TLS uses the
;; system trust store and verifies the server's certificate and host name, which is also the name
;; sent for SNI. `#:check-peer` sees the address actually connected to, before any byte is sent.
;;
;; Failures are exn:fail:http (see errors.rkt): a connect that takes longer than the connect timeout
;; or a read that stalls longer than the idle timeout raises exn:fail:http:timeout; a reply that
;; is malformed, too large or cut short raises exn:fail:http:protocol. A TLS failure raises exn:fail:http;
;; a TCP connect that fails (unknown host, refused) raises exn:fail:network.
(require racket/contract/base racket/list racket/port racket/tcp openssl "errors.rkt")
(provide (struct-out exn:fail:http)
         (struct-out exn:fail:http:protocol)
         (struct-out exn:fail:http:timeout)
         (contract-out
          [struct response ([status exact-integer?]
                            [headers (listof (cons/c string? string?))]
                            [body input-port?])]
          [http-request (->* (boolean? string? (integer-in 1 65535) string? string?
                                       (listof (cons/c string? string?)))
                             ((or/c #f bytes? path?)
                              #:connect-timeout timeout? #:idle-timeout timeout?
                              #:check-peer (or/c #f (-> string? boolean?))
                              #:deadline (or/c #f real?))
                             response?)]
          [response-header (-> response? string? (or/c string? #f))]
          [response-body-bytes! (->* (response?) (exact-nonnegative-integer? #:overflow (or/c 'truncate 'error))
                                     bytes?)]
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
;;   [#:idle-timeout Timeout] [#:check-peer (or #f (String -> Boolean))]
;;   [#:deadline (or #f Real)] -> Response
;; sends one request to host:port (over TLS when `tls?`) and reads the status line and headers.
;; `target` is the request target, already percent-encoded; `headers` must include Host.
;; Content-Length is set from `body`, which is not read into memory when it is a path.
;; `check-peer` gets the IP address of the connected peer; when it answers #f the connection is
;; dropped with exn:fail:http before TLS or any request byte.
;; `deadline` is an absolute time in `current-inexact-monotonic-milliseconds` by which connecting
;; and every read of the head and body must be done, else exn:fail:http:timeout.
;; The connection lives on in the response body; it is closed when the body port is closed.
(define (http-request tls? host port method target headers [body #f]
                      #:connect-timeout [connect-timeout default-connect-timeout]
                      #:idle-timeout [idle-timeout default-idle-timeout]
                      #:check-peer [check-peer #f]
                      #:deadline [deadline #f])
  (define cust (make-custodian))
  (define handed-over? #f)
  (dynamic-wind
   void
   (λ ()
     (define-values (in out) (connect tls? host port (within-deadline connect-timeout deadline) check-peer cust))
     (write-head out method target (append headers (framing-headers body)))
     (write-body out body)
     (begin0 (read-response (idle-timeout-port in idle-timeout deadline) method cust)
             (set! handed-over? #t)))
   (λ () (unless handed-over? (custodian-shutdown-all cust)))))

;; Real (or Real #f) -> Real
;; `timeout` seconds, cut to the seconds left until `deadline` (never negative)
(define (within-deadline timeout deadline)
  (if deadline
      (max 0 (min timeout (/ (- deadline (current-inexact-monotonic-milliseconds)) 1000)))
      timeout))

;; Boolean String Port Timeout (or #f (String -> Boolean)) Custodian -> (values InputPort OutputPort)
;; connects within `timeout` seconds, vets the peer address, then starts TLS when `tls?`;
;; the ports belong to `cust`
(define (connect tls? host port timeout check-peer cust)
  (define result (make-channel))
  (parameterize ([current-custodian cust])
    (thread (λ ()
              (channel-put result
                           (with-handlers ([exn:fail? values])
                             (call-with-values (λ () (connect* tls? host port check-peer)) list))))))
  (define r (sync/timeout timeout result))
  (cond [(not r) (raise-timeout-error "connecting to ~a:~a timed out after ~as" host port timeout)]
        [(exn? r) (raise r)]
        [else (apply values r)]))

;; Boolean String Port (or #f (String -> Boolean)) -> (values InputPort OutputPort)
(define (connect* tls? host port check-peer)
  (define-values (in out) (tcp-connect host port))
  (define-values (_local peer) (tcp-addresses in))
  (unless (or (not check-peer) (check-peer peer))
    (close-input-port in)
    (close-output-port out)
    (raise-http-error "peer address ~a refused" peer))
  (if tls?
      (ports->ssl-ports in out #:context (ssl-secure-client-context) #:hostname host #:close-original? #t
                       #:error/ssl raise-tls-error)
      (values in out)))

;; Symbol String Any ... -> Nothing
;; the `error/ssl` of the TLS ports: a TLS failure is an exn:fail:http
(define (raise-tls-error who fmt . args)
  (raise-http-error "TLS failure: ~a" (if (string? fmt) (apply format fmt args) (format "~a" fmt))))

;; InputPort Timeout (or Real #f) -> InputPort
;; `in`, except that a read waiting longer than `timeout` seconds for data, or past `deadline`,
;; raises a timeout
(define (idle-timeout-port in timeout deadline)
  (define (read-in buf)
    (or (sync/timeout (within-deadline timeout deadline) (read-bytes-avail!-evt buf in))
        (raise-timeout-error "no data from the server within ~as or before the deadline" timeout)))
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
    [(or (string=? method "HEAD") (memv status '(204 304)) (eqv? len 0))
     (custodian-shutdown-all cust)
     (open-input-bytes #"")]
    [(transfer-encoding headers)
     => (λ (te)
          (unless (string=? te "chunked") (raise-protocol-error "unsupported Transfer-Encoding ~s" te))
          (when len (raise-protocol-error "both Transfer-Encoding and Content-Length"))
          (chunked-port in cust))]
    [else (counted-port in len cust)]))

;; Headers -> (or String #f)
;; the lowercased Transfer-Encoding value, #f when absent
(define (transfer-encoding headers)
  (define h (assoc "transfer-encoding" headers))
  (and h (string-downcase (cdr h))))

;; InputPort Custodian -> InputPort
;; the decoded body of a chunked message: hex size lines (extensions ignored), chunk data,
;; and after the 0-chunk the trailers, which are read and dropped. Raises on bad framing or
;; when `in` ends before the 0-chunk. Closing it shuts `cust`, the owner of the connection.
(define (chunked-port in cust)
  (define remaining 0)   ; bytes left in the current chunk
  (define done? #f)
  (define (next-chunk!)
    (define size (read-chunk-size in))
    (cond [(zero? size) (skip-trailers! in)
                        (set! done? #t)]
          [else (set! remaining size)]))
  (define (read-in buf)
    (cond
      [done? eof]
      [(zero? remaining) (next-chunk!) (read-in buf)]
      [else
       (define n (read-bytes-avail! buf in 0 (min remaining (bytes-length buf))))
       (when (eof-object? n) (raise-protocol-error "the response ended inside a chunk"))
       (set! remaining (- remaining n))
       (when (zero? remaining) (expect-crlf! in))
       n]))
  (make-input-port 'http-chunked read-in #f (λ () (custodian-shutdown-all cust))))

;; InputPort -> Void
;; reads and drops the trailer lines up to the blank line, at most `max-header-count` of them
(define (skip-trailers! in)
  (let loop ([n 0])
    (unless (string=? (read-head-line in) "")
      (when (= n max-header-count)
        (raise-protocol-error "more than ~a chunk trailers" max-header-count))
      (loop (add1 n)))))

;; InputPort -> Natural
;; the size on the next chunk-size line, without any chunk extension
(define (read-chunk-size in)
  (define line (read-head-line in))
  (define m (regexp-match #px"^([0-9A-Fa-f]{1,15}) *(?:;.*)?$" line))
  (unless m (raise-protocol-error "malformed chunk size line ~s" line))
  (string->number (cadr m) 16))

;; InputPort -> Void
;; consumes the CRLF that ends a chunk's data
(define (expect-crlf! in)
  (unless (equal? (read-bytes 2 in) #"\r\n") (raise-protocol-error "chunk data not followed by CRLF")))

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

;; Response [Natural] [#:overflow (or 'truncate 'error)] -> Bytes
;; reads and closes the body; at most `limit` bytes (default 1 MiB) are returned. A longer body
;; is cut at `limit` when `overflow` is 'truncate, and raises exn:fail:http:protocol when 'error.
(define (response-body-bytes! r [limit (* 1024 1024)] #:overflow [overflow 'truncate])
  (define in (response-body r))
  (dynamic-wind
   void
   (λ ()
     (define bs (read-bytes (if (eq? overflow 'error) (add1 limit) limit) in))
     (cond [(eof-object? bs) #""]
           [(> (bytes-length bs) limit) (raise-protocol-error "the response body is longer than ~a bytes" limit)]
           [else bs]))
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
    (define-values (p2 _r2) (serve-once #"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n"))
    (check-exn #rx"Transfer-Encoding" (λ () (http-request #f "127.0.0.1" p2 "GET" "/" (host-header p2)))))

  (test-case "header injection is refused before anything is sent"
    (define-values (port _r) (serve-once #"HTTP/1.1 200 OK\r\n\r\n"))
    (check-exn #rx"line break"
               (λ () (http-request #f "127.0.0.1" port "GET" "/" (list (cons "X" "a\r\nEvil: 1"))))))

  (define (get-from reply)
    (define-values (port _r) (serve-once reply))
    (http-request #f "127.0.0.1" port "GET" "/" (host-header port)))

  (test-case "Content-Length must be digits; repeats must agree"
    (for ([bad '("+5" "5, 5" "-1" "0x5" "5 5" "")])
      (check-exn exn:fail:http:protocol?
                 (λ () (get-from (string->bytes/utf-8 (format "HTTP/1.1 200 OK\r\nContent-Length: ~a\r\n\r\nhello" bad))))))
    (check-exn #rx"conflicting"
               (λ () (get-from #"HTTP/1.1 200 OK\r\nContent-Length: 5\r\ncontent-length: 6\r\n\r\nhello")))
    (check-equal? (response-body-bytes!
                   (get-from #"HTTP/1.1 200 OK\r\nContent-Length: 5\r\ncontent-length: 5\r\n\r\nhello"))
                  #"hello"))

  (test-case "a body cut short raises instead of returning less"
    (define r (get-from #"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"))
    (check-exn exn:fail:http:protocol? (λ () (response-body-bytes! r))))

  (test-case "a head cut short, with an oversized line, or with too many headers raises"
    (check-exn exn:fail:http:protocol? (λ () (get-from #"HTTP/1.1 200 OK\r\nA: b\r\n")))
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
    (check-exn exn:fail:http:timeout? (λ () (stalled #"HTTP/1.1 200 OK\r\nContent-Le")))
    (define r (stalled #"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"))
    (check-exn exn:fail:http:timeout? (λ () (response-body-bytes! r))))

  ;; Bytes ... -> Response
  (define (chunked-reply . parts)
    (get-from (apply bytes-append #"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" parts)))

  (test-case "a chunked body is decoded: chunks, extension, trailer"
    (check-equal? (response-body-bytes!
                   (chunked-reply #"5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: 1\r\n\r\n"))
                  #"hello world")
    (check-equal? (response-body-bytes! (chunked-reply #"0\r\n\r\n")) #""))

  (test-case "bad chunking raises"
    (for ([bad (list #"zz\r\nhello\r\n0\r\n\r\n"        ; bad hex
                     #"5\r\nhelloXX0\r\n\r\n"             ; no CRLF after the data
                     #"5\r\nhel"                            ; EOF inside a chunk
                     #"5\r\nhello\r\n"                      ; EOF before the 0-chunk
                     #"5\r\nhello\r\n0\r\nX: 1\r\n")])      ; EOF inside the trailers
      (define r (chunked-reply bad))
      (check-exn exn:fail:http:protocol? (λ () (response-body-bytes! r)) (bytes->string/latin-1 bad))))

  (test-case "a chunked body is read only up to the cap"
    (define r (chunked-reply #"a\r\n0123456789\r\n0\r\n\r\n"))
    (check-equal? (response-body-bytes! r 4) #"0123"))

  (test-case "Transfer-Encoding together with Content-Length is refused"
    (check-exn #rx"both"
               (λ () (get-from #"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\nabc"))))

  (test-case "#:check-peer sees the peer address and refuses before any byte is sent"
    (define listener (tcp-listen 0 4 #t "127.0.0.1"))
    (define-values (_h port _rh _rp) (tcp-addresses listener #t))
    (define received (make-channel))
    (thread (λ ()
              (define-values (in out) (tcp-accept listener))
              (channel-put received (read-bytes 1 in))))
    (define seen #f)
    (check-exn #rx"refused"
               (λ () (http-request #f "127.0.0.1" port "GET" "/" (host-header port)
                                   #:check-peer (λ (ip) (set! seen ip) #f))))
    (check-equal? seen "127.0.0.1")
    (check-true (eof-object? (sync/timeout 1 received)) "the server got EOF and no byte")
    (tcp-close listener))

  (test-case "more than max-header-count chunk trailers raise"
    (define trailers (apply bytes-append (for/list ([i (add1 max-header-count)]) #"X: 1\r\n")))
    (define r (chunked-reply #"0\r\n" trailers #"\r\n"))
    (check-exn #rx"trailers" (λ () (response-body-bytes! r)))
    (define ok (apply bytes-append (for/list ([i max-header-count]) #"X: 1\r\n")))
    (check-equal? (response-body-bytes! (chunked-reply #"0\r\n" ok #"\r\n")) #""))

  (test-case "#:overflow 'error raises instead of truncating"
    (check-equal? (response-body-bytes! (get-from #"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello") 5
                                        #:overflow 'error)
                  #"hello")
    (check-exn exn:fail:http:protocol?
               (λ () (response-body-bytes! (get-from #"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello") 4
                                           #:overflow 'error)))
    (check-equal? (response-body-bytes! (get-from #"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello") 4)
                  #"hell"))

  (test-case "#:deadline bounds a slow-drip server, in the head and in the body"
    (define (drip chunks)
      (define listener (tcp-listen 0 4 #t "127.0.0.1"))
      (define-values (_h port _rh _rp) (tcp-addresses listener #t))
      (thread (λ ()
                (define-values (in out) (tcp-accept listener))
                (let skip ()
                  (define l (read-line in 'return-linefeed))
                  (unless (or (eof-object? l) (string=? l "")) (skip)))
                (with-handlers ([exn:fail? void])
                  (for ([c (in-list chunks)])
                    (write-bytes c out) (flush-output out) (sleep 0.1)))
                (tcp-close listener)))
      port)
    (define (deadline-in s) (+ (current-inexact-monotonic-milliseconds) (* s 1000)))
    (define head-port (drip (cons #"HTTP/1.1 200 OK\r\n" (for/list ([i 30]) #"X-A: b\r\n"))))
    (check-exn exn:fail:http:timeout?
               (λ () (http-request #f "127.0.0.1" head-port "GET" "/" (host-header head-port)
                                   #:deadline (deadline-in 0.5))))
    (define body-port (drip (cons #"HTTP/1.1 200 OK\r\nContent-Length: 30\r\n\r\n"
                                  (for/list ([i 30]) #"x"))))
    (define r (http-request #f "127.0.0.1" body-port "GET" "/" (host-header body-port)
                            #:deadline (deadline-in 0.5)))
    (check-exn exn:fail:http:timeout? (λ () (response-body-bytes! r)))
    (check-exn exn:fail:http:timeout?
               (λ () (http-request #f "127.0.0.1" body-port "GET" "/" (host-header body-port)
                                   #:deadline (- (current-inexact-monotonic-milliseconds) 1)))))

  (test-case "a TLS failure (untrusted certificate) is an exn:fail:http"
    (define ctx (ssl-make-server-context))
    (define pem (collection-file-path "test.pem" "openssl"))
    (ssl-load-certificate-chain! ctx pem)
    (ssl-load-private-key! ctx pem)
    (define listener (ssl-listen 0 4 #t "127.0.0.1" ctx))
    (define-values (_h port _rh _rp) (ssl-addresses listener #t))
    (thread (λ () (with-handlers ([exn:fail? void])
                    (define-values (in out) (ssl-accept listener))
                    (close-input-port in) (close-output-port out))))
    (check-exn exn:fail:http? (λ () (http-request #t "127.0.0.1" port "GET" "/" (host-header port))))
    (ssl-close listener))

  (test-case "#:check-peer accepting lets the exchange through"
    (define-values (port _r) (serve-once #"HTTP/1.1 204 No Content\r\n\r\n"))
    (check-equal? (response-status (http-request #f "127.0.0.1" port "GET" "/" (host-header port)
                                                 #:check-peer (λ (ip) #t)))
                  204))

  (test-case "connecting to a closed port raises"
    (define l (tcp-listen 0 1 #t "127.0.0.1"))
    (define-values (_h port _a _b) (tcp-addresses l #t))
    (tcp-close l)
    (check-exn exn:fail:network? (λ () (http-request #f "127.0.0.1" port "GET" "/" '()))))
)
