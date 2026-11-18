# Orquelo

Live polls for PDF lectures, self-hosted. A presenter uploads a PDF deck, adds polls and runs a session: the
projector shows the slide and revealed results, and students vote from their phones. Optional Q&A gives
presenters a private question inbox and control over which question appears on screen. One deck can be reused
across classes, since every URL is scoped to a lecture session. Votes and questions are kept in Postgres for
later analysis.

Racket backend, Svelte frontend, built with Nix.

## Why

This project was initially created for my programming course, which closely follows the
[How to Design Programs](https://htdp.org/) book. I decided to write it in Racket to show my students that not
all software out there has to be in C/C++, Python or Java (as some of them firmly believe).

## Hosted version

Don't want to run it yourself? A hosted Orquelo with paid tiers runs at [orquelo.com](https://orquelo.com), on my
own infrastructure. It is built on this open-source core.

## Pages

| Page | Who |
|---|---|
| `/` | Redirects to `/decks` |
| `/login` | Sign in with email and password |
| `/account` | Change your password |
| `/decks`, `/decks/:id` | Deck list and editor: PDF, polls, Q&A, sharing, sessions |
| `/sessions/:code`, `/sessions/:code/results` | Live cockpit and results of a session |
| `/screen/:pid/:code` | Projector |
| `/:pid/:code` | Audience (anonymous, no login) |

Decks can be shared with other users by email. There is no self-signup: accounts are created by the operator
with the `user` command ([`docs/accounts.md`](docs/accounts.md)).

## Documentation

- [`docs/api.md`](docs/api.md) and `docs/api-fixtures/`: the API contract
- [`docs/qa-and-polls.md`](docs/qa-and-polls.md): Q&A, exclusive options and live poll options
- [`docs/accounts.md`](docs/accounts.md): the `user` command, login throttling, sessions, `TRUST_PROXY`
- [`docs/metrics.md`](docs/metrics.md): Prometheus metrics
- [`server/README.md`](server/README.md): backend module map and its two DSLs
- [`AGENTS.md`](AGENTS.md): code conventions; [`CONTRIBUTING.md`](CONTRIBUTING.md): how to contribute;
  [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md); [`SECURITY.md`](SECURITY.md): reporting vulnerabilities

## Run with Docker

Images for amd64 and arm64 are published as `ghcr.io/dsrod/orquelo` (tags `X.Y.Z`, `X.Y`, `latest`).
[`compose.yaml`](compose.yaml) runs Orquelo with Postgres:

    printf 'SESSION_SECRET=%s\nPUBLIC_BASE_URL=http://localhost:8080\n' "$(openssl rand -base64 48)" > .env
    docker compose up -d
    docker compose exec -T orquelo /bin/orquelo user add you@example.org < password.txt

Then log in at `http://localhost:8080/login`. The image migrates the database on start. Put it behind a TLS
reverse proxy for real use, set `PUBLIC_BASE_URL` to the public address and `TRUST_PROXY=1`. All settings are in
[Building the image](#building-the-image) and `.env.example`.

## Accounts

Users have an email and a password. Create them from the command line, with the password on stdin (never
argv), then log in at `/login`:

    set -a; . ./.env; set +a
    racket server/main.rkt user add you@example.org --name You < password.txt

`user` also has `passwd`, `suspend`, `activate` and `list`; see [`docs/accounts.md`](docs/accounts.md).
Users change their own password at `/account`.

## Limits

Two global settings, both optional:

- `MAX_UPLOAD_BYTES`: the largest PDF accepted, 1 byte to 100 MiB (the default and the maximum);
- `STORAGE_QUOTA_BYTES`: how much PDF data one user's own decks may hold in total. Unset means unlimited.

A PDF over the first is refused with 413 `too_large`, one that would pass the second with 413 `quota_exceeded`.

## Development

    nix develop
    scripts/with-ephemeral-pg scripts/with-ephemeral-s3 raco test server
    (cd web && npm run test && npm run build)
    scripts/dev    # loads .env, builds web, runs racket server + vite dev server

Copy `.env.example` to `.env` and create an account as above. `scripts/dev` creates its database
(`orquelo_core`) when it is missing.

### Without Nix

Nix pins every tool, and CI uses it, but the scripts only need these on `PATH`:

- [Racket](https://download.racket-lang.org) 9.1, the full distribution (`web-server`, `db` and `openssl` come with it)
  with OpenSSL 3 `libcrypto` (bundled on macOS and Windows; `libssl3` or `openssl` on Linux)
- Node.js 22 with npm
- PostgreSQL 17 client and server binaries (`psql`, `initdb`, `pg_ctl`) for `scripts/dev` and the test wrappers
- optional: [versitygw](https://github.com/versity/versitygw) for the S3 tests
- for the e2e stories, Chromium for Playwright: `(cd e2e && npm install && npx playwright install chromium)`

Then run the same commands as above without `nix develop`. This setup is not tested in CI. If a tool version
differs, check against `flake.nix`.

### End-to-end tests

    nix develop -c scripts/e2e [playwright args]

Runs the Playwright user stories (`e2e/stories`, Chromium from nixpkgs) against a throwaway Postgres and a local
server on port 18181; users are created through `user add`. It uses the same Postgres port as the backend
tests (54329), so do not run them at the same time.

### Resetting a development database

Stop the app, load the intended development environment, then run:

    nix develop -c bash -c 'set -a; . ./.env; set +a; racket server/main.rkt db reset --confirm'

This rebuilds the configured database schema and deletes all accounts, decks and sessions. It does not delete
stored PDF objects. Add your accounts again with `user add`. The command never runs automatically.

## Building the image

The `server` package, its integration-test check and the OCI `image` are Linux-only
(`raco distribute` does not work on darwin). `nix flake check` on a Mac checks the web package only.
To build them on a Mac, either enable `nix.linux-builder` in nix-darwin, or run
`scripts/build-image-in-docker` (nix inside a `nixos/nix` container, then `docker load`). Or build on Linux
with `nix build .#image`. Then run it with the core settings only:

    docker run --rm -p 8080:8080 -e DATABASE_URL=... -e PUBLIC_BASE_URL=http://localhost:8080 \
      -e SESSION_SECRET=... -e UPLOAD_DIR=/data orquelo:local

`SESSION_SECRET` is at least 32 bytes (`openssl rand -base64 48`). Optional: `PORT`, `METRICS_PORT`,
`POOL_SIZE`, `MAX_UPLOAD_BYTES`, `STORAGE_QUOTA_BYTES`, `TRUST_PROXY=1` behind a reverse proxy, and the storage
settings below (`.env.example` lists them). The image migrates the database on start. Create the first account with
the image's `user` command: `docker run --rm -i -e DATABASE_URL=... orquelo:local user add you@example.org < password.txt`.

`scripts/e2e-image` tests the built image end to end against Postgres.

## Storage

Uploaded PDFs go through the `Store` interface (`server/storage/store.rkt`). `STORAGE=local`
(default) keeps them in `UPLOAD_DIR`; `STORAGE=s3` keeps them in a bucket and uses `UPLOAD_DIR`
only to stage uploads. S3 settings: `S3_ENDPOINT` (`https://host[:port]`; `http://` is
refused behind an https `PUBLIC_BASE_URL`), `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`,
`S3_SECRET_ACCESS_KEY`, and `S3_PATH_STYLE=1` for servers without bucket sub-domains (MinIO,
Ceph, Contabo). The two keys are secrets.

The S3 integration test (`server/tests/s3-test.rkt`) needs the `S3_*` variables.
`scripts/with-ephemeral-s3` starts a throwaway versitygw on port 7079, creates a bucket and
runs its arguments with those variables set. Run it around the pg wrapper for the full suite;
without `S3_ENDPOINT` the test prints `S3-SKIPPED` and passes, so CI must fail on that marker.

## CI

`.github/workflows/verify.yml` runs `nix flake check` and `scripts/lint-migrations` (via `nix run .#lint-migrations`)
on pushes to `main` and on pull requests. `.github/workflows/publish.yml` runs on a `vX.Y.Z` tag that is on `main`: for
amd64 and arm64 it runs the server tests, builds the image (`dockerTools.buildLayeredImage`), runs `scripts/e2e-image`
and pushes it, then publishes the multi-arch tags `X.Y.Z`, `X.Y` and `latest` (a `vX.Y.Z-pre` tag gets only its own tag).

## Licence

Copyright © 2026 Daniel Rod. Licensed under the [GNU Affero General Public License, version 3 only](LICENSE)
(`AGPL-3.0-only`). If you run a modified version as a network service, the AGPL requires you to offer its
source to the users of that service.

Contributions need the [Contributor Licence Agreement](CLA.md); see [`CONTRIBUTING.md`](CONTRIBUTING.md).
