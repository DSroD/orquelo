# MCP and OAuth

Orquelo serves a Model Context Protocol (MCP) endpoint so an AI agent (Claude Code, Cursor, a claude.ai connector, ...)
can prepare your decks: read them, author polls, switch Q&A on and read aggregate results. The agent signs in through
an OAuth 2.1 authorization server built into Orquelo, and you approve each connection on a consent page.

The agent cannot upload PDFs, start sessions, open polls or see join codes: presenting stays in the web app.

## Connect

    claude mcp add --transport http orquelo https://your.orquelo.example/mcp

The client discovers the rest by itself, opens your browser on Orquelo's consent page, and you choose which scopes to
allow. Connected apps are listed at `/connected-apps`, where you can disconnect each one.

The endpoint exists only when `PUBLIC_BASE_URL` is an `https` origin (or loopback `http`) with no path. Otherwise OAuth
and `/mcp` are switched off (404) and the server logs a warning at startup.

## Transport

`POST /mcp`, Streamable HTTP, stateless: every reply is a single JSON body (no SSE, no `Mcp-Session-Id`).
`GET` and `DELETE` answer 405, a notification answers 202. Bodies over 1 MiB are refused (413).

Supported protocol versions: `2026-07-28` (`server/discover`, `_meta` version and `MCP-Protocol-Version`, `Mcp-Method`
and `Mcp-Name` headers, `resultType`) and the legacy `2025-11-25` and `2025-06-18` (`initialize`).

Every request needs `Authorization: Bearer <access token>`. A request that carries an `Origin` header other than
`PUBLIC_BASE_URL` gets 403 (DNS-rebinding protection); a request without one is accepted.

## Authorization

- Discovery: `/.well-known/oauth-protected-resource` (also under `/mcp`) and `/.well-known/oauth-authorization-server`.
  A 401 from `/mcp` carries `WWW-Authenticate: Bearer resource_metadata="..."`.
- Clients: Client ID Metadata Documents (the `client_id` is an https URL, preferred) or dynamic registration
  (`POST /oauth/register`). Public clients only (`token_endpoint_auth_method: none`); redirect URIs are https or
  loopback http.
- Flow: authorization code with PKCE `S256` only. The authorization response carries `iss` (RFC 9207).
- Scopes: `decks` (read and edit decks, polls and settings) and `results` (read aggregate results). The consent page
  lets you narrow what the client asked for. A request without `scope` asks for all of them. Orquelo's per-deck access
  still applies on top: a deck shared with you read-only stays read-only for your agent.
- `resource` (RFC 8707): omitted means the sole resource, `<PUBLIC_BASE_URL>/mcp`; anything else is `invalid_target`.
  Tokens are valid for that resource only.
- A tool call whose scope the token lacks gets 403 `WWW-Authenticate: Bearer error="insufficient_scope", scope="..."`.

### Tokens

| Token | Lifetime |
|---|---|
| authorization code | 60 seconds, single use |
| access token | 1 hour |
| refresh token | 30 days, sliding: each refresh issues a new pair and the lifetime starts over |

Tokens are opaque random values, stored only as SHA-256 hashes. Refresh tokens rotate, and there is **no reuse grace
window**: presenting an already used refresh token (or code) revokes the whole grant, so a leaked token that gets used
twice ends the connection. The client then has to be approved again.

### What ends access

- Disconnecting the app in Connected apps (`DELETE /api/oauth/grants/:id`).
- Reusing a refresh token (above) or letting it expire.
- A password change or a suspension of the account. A grant records the user's session epoch; both bump it, so the
  access tokens stop working at once and Connected apps shows the app as "reconnect needed". Approving it again makes a
  new connection.

## Tools

Slides are numbered from 1 to `page_count`. Errors come back as tool errors (`isError: true`) shaped like the REST
API's `{error, message, field?}` with the same codes (`not_found`, `forbidden`, `poll_has_runs`, `deck_disabled`, ...),
except that every bad argument, whether the schema or the domain rejected it, has the one code `invalid_argument` with
the offending `field`.

| Tool | Scope | Access to the deck | What it does |
|---|---|---|---|
| `list_decks` | decks | view | your decks (`archived` optional), with `qa_enabled` and your access |
| `get_deck` | decks | view | page count, `qa_enabled`, `disabled` when the deck was switched off, and a flat list of polls, each with its `slide` (null: none); no sessions or codes |
| `create_poll` | decks | edit | `deck_id`, `slide` (number or null), `question`, `kind` (`single`/`multi`), `options` (2 to 30, each `label` and optional `exclusive`), optional `show_results`, `allow_additional_answers` |
| `replace_poll` | decks | edit | the same fields with `poll_id`; `poll_has_runs` once the poll was opened: duplicate it instead |
| `delete_poll` | decks | edit | `poll_id`; `poll_has_runs` once opened |
| `duplicate_poll` | decks | edit | `poll_id`; copies without runs |
| `set_poll_show_results` | decks | edit | `poll_id`, `show_results` |
| `rename_deck` | decks | edit | `deck_id`, `title` |
| `set_qa_enabled` | decks | edit | `deck_id`, `enabled` |
| `list_sessions` | results | results | `deck_id`; every session newest first: `session_id`, `label`, `started_at`, `ended_at` (no codes) |
| `get_results` | results | results | `deck_id`, optional `session_id` (one session), optional `limit` (1 to 50, default 10: how many newest sessions to return) |

`get_results` returns `total_sessions` and `truncated` (true when `limit` cut the list; use `list_sessions` to find the
rest) and, per session, the label, `started_at`, `ended_at`, `unique_voters` and, per poll run, the question,
`opened_at`, `closed_at`, `total_voters` and the count of every option. It never returns join codes, individual votes
or Q&A text.

### Who can read results over MCP

A deck shared with the `results` flag lets that person's agent read the results of **every** session of the deck with
`list_sessions` and `get_results`, aggregates only. The REST API is narrower: `GET /api/decks/:id` lists sessions only
to users who may edit or moderate, because its session list carries join codes. The MCP tools never return codes, so
they can offer the session list to results-only sharers.
