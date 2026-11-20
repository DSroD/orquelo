# API contract

### Conventions
- JSON keys are `snake_case`. Timestamps are ISO-8601 UTC strings (`"2026-11-15T10:00:00.000Z"`) or `null`. Slides are 1-based.
- `pid` = presentation id (integer in path). `code` (audience) and `screen_code` (presenter) both match `^[a-z2-7]{10}$` and are independent random values. The audience link `/:pid/:code` grants voting, Q&A submission and the audience stream only; the projector link `/screen/:pid/:screen_code` grants the screen stream and the slides PDF. `screen_code` is shown to moderators only.
- Error body for `/api/*`: `{"error": "<code>", "message": "<human text>", "field": "<optional>"}`. `/auth/*` errors are plain-text pages.
- Mutating requests (POST/PUT/PATCH/DELETE under `/api/decks`, `/api/polls` and `/api/sessions`) must send an `Origin` equal to `PUBLIC_BASE_URL`; otherwise the response is 403 `bad_origin`. Combined with `SameSite=Lax`, this covers CSRF.

| HTTP | `error` | When |
|---|---|---|
| 400 | `bad_request` | Malformed JSON, path or query |
| 401 | `unauthorized` | No or invalid user cookie, or the user no longer exists |
| 403 | `forbidden` / `suspended` / `bad_origin` | The deck is visible to the user but their access lacks the flag the endpoint needs / account suspended / Origin mismatch |
| 404 | `not_found` | Unknown id, a deck (or a poll or session of it) the user cannot see, unknown code, or a code that doesn't belong to `pid`. An audience code on a screen endpoint (and the reverse) is an unknown code |
| 409 | `poll_not_open`, `run_not_resumable`, `no_poll_overlay`, `poll_has_runs`, `poll_has_no_runs`, `poll_archived`, `session_live`, `pdf_pending`, `qa_disabled`, `qa_not_open`, `additional_answers_disabled`, `question_not_pending` | State conflicts |
| 410 | `session_ended` | Session has `ended_at` |
| 413 | `too_large`, `quota_exceeded` | A PDF over the user's per-deck cap (`max_upload_bytes`) / one that would take the owner's stored PDFs over their storage quota (`storage_quota`) |
| 422 | `invalid` (+`field`) | Validation (see the limits below) |
| 429 | `qa_rate_limited`, `qa_question_limit` | Less than 10 seconds since the participant’s previous Q&A submission / already 20 questions in this session |
| 500 | `internal` | Anything else (logged, no details leaked) |
| 503 | `busy` | No database connection became free in time; retry later (`Retry-After: 1`) |

Validation limits: title 1–200 chars; question 1–500; options 2–30, each label 1–200; Q&A text 1–1,000 trimmed characters; `slide` is `null` or 1..`page_count`; label (session) 0–100; PDF ≤ 100 MiB and must start with `%PDF-`.

### Cookies
| Name | Value | Attributes |
|---|---|---|
| `orquelo_participant` | session code and participant UUID v4 | `Path=/api/s/:pid/:code`, browser-session lifetime |
| `orquelo_remember_participant` | signed participant UUID v4 on opt-in, or the same `off` preference for every visitor who declines | `Path=/api/s`, up to one year |
| `orquelo_user` | id-cookie signed `<user id>.<session epoch>` (decimal) | `Path=/`, up to 12 hours |

These cookies use HttpOnly and SameSite=Lax, with Secure when `PUBLIC_BASE_URL` is HTTPS.
Audience streams and successful submissions set the session cookie when needed. Session
metadata and projector routes do not set a participant cookie. The legacy `orquelo_pid`
cookie is ignored and expired on audience participation or a preference update.

`GET /api/s/cookies` returns `{remember: true | false | null}`. A null value means no
saved choice. `POST /api/s/cookies` takes `{remember: boolean}`, requires a matching
Origin and returns the saved choice. A change applies when assigning an identity in
future sessions. It does not replace an existing session identity or rewrite stored
votes or questions. Declining or leaving the choice unset assigns a fresh identifier
for each session.

