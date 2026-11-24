# Orquelo

Live polls and Q&A for PDF lectures. The presenter
(`/decks`) moves slides and opens or reveals polls. The projector (`/screen/:pid/:code`)
shows the slide and revealed results. Students (`/:pid/:code`) see only the active
poll. URLs are scoped to a lecture session, so one presentation can be reused across
classes without crosstalk. Votes are kept in Postgres for later analysis.

The backend is in Racket on purpose: it is a teaching showcase for HtDP students. Code
quality and idiom matter as much as behaviour.

## Layout

- `server/`: Racket 9.1 backend on the standard library (`web-server`, `db`, `json`,
  `openssl`, `syntax/parse`, `racket/contract`). Third-party packages need a
  justification, since each one has to be packaged into the `raco exe` image
- `server/storage/`: where uploaded PDFs live. Everything else reaches them only through
  `storage/store.rkt` (`store-put!`, `store-open`, `store-delete!`, `store-copy!`), with a
  local-disk and an S3 backend chosen by `STORAGE=local|s3`
- `server/s3/`: a generic S3 client (SigV4, TLS-verified HTTP/1.1) with no orquelo-specific
  code, so it can be published on its own
- `server/http-client/`: a generic HTTP/1.1 client (TLS-verified, optional peer-address check), used by S3 and
  the OAuth metadata fetch
- `server/mcp/`: a generic MCP server library (JSON-RPC, `define-tool`, stateless Streamable HTTP handler). The
  Orquelo tools are in `server/http/mcp-tools.rkt`; see `docs/mcp.md`
- `server/oauth/`: a generic OAuth 2.1 authorization server (PKCE, CIMD, DCR, opaque tokens) over a pluggable
  store. Orquelo's Postgres store is `server/db/oauth-store.rkt`, its routes `server/http/oauth-routes.rkt`.
  Neither library imports Orquelo code. Its property and model-based tests live in `server/oauth/tests/` (rackcheck,
  test-only: never require them from code reachable from `main.rkt`)
- `web/`: Svelte 5 + Vite SPA. `web/src/lib/types.ts` mirrors the API contract
- `e2e/`: Playwright user stories (`stories/*.spec.ts`) over helpers in `e2e/support` (actors: `Presenter`,
  `Projector`, `Student`, `McpClient`). Specs import `test`/`expect` only from `../support`
- `docs/api.md` + `docs/api-fixtures/`: **the API contract and source of truth**.
  The backend's JSON must equal the fixtures, and the frontend tests parse them
- `docs/accounts.md`: password accounts (`user` CLI, throttling, sessions)
- `docs/mcp.md`: the MCP endpoint for AI agents, its OAuth flow and tools
- `LICENSE` (AGPL-3.0-only), `CLA.md` (contributors agree with "I agree to CLA.md" in the PR) and `CONTRIBUTING.md`
- `compose.yaml`: self-hosting with Postgres on the published image; `CODE_OF_CONDUCT.md`, `SECURITY.md`
- `.github/workflows/`: `verify.yml` (flake check, migration lint) and `publish.yml` (`vX.Y.Z` tag on main: amd64 + arm64
  image, e2e, push to `ghcr.io/dsrod/orquelo`)
- `nix/`, `flake.nix`: packages (web, standalone server, OCI image), checks, devShell
- A hosted edition (closed source) builds on core through `lib.mkOrquelo`, the `$ext` web seam, the e2e `Edition` seam and extra migration streams. Core never depends on it.

## Commands

Run everything through the flake's devShell:

- `nix develop -c scripts/with-ephemeral-pg scripts/with-ephemeral-s3 raco test server`: backend
  tests on a throwaway Postgres and a throwaway S3 server (versitygw). A `SKIPPED` or
  `S3-SKIPPED` line means the DB or S3 tests didn't run, which is a failure. Without the
  S3 wrapper, only the S3 integration test (`server/tests/s3-test.rkt`) is skipped
- `nix develop -c scripts/e2e [playwright args]`: the e2e stories (Chromium from nixpkgs) on a throwaway
  Postgres and a local server on :18181; users are created through `user add`. Not alongside the backend tests
  (both use Postgres port 54329)
- `scripts/build-image-in-docker [system] [attr]` then `scripts/e2e-image [image]`: builds the Linux OCI image
  in a Docker-hosted Nix (works on macOS) and tests it end to end against Postgres (password login, `user` CLI)
- `scripts/dev`: local dev (`.env`, database `orquelo_core`); creates the database when it is missing
- Property tests pick a random seed each run and print `property seed: PROP_SEED=<n>`; rerun with that `PROP_SEED` to
  reproduce a failure, and set `PROP_SCALE=<k>` to run k times as many cases. rackcheck comes from the devShell
  (`PLTCOLLECTS`) or `lib.racketTestPkgs`
- `nix develop -c sh -c 'cd web && npm run test && npm run build'`
- `nix flake check`

## Racket conventions (required)

- **HtDP design recipe.** Each function is small, does one thing, and has a
  signature and purpose statement directly above it:
  ```racket
  ;; presentation-id Natural -> (or/c poll #f)
  ;; finds the poll by id within the presentation
  ```
  Each struct has a data definition with an interpretation next to it, e.g.
  `;; A Session is a (session Id Code String Time (or/c Time #f))`.
- **Structs, not hashes.** Model domain data as contracted structs. Classes only where
  one genuinely fits. Hashes and jsexprs exist only at the edges:
  - SQL row → struct in `db/repo`
  - `X->jsexpr` / `jsexpr->X` in `http/json`
  - request bodies parsed into structs by the endpoint DSL
- **Explicit interfaces.** `provide` lists with `contract-out`; never `all-defined-out`.
- **Hygienic macros** (`syntax-parse`) where they remove real repetition and read as a
  small declarative DSL, with clear compile-time errors via syntax classes. Not for
  their own sake.
- Prefer `match`, `for/…` comprehensions and `define-values` over manual
  `cond`/`hash-ref`/`car` plumbing.
- Error cleanup uses `dynamic-wind` or `exn:fail?` handlers, never `with-handlers
  ([void …])`, which also catches breaks.
- `live/state.rkt` stays pure (no IO). All effects live in `live/hub.rkt`, `db/` and
  `http/`.
- **Packaging constraint.** The image is built with `raco exe` + `raco distribute`.
  No runtime `dynamic-require`, `eval` or collection-path lookups. Files such as
  migrations and static assets come from directories set by env vars.
- **Migrations are append-only.** Never edit an applied `server/migrations/YYYYMMDDHHMMSS_name.sql`;
  add a new one with a later timestamp (`scripts/lint-migrations` enforces it in CI).
- Tests: rackunit `module+ test` per module, plus integration tests in
  `server/tests/` against the ephemeral Postgres.

## Frontend conventions

- Develop against the contract. Change `types.ts` only together with `docs/api.md`,
  the fixtures and the backend.
- The audience UI is phone-first (works at 360px, ≥48px touch targets). The screen
  must never overflow with many or long options.

## General

- Minimal code, with comments only for non-obvious parts.
- Don't touch unrelated code. Surface smells separately.
- Never commit `.env` or plaintext secrets. Cluster secrets live in SOPS
  (`secrets.sops.yaml`, created by the user).
