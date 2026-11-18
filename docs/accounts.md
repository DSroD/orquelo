# Accounts in core

Core uses local accounts: an email and a password. There is no self-signup and no email sending (no SMTP),
so there is no "forgot password" mail: an operator creates accounts and resets passwords with the `user`
command line. A user can change their own password at `/account`.

## The `user` command

    orquelo user add EMAIL [--name NAME]   # the password is read from stdin
    orquelo user passwd EMAIL              # the new password is read from stdin
    orquelo user suspend EMAIL
    orquelo user activate EMAIL
    orquelo user list                      # id, email, status and name, tab-separated

In a checkout it is `racket server/main.rkt user ...`; in the image it is `/bin/orquelo user ...`. It reads
`DATABASE_URL` and `MIGRATIONS_DIR`, and migrates the database first, so it works against a fresh one.

- The password comes from stdin only, never from the arguments (a terminal would echo it, so pipe or redirect
  it): `racket server/main.rkt user add you@example.org --name You < password.txt`. One trailing newline is removed.
- A password is 10 to 1024 bytes (UTF-8).
- The email is trimmed and lower-cased. It is stored as verified, so decks can be shared with the user right away.
  `--name` defaults to the part before the `@`. A second account with the same email is refused.
- A suspended user gets 403 `suspended` everywhere and cannot log in. `activate` restores access.

## Login throttling

`POST /auth/password` (and the "current password" check of `PUT /api/me/password`) counts failures in memory,
per (email, client address) and per address (`server/auth/throttle.rkt`):

- after 5 failures in a row for the same email from the same address, each further attempt waits twice as long:
  1 s, 2 s, 4 s ... capped at 15 minutes (`429 throttled` with `Retry-After`);
- 50 failures from one address block it with the same back-off, whatever the emails;
- a successful login clears the (email, address) counter;
- the counters are per process and are lost on restart.

The client address is the socket peer. Behind a reverse proxy set `TRUST_PROXY=1`: the rightmost
`X-Forwarded-For` entry (the one your own proxy appended) is used instead. Without a proxy leave it unset, since
the header is client-controlled. Unknown emails are checked against a dummy hash, so the response time does not
reveal which emails exist.

## Sessions

The `orquelo_user` cookie is signed and holds `<user id>.<session epoch>`, valid for 12 hours. Each user has an
epoch counter in the database, and a cookie is accepted only while its epoch is current. Changing a password
(in the app or with `user passwd`) and suspending a user bump the epoch, which signs out every other session.
The app issues a fresh cookie to the user who changed their own password.

## Password hashing

scrypt through libcrypto (`EVP_PBE_scrypt`), with N=2^15, r=8, p=1, a 16-byte random salt and a 32-byte key.
It is stored as `$scrypt$ln=15,r=8,p=1$<salt>$<hash>` (base64, no padding), compared in constant time, and
rehashed at the next login when the parameters change. Each hash takes about 60 ms and 64 MiB; it runs on an OS
thread, at most 4 at a time, so other requests keep being served.

## Limits

Core has two global limits, not per user: `MAX_UPLOAD_BYTES` (largest single PDF, default and maximum 100 MiB)
and `STORAGE_QUOTA_BYTES` (what one user's own decks may hold in total; unset means unlimited). They show in
`GET /api/me` as `max_upload_bytes` and `storage_quota` (`null` when unlimited).
