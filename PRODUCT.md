# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

- **Lecturers** (the author and colleagues, possibly TAs; in the hosted edition, any lecturer): they run live polls
  in their own lectures. They use the presenter view on a laptop at the lectern, and often from a phone while walking
  the room. Colleagues get no training, so the presenter view must explain itself.
- **Students** (the audience): they join from their phones in a lecture hall, through a link or
  a QR code, and vote in a few seconds. Anonymous: no login, only a participant cookie.

## Product Purpose

Live polls over PDF lectures: a lightweight replacement for claper.co, sold as open core.

- **Core (this repository, AGPL-3.0):** the self-hosted product. A lecturer or institution runs it on their own
  server, with local accounts created by the operator.
- **Hosted edition (separate, closed repository):** Orquelo run as a service on top of core.

- The presenter moves the slides, then opens, reveals and closes polls.
- The projector shows the slide and the revealed results.
- Students see only the active poll.

Sessions scope the URLs, so one deck is reused across classes without crosstalk. Votes are kept
in Postgres for later analysis, through the results page and CSV exports. Success: polls run
smoothly in a real lecture, and the data is there afterwards.

## Positioning

A small tool owned end to end. Core is open source and self-hosted; the hosted edition is an option, not a
requirement:

- runs on the lecturer's own deck PDF
- no audience accounts
- no data leaves the operator's own server (core)
- per-class sessions
- results and raw votes exportable

The backend is deliberately Racket in HtDP style, as a teaching showcase.

## Operating Context

- **Presenter:** a laptop in a lecture hall, usually dim. The presenter page is never mirrored on the
  projector. It is driven by mouse and keyboard (arrow keys move slides), and also from a phone.
- **Screen:** `/screen/:pid/:code` runs full screen on the projector.
- **Audience:** `/:pid/:code` on students' phones, often on poor Wi-Fi.
- **Session flow:** upload a PDF → add polls (per slide or "any slide") → start a session → share
  the audience link or QR → present, open, reveal and close votes → review results and download
  CSVs.

## Capabilities and Constraints

- Poll kinds: single and multi choice, 2–30 options, long labels.
- A run can be resumed (votes kept), or a fresh vote started.
- Overlays on the screen: slide only, QR code, or poll results (hidden until revealed).
- **Audience UI:** phone-first, works at 360px, touch targets ≥48px.
- **Screen:** must never overflow, even with many or long options.
- **Operators** (core): whoever self-hosts it creates accounts with the `user` command and sets global upload and
  storage limits. There is no self-signup and no email sending.
- `web/src/lib/types.ts` mirrors the API contract in `docs/api.md`; the UI follows the contract.
- The projector screen keeps its current look; it is out of scope for visual redesigns unless
  asked.

## Brand Commitments

- Name: **Orquelo**, for both editions.
- **Presenter and audience UI:** a modern terminal-like look, with keyboard shortcuts shown inline in
  the live cockpit. The owner pinned this in November 2026.

## Evidence on Hand

- Real decks in the dev database ("GS Uvod", 26 slides; "Audit deck") and a real poll ("Which
  recursion template fits a list of numbers?").
- No testimonials, customers or usage numbers. Do not invent any.

## Product Principles

1. **The lecture must not stall:** every live action is one obvious step and its state is visible.
2. **Self-explanatory for a colleague** who has never seen it.
3. **Students vote in seconds** on any phone.
4. **Data outlives the lecture:** results and exports are first-class.
5. **Small and honest:** no features or claims beyond what it does.

## Accessibility & Inclusion

- WCAG AA contrast.
- Keyboard operable: shortcuts are additions, never the only path.
- Audience touch targets ≥48px.
- Respects `prefers-reduced-motion`.
