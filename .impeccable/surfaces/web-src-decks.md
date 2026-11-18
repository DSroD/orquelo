---
version: 1
slug: "web-src-decks"
primary_target: "web/src/decks"
related_targets: ["web/src/Audience.svelte"]
---

# Presenter + audience UI

## Scope and mode

- **Presenter:** Operate. Covers `web/src/decks/**`: presentation list, deck editor, poll form, live
  cockpit, results.
- **Audience:** Operate, phone-first. Covers `web/src/Audience.svelte` and the components it uses.
- **Projector:** `web/src/Screen.svelte` keeps its current look and must not change.

## Audience, job, constraints

- **Lecturers** run polls live, from a laptop in a dim hall and also from a phone. Colleagues get
  no training. The presenter view is never mirrored on the projector.
- **Students** vote from phones in seconds: 360px wide, touch targets ≥48px.
- **Live cockpit:** everything visible at once (slide, what's on screen, the open vote), with
  keyboard shortcuts shown inline. Shortcuts are never the only path.

## Pinned by the owner

A modern terminal-like look, plus inline shortcut hints. This is translated through the Operate
limit: the terminal lends type, palette, density and one signature move. Controls stay standard
web buttons, inputs, tabs and links. No fake prompt, no function-key bar.

## Direction contract

THESIS: The presenter view reads like a well-kept TUI session: one mono voice, panes divided by rules
instead of cards, and live state always on a status line. It refuses SaaS card soup: rounded
white panels, pill badges and rows of equal-weight outline buttons.

OWN-WORLD:
- **Type:** Martian Mono (variable weight and width), self-hosted. Width 112 for titles, 87 for
  body text, 75 for data and tables.
- **Ground:** a deep green-black.
- **Palette roles:**
  - amber: actions and selection
  - phosphor green: live
  - red: ended and destructive
  - cyan: data bars
  - dim sage: secondary text
- **Shape:** square corners (radius at most 2px), 1px rules, headings set as `── name ───` rules.
  States are bracket tags such as `[live]`, not pills.
- **Light theme:** a cool grey-green, never cream.

STORY: A colleague opens /decks and sees their decks as a listing. They open one, start a session,
and the cockpit tells them what is live and which key does what. The results read like a report.

FIRST VIEWPORT:
- **Live cockpit:**
  - top: a breadcrumb path (`~/decks/audit-deck/group-a`)
  - left: the current and next slide, with `← →` hints
  - right: the "on screen" control and the open vote's bars
  - bottom: a full-width status line
- **Primary action:** the amber button for the next step (open, reveal, close).

FORM: an owner-pinned direction, so no roll was made. Seed key: none (pinned). Signature move: a
tmux-style status line that carries the live state, and kbd chips on the buttons themselves.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
