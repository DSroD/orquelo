#lang racket/base
;; A small MCP server library: JSON-RPC, tool definitions with generated JSON Schema, the protocol
;; (2026-07-28, plus legacy 2025 clients) and a Streamable HTTP handler for web-server.
(require "jsonrpc.rkt" "schema.rkt" "tool.rkt" "server.rkt" "http.rkt")
(provide (all-from-out "jsonrpc.rkt" "schema.rkt" "tool.rkt" "server.rkt" "http.rkt"))
