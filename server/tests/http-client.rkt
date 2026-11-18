#lang racket/base
;; A small HTTP client for the integration tests: plain requests, SSE streams and multipart uploads
;; against the server at `current-base`.
(require racket/list racket/string racket/port json net/http-client net/url)
(provide current-base base-port
         (struct-out resp) resp-json resp-header resp-headers-all
         http sse-open multipart upload!)

;; (parameter/c (or String #f))
;; the base URL of the server under test, e.g. "http://127.0.0.1:20123"; also the Origin requests send
(define current-base (make-parameter #f))

;; -> Natural
(define (base-port) (url-port (string->url (current-base))))

(struct resp (status headers body))
(define (resp-json r) (bytes->jsexpr (resp-body r)))
(define (resp-header r name)
  (for/or ([h (resp-headers r)])
    (define m (regexp-match (byte-regexp (bytes-append #"(?i:^" (string->bytes/utf-8 name) #": *)(.*)$")) h))
    (and m (bytes->string/utf-8 (cadr m)))))
(define (resp-headers-all r name)
  (for/list ([h (resp-headers r)] #:when (regexp-match? (byte-regexp (bytes-append #"(?i:^" (string->bytes/utf-8 name) #":)")) h))
    (bytes->string/utf-8 h)))

(define (http method path #:json [j #f] #:data [data #f] #:cookies [cookies '()] #:origin [origin (current-base)] #:headers [extra '()])
  (define headers
    (append (if (pair? cookies) (list (string-append "Cookie: " (string-join cookies "; "))) '())
            (if origin (list (string-append "Origin: " origin)) '())
            (if j '("Content-Type: application/json") '())
            extra))
  (define-values (status hdrs in)
    (http-sendrecv "127.0.0.1" path #:port (base-port) #:method method #:headers headers
                   #:data (cond [j (jsexpr->bytes j)] [data data] [else #f])))
  (define body (port->bytes in))
  (close-input-port in)
  (resp (string->number (cadr (regexp-match #rx" ([0-9]+) " (bytes->string/utf-8 status)))) hdrs body))

;; SSE client: -> (values status in next-event!); next-event! -> (cons name jsexpr) | #f on timeout
(define (sse-open path #:cookies [cookies '()])
  (define-values (status hdrs in)
    (http-sendrecv "127.0.0.1" path #:port (base-port)
                   #:headers (if (pair? cookies) (list (string-append "Cookie: " (string-join cookies "; "))) '())))
  (values status in
          (λ (#:timeout [t 1.5])
            (let loop ([lines '()])
              (cond
                [(not (sync/timeout t in)) #f]
                [else
                 (define l (read-line in 'any))
                 (cond
                   [(eof-object? l) 'eof]
                   [(string=? l "")
                    (define ev (for/first ([x lines] #:when (string-prefix? x "event: ")) (substring x 7)))
                    (define data (for/first ([x lines] #:when (string-prefix? x "data: ")) (substring x 6)))
                    (if ev (cons ev (string->jsexpr data)) (loop '()))]
                   [else (loop (cons l lines))])])))))

(define (multipart title page-count pdf-bytes)
  (define b "XXboundaryXX")
  (define (field n v) (format "--~a\r\nContent-Disposition: form-data; name=\"~a\"\r\n\r\n~a\r\n" b n v))
  (values
   (bytes-append (string->bytes/utf-8 (string-append (field "title" title) (field "page_count" page-count)))
                 (string->bytes/utf-8 (format "--~a\r\nContent-Disposition: form-data; name=\"pdf\"; filename=\"a.pdf\"\r\nContent-Type: application/pdf\r\n\r\n" b))
                 pdf-bytes
                 (string->bytes/utf-8 (format "\r\n--~a--\r\n" b)))
   (format "multipart/form-data; boundary=~a" b)))

(define (upload! title page-count pdf-bytes #:cookie cookie)
  (define-values (body ctype) (multipart title page-count pdf-bytes))
  (http "POST" "/api/decks" #:data body #:cookies (list cookie) #:headers (list (string-append "Content-Type: " ctype))))

(module+ test)
