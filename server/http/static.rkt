#lang racket/base
;; SPA static files from STATIC_DIR (explicit dir, not collection-relative), history fallback to index.html.
(require racket/contract/base racket/file racket/list racket/string web-server/http "json.rkt")
(provide (contract-out
          [static-response (-> path-string? (listof any/c) response?)]
          [resolve-static (-> path-string? (listof any/c) (or/c path? #f))]
          [mime-for (-> (or/c path? string?) bytes?)]))

;; Hash of extension -> Bytes: the content type per file extension
(define mimes
  (hash ".html" #"text/html; charset=utf-8" ".js" #"text/javascript; charset=utf-8" ".mjs" #"text/javascript; charset=utf-8"
        ".css" #"text/css; charset=utf-8" ".svg" #"image/svg+xml" ".png" #"image/png" ".ico" #"image/x-icon"
        ".woff2" #"font/woff2" ".json" #"application/json; charset=utf-8" ".map" #"application/json; charset=utf-8"))

;; (or Path String) -> Bytes
;; content type by extension
(define (mime-for path)
  (define m (regexp-match #rx"[.][^.]*$" (if (path? path) (path->string path) path)))
  (hash-ref mimes (if m (string-downcase (car m)) "") #"application/octet-stream"))

;; Any -> Boolean
;; a plain path segment: no separators, no . or ..
(define (safe-segment? s)
  (and (string? s) (not (member s '("" "." "..")))
       (not (regexp-match? #rx"[/\\\0]" s))))

;; Path [Listof String] -> (or Path #f)
;; an existing regular file inside dir
(define (resolve-static dir segments)
  (and (pair? segments) (andmap safe-segment? segments)
       (let ([p (apply build-path dir segments)])
         (and (file-exists? p) p))))

;; [Listof String] -> Bytes
;; hashed assets are immutable, everything else revalidates
(define (cache-control segments)
  (cond [(equal? (car segments) "assets") #"public, max-age=31536000, immutable"]
        [else #"no-cache"]))

;; Path Bytes -> Response
(define (file-response p cc)
  (response/full 200 #"OK" (current-seconds) (mime-for p) (list (make-header #"Cache-Control" cc))
                 (list (file->bytes p))))

;; Path [Listof String] -> Response
;; the file, else (for extensionless paths) the SPA's index.html, else 404
(define (static-response dir segments)
  (define file (resolve-static dir segments))
  (cond
    [file (file-response file (cache-control segments))]
    [(and (pair? segments) (regexp-match? #rx"[.][a-z0-9]+$" (last segments))) (error-response 404 "not_found" "not found")]
    [(file-exists? (build-path dir "index.html")) (file-response (build-path dir "index.html") #"no-cache")]
    [else (error-response 404 "not_found" "frontend not built")]))

(module+ test
  (require rackunit)
  (define dir (make-temporary-file "orquelo-static~a" 'directory))
  (make-directory* (build-path dir "assets"))
  (display-to-file "<html>" (build-path dir "index.html"))
  (display-to-file "js" (build-path dir "assets" "app.js"))
  (define (hdr r name) (for/or ([h (response-headers r)]) (and (equal? (header-field h) name) (header-value h))))
  (define (body r) (let ([o (open-output-bytes)]) ((response-output r) o) (get-output-bytes o)))

  (test-case "path traversal is rejected"
    (check-false (resolve-static dir '("..")))
    (check-false (resolve-static dir '("assets" ".." "index.html")))
    (check-false (resolve-static dir '("assets/../index.html")))
    (check-false (resolve-static dir '("")))
    (check-false (resolve-static dir '("a\\b"))))
  (test-case "resolves real files only"
    (check-true (path? (resolve-static dir '("assets" "app.js"))))
    (check-false (resolve-static dir '("assets")))
    (check-false (resolve-static dir '("nope.js"))))
  (test-case "mime map"
    (for ([p '(("a.html" . #"text/html; charset=utf-8") ("a.JS" . #"text/javascript; charset=utf-8") ("a.mjs" . #"text/javascript; charset=utf-8")
               ("a.css" . #"text/css; charset=utf-8") ("a.svg" . #"image/svg+xml") ("a.png" . #"image/png") ("a.ico" . #"image/x-icon")
               ("a.woff2" . #"font/woff2") ("a.json" . #"application/json; charset=utf-8") ("a.map" . #"application/json; charset=utf-8")
               ("a.bin" . #"application/octet-stream") ("noext" . #"application/octet-stream"))])
      (check-equal? (mime-for (car p)) (cdr p))))
  (test-case "cache headers and fallback"
    (define a (static-response dir '("assets" "app.js")))
    (check-regexp-match #rx#"immutable" (hdr a #"Cache-Control"))
    (define i (static-response dir '("index.html")))
    (check-equal? (hdr i #"Cache-Control") #"no-cache")
    (define spa (static-response dir '("decks" "3")))
    (check-equal? (body spa) #"<html>")
    (check-equal? (hdr spa #"Cache-Control") #"no-cache")
    (check-equal? (body (static-response dir '("login"))) #"<html>")
    (check-equal? (body (static-response dir '())) #"<html>")
    (check-equal? (response-code (static-response dir '("missing.js"))) 404))
  (delete-directory/files dir))
