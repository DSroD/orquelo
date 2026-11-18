# Orquelo: Racket backend

A production web service written in plain Racket 9.1 using only the standard
distribution. Every function follows the HtDP design recipe: a signature, a purpose
statement, and tests. See `../AGENTS.md` for the conventions.

## Module map

| Module | Role |
|---|---|
| `domain.rkt` | Data definitions: contracted structs for Presentation, Poll, Option, Session, PollRun, Vote, User, Limits, … |
| `config.rkt`, `env.rkt` | Environment → `config` struct (validated once at startup) |
| `edition.rkt`, `editions/core.rkt` | The extension interface (plugin, route kit, commands, migration streams) and the core edition: password login, env limits |
| `user-cli.rkt` | The `user add\|passwd\|suspend\|activate\|list` command line, dispatched from `main.rkt` |
| `db-cli.rkt`, `db/reset.rkt` | Explicitly confirmed development schema reset; clears all data |
| `db/query.rkt` | `define-query` macro |
| `db/repo.rkt` | SQL for decks, polls, sessions and votes, written as `define-query` forms. SQL rows become structs here |
| `db/accounts.rkt` | SQL for users, password credentials, status and the session epoch |
| `qa.rkt`, `db/qa.rkt` | Q&A data definitions and session-owned questions, moderation and submission limits |
| `db/conn.rkt`, `db/migrate.rkt` | `DATABASE_URL` → connection; applies `migrations/*.sql` in order, per stream (see Migrations below) |
| `live/state.rkt` | **Pure** live-lecture state machine: `step : State Event -> State`, `project : State Role -> Snapshot` |
| `live/snapshot.rkt` | Per-role snapshot structs (audience / screen / moderator / restricted editor) |
| `live/hub.rkt`, `live/mailbox.rkt` | The only stateful part: holds each session's state and pushes snapshots to SSE subscribers |
| `http/endpoint.rkt` | `define-endpoint` macro |
| `http/public.rkt`, `http/decks.rkt` | Handlers (audience and screen; signed-in users), written as `define-endpoint` forms |
| `http/json.rkt` | `X->jsexpr` per struct. JSON exists only at this edge |
| `http/routes.rkt` | URL → handler table (`dispatch-rules`) plus the auth/Origin guards |
| `auth/session.rkt`, `auth/users.rkt` | Signed cookies carrying the user id and session epoch; cookie → current user |
| `auth/password.rkt`, `auth/throttle.rkt` | scrypt password hashing (libcrypto, off the Racket VM thread) and login back-off |
| `http/password-routes.rkt` | `POST /auth/password` and `PUT /api/me/password` |
| `auth/access.rkt` | What a user may do with a deck (owner or share role). Pure |
| `results.rkt`, `export.rkt` | Session results and their CSV export |
| `uploads.rkt` | Validates an uploaded PDF into a staging file |
| `storage/store.rkt` | The `Store` interface for PDFs; `local.rkt` and `s3.rkt` implement it, `config.rkt` picks one |
| `s3/` | Generic S3 client: SigV4 signing, minimal HTTP/1.1 over verified TLS, put/get/head/delete/copy |
| `metrics/` | Prometheus registry and the app, hub and runtime metrics |
| `main.rkt` | Wires it together and starts the web server, or runs the edition's commands (`user`, `db`) |

## The two DSLs

Both are hygienic `syntax-parse` macros. Their syntax classes turn a malformed spec
into a readable **compile-time** error, and the tests check for that.

### `define-query`: one SQL statement becomes a function

```racket
(define-query (get-session c code) #:maybe-row row->session
  "SELECT " session-cols " FROM lecture_sessions WHERE code=$1")
```

The result keyword picks both the `db` function and the row converter:
`#:exec #:count #:value #:maybe-value #:list #:row #:maybe-row #:rows`. The SQL stays
literal and visible, and the macro removes the `query-maybe-row` + convert + `#f` noise.

### `define-endpoint`: an HTTP handler as a declarative spec

```racket
(define-endpoint (cast-vote* d req pid code)
  #:need [s (public-session pid code)]                  ; lookup, or 404/410
  #:json [in (vote-input [run-id (integer)]             ; body -> struct, or 422
                         [option-ids (distinct-integers)])]
  ...)
```

Clauses run in order, and each binds names for the clauses after it. `#:need` performs
lookups that fail with the right HTTP status. `#:json` and `#:form` parse the request
body straight into a struct; the field `run-id` reads the JSON key `"run_id"`. The body
then works only with structs.

## One request, end to end (a student casts a vote)

1. `routes.rkt` matches `POST /api/s/<pid>/<code>/vote` to `cast-vote*`.
2. `define-endpoint` checks that the session exists and is live, and parses the body
   into `(vote-input run-id option-ids)`.
3. `repo.rkt`'s `cast-vote!` runs in a transaction. It locks the open run *of this
   session*, so a vote from another class can't land here, then replaces the
   participant's vote.
4. `hub.rkt` applies the event `(vote-cast …)` to that session's state with the pure
   `step`.
5. For each subscriber, the hub calls `project` for that subscriber's role and sends
   the snapshot only if it changed. Students never receive counts; the screen receives
   them only after reveal.
6. `json.rkt` turns the snapshot struct into JSON at the SSE edge.

## Running and testing

```sh
nix develop -c scripts/with-ephemeral-pg scripts/with-ephemeral-s3 raco test server   # unit + Postgres + S3 integration
scripts/dev                                                 # local server + Vite (reads ../.env)
```

The image is built with `raco exe` + `raco distribute`, a standalone runtime without
the full Racket install. That's why the code never uses runtime `dynamic-require` or
`eval`.

## Migrations

- Files are `server/migrations/YYYYMMDDHHMMSS_name.sql` (UTC timestamp, `^\d{14}_[a-z0-9_]+\.sql$`).
  Any other `*.sql` there is an error. Each file runs in its own transaction.
- A *stream* is one directory with its own history. Versions in `schema_migrations` are `<stream>/<file>`,
  e.g. `core/20261117000000_init.sql`. Streams run in the order given to `migrate!`, files by name.
  `MIGRATIONS_DIR` sets core's directory.
- **Never edit an applied migration; add a new one with a later timestamp.** Startup refuses to run when a
  pending file is older than the newest applied one of its stream, and logs a warning for applied versions
  this binary does not know (a rollback to an older image).
- `scripts/lint-migrations DIR BASE_REF` (also `nix run .#lint-migrations -- server/migrations origin/main`) fails
  on modified, deleted or renamed migrations, bad names, duplicate timestamps, and new files not newer than
  the newest on `BASE_REF`. CI runs it. Only timestamp-named files count as history, so the one-off rename of
  `001_init.sql` is exempt. `scripts/lint-migrations-test` tests the lint.
- A development database created before the timestamp names holds `001_init.sql`: run `orquelo db reset --confirm`.
