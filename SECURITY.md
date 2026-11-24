# Security policy

## Reporting a vulnerability

Please do not open a public issue. Report it privately through GitHub's
[private vulnerability reporting](https://github.com/DSroD/orquelo/security/advisories/new), or by email to
dsrod@seznam.cz. Include the version or commit, how to reproduce it, and what an attacker gains.

You should get an answer within a week. Once a fix is released, the advisory is published with credit to you,
unless you prefer otherwise.

## Supported versions

Only the latest release (the `latest` image tag) gets security fixes.

## Notes for reviewers

- **Outbound requests (SSRF).** OAuth clients may identify themselves with a Client ID Metadata Document: an
  https URL that Orquelo fetches. The fetch only goes to port 443, follows no redirects, has short timeouts,
  reads at most 5 KiB, and checks the connected peer's address before sending any byte, refusing loopback,
  private, link-local and other non-public ranges (`server/oauth/ip.rkt`, `server/oauth/cimd.rkt`). A report
  that gets Orquelo to reach an internal address through this path is in scope.
- **Self-asserted client names.** A client's name comes from the client itself. The consent page shows the
  verified host for metadata-document clients and labels registered clients as unverified, together with the
  host the user will be sent back to.
