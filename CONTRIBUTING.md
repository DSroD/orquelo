# Contributing

Thanks for helping. Please open an issue first for anything bigger than a small fix.

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md). Report security problems privately as
described in [SECURITY.md](SECURITY.md), not in issues.

## Licence

Core is [AGPL-3.0](LICENSE). Before we can merge a pull request, you must agree to the
[Contributor Licence Agreement](CLA.md): put the line

    I agree to CLA.md

in the pull request description. You keep your copyright; the CLA lets the maintainer also license your
contribution under other terms (the hosted edition is not open source).

## Before you open a pull request

Run everything through the Nix devShell, from the repository root (or install the tools yourself, see
"Without Nix" in the [README](README.md)):

    nix develop -c scripts/with-ephemeral-pg scripts/with-ephemeral-s3 raco test server
    nix develop -c sh -c 'cd web && npm run test && npm run build'
    nix develop -c scripts/e2e          # the Playwright stories, when you changed behaviour users see
    nix flake check

A `SKIPPED` or `S3-SKIPPED` line in the backend output means the database or S3 tests did not run, which
counts as a failure. The e2e stories and the backend tests both use Postgres port 54329, so do not run them
at the same time.

Code conventions are in [AGENTS.md](AGENTS.md) (the Racket backend follows the HtDP design recipe: a signature
and purpose statement above each function, structs instead of hashes, contracted `provide`s). Add or update
tests with your change. The API contract is `docs/api.md` with `docs/api-fixtures/`; change them together with
`web/src/lib/types.ts` and the backend.

## Migrations are append-only

Never edit, rename or delete an applied `server/migrations/YYYYMMDDHHMMSS_name.sql`. Add a new file with a
later UTC timestamp instead. `scripts/lint-migrations` enforces this in CI.