### Shared shapes
```
Access       = {owner, edit, moderate, copy, results: bool}   // what the asking user may do; any visible deck can be viewed
Presentation = {id, title, page_count, created_at, archived_at:ISOTime|null, qa_enabled:bool,
                owner: {email:string, name:string},          // email "" when the owner has none
                access: Access}
Share        = {email, edit, moderate, copy, results: bool}  // email lowercase
PresentationListItem = Presentation & {live_sessions:int}
OptionDraft  = {label:string, exclusive:bool}
Option       = {id, idx, label, exclusive:bool}                       // idx 0-based, display order
Poll         = {id, presentation_id, slide: int|null, position, question,
                kind: "single"|"multi", options: [Option], has_runs: bool,
                show_results: bool, allow_additional_answers: bool,
                                                      // open the poll with its results already shown on the screen
                archived_at: ISOTime|null}            // null = active; only polls with runs can be archived
Session      = {id, presentation_id, code, screen_code, label, started_at, ended_at|null,
                audience_url, screen_url}             // URLs from PUBLIC_BASE_URL; screen_code/screen_url null for edit-only viewers
Question     = {id, text, status:"pending"|"answered"|"dismissed", created_at, updated_at}
```

### Public
| Method & path | Request | Response |
|---|---|---|
| `GET /healthz` | – | `200 text/plain "ok"`. Process liveness only, **no DB call** (the probe is shared by liveness and readiness, and the image smoke test runs without a DB) |
| `GET /api/s/:pid/:code` | – | `200 {presentation:{id,title,page_count}, session:{code,label}}` · 404 · 410 |
| `GET /api/s/:pid/:code/stream?role=audience` | – | SSE (below) · 400 for any other `role` (`screen` included) · 404 · 410 |
| `POST /api/s/:pid/:code/vote` | `{run_id:int, option_ids:[int]}` | `200 {run_id, option_ids}` · 404 · 410 · 409 `poll_not_open` (not the session's open run) · 422 (empty, duplicates, >1 for `single`, option not in this run, exclusive option combined with any other choice) |
| `POST /api/s/:pid/:code/qa` | `{text:string}` | `201 Question` · 404 · 410 · 409 `qa_disabled` / `qa_not_open` · 422 · 429 `qa_rate_limited` / `qa_question_limit` |
| `GET /api/screen/:pid/:screen_code` | – | `200 {presentation:{id,title,page_count}, session:{code,label}}` (`code` = audience code, for the QR) · 404 · 410 |
| `GET /api/screen/:pid/:screen_code/stream` | – | SSE, role screen (below) · 404 · 410 |
| `GET /api/screen/:pid/:screen_code/slides.pdf` | – | `200 application/pdf`, `Cache-Control: private, max-age=3600` · 404 · 410 |

### Auth
Core users sign in with an email and a password (accounts are created with the `user` CLI, see [accounts.md](accounts.md)). Other editions add more login routes.

| Method & path | Behaviour |
|---|---|
| `POST /auth/password` | Body `{email:string, password:string}`; the Origin header is required (403 `bad_origin`). The email is trimmed and lower-cased. `204` and `Set-Cookie: orquelo_user` · 400 `bad_request` · 422 `invalid` (`field`: an empty or over-long value) · 401 `invalid_credentials` (unknown email and wrong password look the same) · 403 `suspended` · 429 `throttled` with `Retry-After` (whole seconds). Failures back off per (email, client address): 5 in a row, then 1 s, 2 s, 4 s ... up to 15 minutes; 50 failures from one address block it. The client address is the socket peer, or with `TRUST_PROXY=1` the rightmost `X-Forwarded-For` entry |
| `PUT /api/me/password` | Body `{current:string, new:string}`, signed in, Origin required. `204` and a new `orquelo_user` cookie; every other session of the user ends · 401 `unauthorized` (not logged in) / `invalid_credentials` (wrong `current`) · 403 `suspended` / `bad_origin` · 422 `invalid` with `field: "new"` (not 10 to 1024 bytes) · 429 `throttled` (same throttle, keyed by the user's email and address) |
| `POST /auth/logout` | Needs the Origin header (403 `bad_origin`). Clears `orquelo_user`, `204` |
| `GET /api/me` | `200 Me` · 401 · 403 `suspended` |

```
Me = {user: {id:int, email:string|null, name:string},
      membership: {plan:string|null,        // null in core; other editions may name the user's plan
                   status:"active"|"suspended",
                   storage_used:int,          // bytes of PDFs in the user's own decks
                   storage_quota:int|null,    // bytes the user may store; null: unlimited
                   max_upload_bytes:int}}     // largest single PDF the user may upload
```

### Deck access
Each deck has an owner (the uploader). The owner may do everything; anyone else needs a share, which applies to the user whose **verified** email equals the share's email (so a deck can be shared before the person has ever logged in). A share grants view plus the flags set on it: `edit` (rename, polls, deck Q&A configuration, live option additions), `moderate` (run sessions, the moderator stream), `copy` (copy the deck), `results` (the results page and every CSV: they hold personal data). Archive, unarchive, delete and shares are owner-only. A deck the user cannot see is 404 on every endpoint (so ids do not leak); a visible deck without the needed flag is 403 `forbidden`; for session endpoints access is checked before the 410. Moderators still see live aggregate tallies on the moderator stream, which running a poll needs. Edit-only collaborators may discover sessions and use the same stream through a restricted projection: current poll and tallies only, no Q&A inbox, projector credentials, stage, connection counts or run history. Editing does not grant moderation controls.

Known limit: access is checked when a request or stream starts. Revoking a share (or its `moderate` flag) does not stop a moderator SSE stream that is already open; it ends when the client reconnects, and the reconnect is refused.

### Decks, polls and sessions (all require `orquelo_user`, else 401; a suspended user gets 403 `suspended`)
The access needed is in brackets: view, edit, moderate, results, copy, owner.
| Method & path | Request | Response |
|---|---|---|
| `GET /api/decks` | – | `200 [PresentationListItem]`: the user's own and the shared decks, newest first |
| `POST /api/decks` | `multipart/form-data`: `title`, `page_count` (pdf.js client-side), `pdf` (file) | `201 Presentation` owned by the caller · 422 · 413 `too_large` (over `max_upload_bytes`) · 413 `quota_exceeded` (checked race-free against the caller's stored PDFs) |
| `GET /api/decks/:id` [view] | – | `200 Presentation & {polls:[Poll], sessions:[Session]}` (polls ordered `slide NULLS LAST, position`; sessions newest first for moderators or editors, otherwise `[]`; edit-only callers receive `screen_code:null` and `screen_url:null`) |
| `PATCH /api/decks/:id` [edit] | `{title}` | `200 Presentation` |
| `PUT /api/decks/:id/qa` [edit] | `{enabled:bool}` | `204`. New sessions capture this setting; active sessions are unaffected |
| `DELETE /api/decks/:id` [owner] | – | `204`. Deletes the deck with its sessions, runs, votes, polls and shares, and its stored PDF. 409 `session_live` while any of its sessions has not ended: the stage never loses its deck mid-lecture |
| `GET /api/decks/:id/pdf` [view] | – | `200 application/pdf` |
| `POST /api/decks/:id/polls` [edit] | `{slide, question, kind, options:[OptionDraft], show_results?:bool, allow_additional_answers?:bool}` (both flags default `false`) | `201 Poll` (`position` = max+1 within (presentation, slide)) |
| `PUT /api/polls/:poll_id` [edit] | same as POST (full replace; option order = array order) | `200 Poll` · 409 `poll_has_runs` |
| `PATCH /api/polls/:poll_id` [edit] | `{show_results:bool}` | `200 Poll`. A display setting, so it stays editable after the poll has runs |
| `DELETE /api/polls/:poll_id` [edit] | – | `204` · 409 `poll_has_runs` |
| `POST /api/polls/:poll_id/duplicate` [edit] | – | `201 Poll` (new editable copy, same slide, appended position, question unchanged; always active, even when the original is archived) |
| `POST /api/polls/:poll_id/archive` [edit] | – | `200 Poll` with `archived_at` set. Idempotent: archiving an archived poll keeps its original timestamp. 404 · 409 `poll_has_no_runs` (message "poll has no runs; delete it instead") |
| `POST /api/polls/:poll_id/unarchive` [edit] | – | `200 Poll` with `archived_at: null`. 404. Archived polls stay in `GET /api/decks/:id`; clients filter on `archived_at` |
| `POST /api/decks/:pid/archive` / `.../unarchive` [owner] | – | `200 Presentation`. `GET /api/decks?archived=1` lists archived ones. |
| `POST /api/decks/:id/copy` [copy] | – | `201 Presentation` owned by the caller: same title, page count and PDF (copied in storage), plus the non-archived polls; no sessions or votes. Counts against the caller's limits: 413 `too_large` / `quota_exceeded`. 409 `pdf_pending` while the source PDF is still being uploaded |
| `GET /api/decks/:id/shares` [owner] | – | `200 [Share]` ordered by email |
| `PUT /api/decks/:id/shares/:email` [owner] | `{edit, moderate, copy, results: bool}` (all four) | `200 Share`. Creates or replaces the grant; the email is trimmed and lowercased, 422 `email` when it is not one |
| `DELETE /api/decks/:id/shares/:email` [owner] | – | `204` · 404 when there is no such share |
| `POST /api/decks/:id/sessions` [moderate] | `{label}` | `201 Session` (random `code` and `screen_code`) |
| `POST /api/sessions/:code/end` [moderate] | – | `204` · 410 if already ended. Closes the open run, broadcasts `ended`, closes all streams |
| `POST /api/sessions/:code/slide` [moderate] | `{slide}` | `204` · 422 |
| `POST /api/sessions/:code/poll/open` [moderate] | `{poll_id}` | `200 {run_id, options:[Option]}`. Snapshots the definition’s options and additional-answer flag, closes any open run, opens the new one and puts it on the stage as the poll overlay, revealed iff the poll has `show_results` (which stamps `revealed_at`). 404 if the poll isn't in this presentation · 409 `poll_archived` (resuming a run, showing past runs, results and CSV are unaffected) |
| `POST /api/sessions/:code/poll/close` [moderate] | – | `204` · 409 `poll_not_open`. Closes the open run; the stage is unchanged |
| `POST /api/sessions/:code/poll/resume` [moderate] | `{run_id:int}` | `200 {run_id, options:[Option]}`. Reopens the session's newest run, which must be closed, keeping its votes and added run options, and puts its poll overlay on the stage, revealed iff its results were ever shown. 404 if the run isn't one of this session's · 409 `run_not_resumable` (not the newest run, or already open) |
| `POST /api/sessions/:code/poll/options` [edit] | `{run_id:int, label:string, exclusive:bool}` | `201 Option`. Append to this session’s open, opted-in run only; 409 `poll_not_open` / `additional_answers_disabled` · 422 for the 30-option limit or exclusive on a single-choice poll |
| `POST /api/sessions/:code/qa` [moderate] | `{open:bool}` | `204`. Open or close submissions independently of polling · 409 `qa_disabled` |
| `PATCH /api/sessions/:code/qa/questions/:id` [moderate] | `{status:"pending"|"answered"|"dismissed"}` | `204`. Status changes preserve text; answering/dismissing the selected question clears its selection · 404 for another session’s question |
| `POST /api/sessions/:code/overlay` [moderate] | `{overlay: null \| {type:"qr"} \| {type:"poll", run_id:int} \| {type:"qa", question_id:int\|null}}` | `204`. Replaces the overlay (`null` = none). `poll` shows any run of this session, open or past, starting revealed iff its `revealed_at` is set. Q&A uses `question_id:null` for the generic invitation; a selected question must be pending and belong to this session. 404 for a foreign run/question · 409 `qa_disabled` / `question_not_pending` · 422 |
| `POST /api/sessions/:code/poll/reveal` [moderate] | – | `204` · 409 `no_poll_overlay`. Reveals the run in the poll overlay (stamps its `revealed_at` if null) |
| `POST /api/sessions/:code/poll/hide` [moderate] | – | `204` · 409 `no_poll_overlay`. In memory only |
| `GET /api/sessions/:code/stream` [moderate or edit] | – | SSE, moderator or restricted editor projection. Ended sessions still stream a single snapshot and then `ended` |
| `GET /api/sessions/:code/export.csv` [results] | – | `200 text/csv; charset=utf-8`, `Content-Disposition: attachment; filename="orquelo-<code>.csv"`. Works for ended sessions |
| `GET /api/sessions/:code/results` [results] | – | `200 SessionResults` (see below). Works for ended sessions. Peak audiences are stored every 10 s and at run boundaries and session end, so a live session's peaks lag by up to 10 s · 404 |
| `GET /api/sessions/:code/qa.csv` [results] | – | `200 text/csv; charset=utf-8`, filename `orquelo-<code>-qa.csv`; columns `question_id,question,status,created_at,updated_at`. Includes every status, no participant identifiers; works after session end |
| `GET /api/sessions/:code/results.csv` [results] | – | `200 text/csv; charset=utf-8`, `Content-Disposition: attachment; filename="orquelo-<code>-results.csv"`. One row per run and option, zero counts included; columns `session_code, session_label, presentation_title, run_id, opened_at, closed_at, poll_id, slide, question, kind, option_idx, option_label, count, percent, total_voters, peak_audience, participation, median_seconds_to_vote`. Works for ended sessions · 404 |

All `/api/sessions/:code/*` mutations on an ended session → 410.

### Session results
`SessionResults` (fixture `results.json`):
```
{ session: {code, label, started_at, ended_at|null}, presentation: {id, title},
  qa: {enabled:bool, questions:[Question]},
  summary: {unique_voters, peak_audience|null, runs, avg_participation|null,
            median_seconds_to_vote|null, changed_votes|null, changed_voters|null},
  runs: [{run_id, poll_id, slide|null, question, kind, opened_at, closed_at|null,
          total_voters, peak_audience|null, participation|null, median_seconds_to_vote|null,
          changed_voters|null, options: [{id, idx, label, count}]}] }   // runs oldest first
```
- `options` lists every snapshotted or live-added option of the run in `idx` order, zero counts included.
- `peak_audience` is the most audience connections at once, in the session or while the run was open (a resumed run continues its peak).
- `participation` is `total_voters / peak_audience` as a 0..1 fraction capped at 1; `summary.avg_participation` is its mean over the runs that have one.
- `median_seconds_to_vote` is the median seconds from the run opening to a voter's first vote; changing a vote does not move it.
- `changed_votes` / `changed_voters`: answers changed to a different option set, and the voters who did so.
- Any `|null` field is `null` when unknown: sessions and votes from before engagement tracking, runs without a peak or without votes.

### Stage, overlays and runs
What the screen shows is exactly the **stage**: `{slide, overlay}`, the slide in the background (always rendered) and at most one overlay on top. An overlay is a sum type, tagged by `type`:
- `{type:"qr"}`: the join QR and URL;
- `{type:"poll", run_id, ...}`: run `run_id` of this session covers the slide; `revealed` says whether its counts are shown.
- `{type:"qa", question_id:int|null}` in moderator state: `null` shows the generic Q&A invitation. The screen receives only `{type:"qa", question:null|{id,text}, open:bool}`; no inbox or author identity.

`revealed` exists only inside the poll overlay. Slide changes never touch the overlay and closing a run does not remove it: the presenter dismisses it. Showing another overlay replaces the current one. More kinds can be added later as one more variant (backend, `types.ts`, one Svelte branch).

The **open run** is the only run accepting votes (at most one per session). It is independent of the overlay: an earlier run can be on the stage while a new one is open. Closed runs are immutable, so any past run can be shown again, e.g. to compare before and after a slide.

Q&A screen selection is persisted and restored after restart. Otherwise, restart reconstructs the persisted slide plus the open run’s poll overlay (revealed iff `revealed_at` is set), or no overlay when no run is open.

### Q&A lifecycle and privacy

Each deck has one Q&A setting, default off. Sessions capture it when created and start with submissions closed. The persisted `started` flag records whether submissions have ever opened; the audience tab is hidden until then. Moderators may open/close Q&A alongside polling. Once opened, the audience tab remains available read-only while closed; reopening retains the inbox. Ending a session closes submissions and all mutations are refused.

Questions are plain text. Participants see only their own questions and moderation status; moderators see the full session inbox. Showing a question changes only the projector selection, not its status. Answer/dismiss clears the selection back to the generic Q&A screen if that question was shown. Restore sets status to `pending` without displaying it. Closing submissions does not change the projector. No public feed, author editing, withdrawal, written replies or upvotes are included.

Submissions are keyed to the existing participant cookie: at most 20 questions per participant per session, at least 10 seconds apart. These are accidental-flood protections, not strong identity-based abuse controls. The database serializes checks with session mutations. Submitted questions survive close/reopen and restarts; results access is required to review/export the full inbox after the session.

### Poll options and run snapshots

Definition inputs use structured `OptionDraft` entries. `exclusive:true` is valid only for multi-choice polls. A ballot with an exclusive option must contain exactly that one option; mixed ballots are rejected. In the audience UI an ordinary selection disables exclusive choices, and an exclusive selection disables all other choices until deselected.

A new run gets its own option IDs and an ordered snapshot of the definition. Treat definition option IDs and run option IDs as separate namespaces; voting uses run option IDs returned by open/resume or the live stream. “Allow additional answers” is opt-in before the definition has runs, then immutable alongside its options. Editors may append to an opted-in open run; moderators without edit rights may not. Existing ballots remain valid and unchanged. Participants may explicitly revote after seeing additions. The 30-option cap includes additions. Closing/resuming retains the run’s options; starting another run copies only the reusable definition. Results and CSV read run snapshots, so no addition changes earlier runs or another session.

### SSE
- Headers: `Content-Type: text/event-stream`, `Cache-Control: no-cache`, `X-Accel-Buffering: no`. The first bytes are `retry: 3000\n\n`.
- The server sends `event: snapshot\ndata: <json>\n\n` immediately on connect, then whenever that subscriber's projection **changes**. The hub stores the last-sent jsexpr per subscriber and skips equal ones, so other students' votes generate no audience traffic.
- `event: ended\ndata: {}\n\n` is sent once, after which the server closes the stream. Clients stop reconnecting and show "This lecture has ended".
- Heartbeat: the comment line `: hb\n\n` every 15 s.
- Clients reconnect with backoff (1 s, 2 s, 4 s … capped at 15 s, reset on the first `snapshot`). A reconnect re-receives the full snapshot.

Snapshot payloads:
```
audience = {
  session: {code, label}, presentation: {id, title},
  poll: null | {run_id, question, kind, open: bool, options: [{id, label, exclusive:bool}]},  // the open run only
  qa: {enabled:bool, open:bool, started:bool, questions:[Question]},                       // this participant only
  my_vote: null | [option_id]                                                // this participant, open run
}
screen = {
  session: {code, label}, presentation: {id, title, page_count}, join_url: audience_url,
  stage: {
    slide: int,
    overlay: null
           | {type: "qr"}
           | {type: "qa", question:null|{id,text}, open:bool}
           | {type: "poll", run_id, question, kind, open: bool, revealed: bool,
              total_voters: int,                       // always present: a "N voted" counter leaks no split
              options: [{id, label, count: int | null}]}   // count is null unless revealed
  }
}
moderator = {
  session: {code, screen_code, label, started_at, ended_at}, presentation: {id, title, page_count},
  audience_url, screen_url, connections: {audience: int, screen: int},
  stage: {slide: int, overlay: null | {type: "qr"} | {type: "poll", run_id, revealed: bool}
                                     | {type: "qa", question_id:int|null}},
  qa: {enabled:bool, open:bool, started:bool, questions:[Question], selected_question_id:int|null},
  open_run: null | {run_id, poll_id, question, kind, opened_at,
                    options: [{id, label, exclusive:bool, count}], total_voters: int, allow_additional_answers:bool},        // the run accepting votes
  runs: [{run_id, poll_id, question, kind, opened_at, closed_at, total_voters}]  // this session's history, newest first
}
```
The editor projection has the same top-level keys as moderator, but `session.screen_code`, `screen_url`, `connections`, `stage` and `qa` are `null`, and `runs` is `[]`. The `open_run` shape is unchanged.

The audience sees a poll only while the open run is open: with no open run, `poll` and `my_vote` are `null` (results are on the projector only).

`count` = participants that chose the option. `total_voters` = distinct participants in the run. The frontend computes percent = count / total_voters (largest-remainder rounding for `single`, plain rounding for `multi`). Options are always ordered by `idx`.

Contract fixtures: `docs/api-fixtures/` also includes `audience-qa.json`, `moderator-qa.json`, `screen-qa.json`, `screen-qa-question.json` and `editor.json`. The original examples cover polling, idle states and QR display. A rackunit test checks that the projection output has the same key structure; vitest checks that `web/src/lib/types.ts` parses them.
