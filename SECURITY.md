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
  that gets Orquelo to reach an internal address through this path is in scope. At most one fetch per
  `client_id` is in flight (concurrent requests share its result) and at most 8 run at once; a failed fetch
  is not repeated for five minutes.
- **Self-asserted client names.** A client's name comes from the client itself. The consent page shows the
  verified host for metadata-document clients and labels registered clients as unverified, together with the
  host the user will be sent back to. "Verified" means the host only: the name, logo and description are the
  client's own claims, and a verified host is not an endorsement of the client.
- **Registration limits.** Dynamic registration is limited per address (an IPv6 address by its /64), unused
  registered clients are deleted after 24 hours and at most 1000 of them are kept; further registrations get
  429 until the sweep makes room. Authorization and token requests are limited per address in the same way.
  Grants end 90 days after approval, and a used authorization code is remembered for 24 hours so that a replay
  revokes its grant. Password login throttling counts plain addresses (not /64s).
- **Consent page.** Every SPA page is sent with `Content-Security-Policy: frame-ancestors 'none'`, and the
  consent page also with `Referrer-Policy: no-referrer`. Approve and deny replies are `Cache-Control: no-store`.
