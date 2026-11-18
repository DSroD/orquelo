---
name: Orquelo
description: Live polls over PDF lectures; the presenter and audience UI read like a well-kept terminal session.
colors:
  ground: "#0b130e"
  panel: "#131f17"
  rule-line: "#2a3d30"
  ink: "#d8e5d4"
  dim-sage: "#8ea898"
  amber: "#f2a93b"
  amber-fill: "#f2a93b"
  on-amber: "#171002"
  selection: "#2c2511"
  phosphor-green: "#5fdc86"
  signal-red: "#ff7d70"
  data-cyan: "#4cc8df"
  ground-light: "#e8eeea"
  panel-light: "#dae3de"
  rule-line-light: "#a9b9af"
  ink-light: "#14201a"
  dim-sage-light: "#46594d"
  amber-light: "#845000"
  amber-fill-light: "#e0970f"
  on-amber-light: "#150e00"
  selection-light: "#cfe0e6"
  phosphor-green-light: "#0d6b34"
  signal-red-light: "#b3261e"
  data-cyan-light: "#066a80"
typography:
  display:
    fontFamily: "Martian Mono Variable, ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "1.35rem"
    fontWeight: 600
    lineHeight: 1.25
    fontVariation: "'wdth' 112.5"
  headline:
    fontFamily: "Martian Mono Variable, ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "1rem"
    fontWeight: 600
    lineHeight: 1.25
    fontVariation: "'wdth' 112.5"
  audience-question:
    fontFamily: "Martian Mono Variable, ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "clamp(1.1rem, 5vw, 1.5rem)"
    fontWeight: 600
    lineHeight: 1.25
    fontVariation: "'wdth' 112.5"
  rule-heading:
    fontFamily: "Martian Mono Variable, ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "0.85rem"
    fontWeight: 500
    fontVariation: "'wdth' 100"
  title:
    fontFamily: "Martian Mono Variable, ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "0.85rem"
    fontWeight: 500
    lineHeight: 1.25
    fontVariation: "'wdth' 87.5"
  body:
    fontFamily: "Martian Mono Variable, ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
    fontFeature: "'tnum'"
    fontVariation: "'wdth' 87.5"
  data:
    fontFamily: "Martian Mono Variable, ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "0.85rem"
    fontWeight: 400
    fontFeature: "'tnum'"
    fontVariation: "'wdth' 75"
  label:
    fontFamily: "Martian Mono Variable, ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "0.8em"
    fontWeight: 400
    lineHeight: 1
    fontVariation: "'wdth' 75"
rounded:
  none: "0px"
  sharp: "2px"
  round: "50%"
spacing:
  hair: "2px"
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  xxl: "24px"
  gutter: "32px"
components:
  button-primary:
    backgroundColor: "{colors.amber-fill}"
    textColor: "{colors.on-amber}"
    rounded: "{rounded.sharp}"
    padding: "6px 14px"
    height: "44px"
  button-quiet:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.sharp}"
    padding: "6px 14px"
    height: "44px"
  button-quiet-hover:
    textColor: "{colors.amber}"
  button-small:
    rounded: "{rounded.sharp}"
    padding: "2px 10px"
    height: "32px"
  button-danger:
    backgroundColor: "transparent"
    textColor: "{colors.signal-red}"
    rounded: "{rounded.sharp}"
  button-on:
    backgroundColor: "{colors.selection}"
    textColor: "{colors.amber}"
    rounded: "{rounded.none}"
  link-action:
    backgroundColor: "transparent"
    textColor: "{colors.amber}"
    padding: "0 1ch"
  input:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sharp}"
    padding: "8px 10px"
    height: "40px"
  tag:
    textColor: "{colors.dim-sage}"
    typography: "{typography.data}"
  tag-live:
    textColor: "{colors.phosphor-green}"
  tag-ended:
    textColor: "{colors.signal-red}"
  kbd-chip:
    textColor: "currentColor"
    typography: "{typography.label}"
    rounded: "{rounded.sharp}"
    padding: "2px 5px"
  status-line:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    typography: "{typography.data}"
  option-card:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sharp}"
    padding: "12px 14px"
    height: "56px"
  option-card-selected:
    backgroundColor: "{colors.selection}"
  bar-fill:
    backgroundColor: "{colors.data-cyan}"
    height: "6px"
---

# Design System: Orquelo

## Overview

**Creative North Star: "The Kept Session"**

The presenter and audience UI read like a well-kept TUI session: one monospace voice, panes divided by 1px rules instead of cards, and live state always on a status line. The terminal lends type, palette, density and one signature move (the tmux-style status line with kbd chips on the buttons themselves); the controls stay standard web buttons, inputs, radio groups and links. There is no fake prompt and no function-key bar.

Density is high and calm. A lecturer in a dim hall sees the slide, what is on screen and the open vote at once, and the single amber button always names the next step. Students on a 360px phone get the same voice at larger sizes: one question, tall option rows, one sticky submit.

The world is scoped: every rule lives under `html.term`, which App.svelte sets for every route except the projector. The projector (`/screen/:pid/:code`: Screen.svelte, ResultsBars.svelte, app.css) is an explicit exception. It keeps its legacy look and is not part of this system.

**Key Characteristics:**
- One typeface (Martian Mono, variable weight and width); hierarchy comes from width, weight and color, not from a second family.
- Deep green-black ground in dark; cool grey-green in light, never cream.
- Square corners (2px at most), 1px rules, flat surfaces.
- Section headings drawn as `── name ─────` rules; states written as bracket tags like `[live]`.
- Color is semantic only: amber acts, green is live, red is ended or destructive, cyan is data, sage is secondary.
- Keyboard shortcuts shown inline as kbd chips; never the only path.

## Colors

A dark phosphor palette on a green-black ground, with five semantic voices and no decorative color. Dark is the hall theme; light follows `prefers-color-scheme` and darkens every voice for AA on its ground.

### Primary
- **Lectern Amber** (`amber` / `amber-light`): every action and every selection. Links, quiet-button hover, the focus ring (2px outline, 2px offset), the selected segment, checked radios and checkboxes, breadcrumb current item, caret and `accent-color`.
- **Amber Fill** (`amber-fill` / `amber-fill-light`) with **On-Amber** text (`on-amber` / `on-amber-light`): the filled primary button only. In light it is a brighter amber than the text amber, so dark text holds contrast on it.

### Secondary
- **Phosphor Green** (`phosphor-green` / `-light`): live and only live. `[live]` and `[open]` tags, the status-line live segment and its dot, "voting" in run rows, the audience "Vote recorded" hint.

### Tertiary
- **Signal Red** (`signal-red` / `-light`): ended and destructive. `[ended]`, End session, Delete, Remove, error text, the audience "Reconnecting…" note. The ended status dot turns square.
- **Data Cyan** (`data-cyan` / `-light`): result bar fills only.

### Neutral
- **Green-Black Ground** (`ground`) / **Cool Grey-Green** (`ground-light`): page background, scrollbar track.
- **Panel** (`panel` / `-light`): inputs, option cards, the status line, the New deck form.
- **Rule Line** (`rule-line` / `-light`): every 1px border, rule heading lines, bar tracks, scrollbar thumb.
- **Ink** (`ink` / `-light`): body text.
- **Dim Sage** (`dim-sage` / `-light`): secondary text, tags at rest, rule heading labels, `h3`, field labels, breadcrumb separators, link-row separators.
- **Selection** (`selection` / `-light`): background of the chosen segment, the chosen run row and selected option cards. Amber-tinted in dark, cool blue-grey in light.

### Named Rules
**The Five Voices Rule.** Amber acts, green is live, red is ended or destructive, cyan is data, sage is secondary. A color never carries a second meaning, and nothing is colored for decoration.

**The One Amber Fill Rule.** At most one filled amber button per area, and in the live cockpit it is the next step (open, then reveal, then close). Every other action is a quiet outlined button or an amber text link.

**The Never Cream Rule.** The light theme is a cool grey-green (`ground-light`); warm paper tones are out.

## Typography

**Display Font:** Martian Mono Variable (self-hosted woff2, OFL; weight 100–800, width 75–112.5%), falling back to ui-monospace, SF Mono, Menlo, Consolas.
**Body Font:** the same family.
**Label/Mono Font:** the same family, narrowed.

**Character:** One mono voice with three widths. Wide for titles, standard-narrow for reading, condensed for data, so a dense cockpit still scans by shape.

### Hierarchy
- **Display** (600, 1.35rem, 1.25, width 112.5%): page `h1` such as the session or deck name.
- **Headline** (600, 1rem, width 112.5%): `h2`, used rarely; most sections use rule headings instead.
- **Audience question** (600, clamp(1.1rem, 5vw, 1.5rem), width 112.5%): the poll question and state headings on phones.
- **Rule heading** (500, 0.85rem, width 100%, dim sage): section headings drawn as rules.
- **Title** (500, 0.85rem, dim sage): `h3` subgroups such as "This slide" / "Any slide".
- **Body** (400, 14px, 1.5, width 87.5%, tabular numerals): all reading text, buttons, inputs, links.
- **Data** (width 75%, often 0.85rem): counts, dates, times, tags, breadcrumbs, the status line, key/value report tables.
- **Label** (0.8em, width 75%, line-height 1): kbd chips.

### Named Rules
**The Three Widths Rule.** Width encodes role: 112.5% titles, 87.5% body, 75% data. Use width before adding size steps.

**The Local Clock Rule.** Times are local and 24-hour: `HH:MM`, dates `YYYY-MM-DD`, together `YYYY-MM-DD HH:MM` (web/src/lib/time.ts). Never a 12-hour clock or a locale-dependent date.

## Layout

- **Page:** a single column, max 76rem, centred, padding 12px 16px 32px, 20px gap between blocks. Every presenter page starts with a breadcrumb path (`~ / decks / audit-deck / group-a`, condensed, current item in amber), then a header bar with the title on the left and its actions on the right.
- **Two presenter jobs.** *Prepare* (deck list, deck editor, poll form) is desktop-first and dense: row actions are amber text links, and every poll shows a 16:9 thumbnail of its slide (an "any slide" box when it has none); the poll form previews the chosen slide. *Run* (the live cockpit, and the editor's "Live now" strip that leads into it) is thumb-first: every action is a real button, links only navigate, and secondary session tools sit in one `Session` menu. The deck editor has two tabs under its title, drawn as a window list (dim labels with counts, the selected one amber with a 2px amber underline on the rule; full-width halves on phones) and always opening on Sessions: Live now (only while a session is live; its Control button is the area's amber fill), New session, History (ended sessions with Results and CSV). The Polls tab has an active / archived segment; locked polls can be archived (kept with their results, no longer offered in any cockpit), unrun polls are deleted instead.
- **Live cockpit:** at ≥900px a two-column grid (3fr / 2fr, 24px row gap, 32px column gap). The left column holds Slides (current and next thumbnails at 2:1, Prev / `n / N` / Next) with Polls beneath. The right column holds On screen above Voting. Below 900px one column in the order Slides, Voting, On screen, Polls. The status line is sticky at the bottom, full width.
- **Listings:** rows separated by 1px rules (10px vertical padding, no rule above the first), never cards. The deck list is a four-column grid on desktop (title, slides, date, tags), reflowing to two lines below 640px.
- **Audience:** max 40rem, 16px side padding, a thin condensed header under a 1px rule, content centred vertically for state messages, options stacked with 8px gaps, and a sticky full-width submit for multi-choice.
- **Rhythm:** 4 / 8 / 12px inside components, 20–24px between sections, 32px between cockpit columns.
- **Breakpoints:** 600px (compact status line, tighter segments), 640px (deck rows reflow), 760px (status line drops `next`), 900px (cockpit columns). `pointer: coarse` hides kbd chips on buttons, hides `next` in the status line, and raises small buttons to 44px and text links to 10px vertical padding.

## Elevation & Depth

Flat. There are no drop shadows. Depth is tonal: `panel` sits one step above `ground` for inputs, option cards and the status line, and `selection` marks the chosen row. Separation is drawn with 1px `rule-line` borders. The only shadow in the build is the selected option card's inset 1px amber ring, which thickens its border to 2px rather than lifting it.

### Named Rules
**The Rules Not Cards Rule.** Separate with a 1px line, not a raised or rounded container. A bordered box is reserved for controls (buttons, inputs, option cards, the run list) and the inline New deck form.

## Shapes

Square. Corners are 2px on buttons, inputs, kbd chips, checkboxes and option cards, and 0 inside segmented groups and on frames and bars. Circles appear only where they mean something: radio marks and the live status dot. The ended dot is square. Slide thumbnails sit in a 16:9 frame with a 1px outline. Result bars are 6px tracks with no rounding.

## Components

### Buttons
Standard web buttons, quiet by default.
- **Shape:** sharp (2px), 1px border, min-height 44px, padding 6px 14px; small buttons 32px (44px on coarse pointers).
- **Primary:** amber fill, on-amber text, weight 600. One per area; in the cockpit it moves to whichever of Open / Reveal results / Close voting is the next step.
- **Quiet:** transparent with a rule-line border and ink text; hover turns border and text amber. Colors transition over 0.18s.
- **Danger:** red text with a red-tinted border (45% red into the rule line); hover makes the border full red.
- **On (pressed segment):** amber border and text over the selection tint.
- **Segmented group:** buttons butted together (-1px overlap, 0 radius), the pressed one raised in z-order. Used for On screen (Slide only / QR code / Poll) and active / archived decks.
- **Disabled:** 45% opacity.

### Link Rows
Secondary actions are amber underlined text, as links (`<a>`) for navigation and as `<button>` for quiet actions (copy, resume, start new vote). Grouped in a row, they are separated by a 1px dim-sage left border and 1ch padding, so a wrapped line never starts with a stray separator. Underline is 1px, offset 0.25em, 2px on hover. A danger link is red.

### Bracket Tags
State and kind as condensed bracketed text: `[live]`, `[ended]`, `[open]`, `[single]`, `[multi]`, `[locked]`, `[archived]`. Sage at rest, green for live, red for ended, amber for warn. Adjacent tags sit 1ch apart. No pills, no fills.

### Rule Headings
Section headings render as `── Name ─────────`: a 2ch rule, the dim sage label at 0.85rem / 500, then a rule filling the row. On the results report the run question takes the heading in ink at 600.

### Kbd Chips
Shortcut hints sit inside the button they trigger: 0.8em, condensed, 1px currentColor border, 2px radius, 80% opacity. They take the button's color, so on the primary they are dark on amber. Hidden on coarse pointers. Every shortcut button also carries `aria-keyshortcuts`.

### Keyboard Shortcuts (live cockpit)
- `←` / `PgUp`: previous slide. `→` / `PgDn`: next slide.
- `o`: open the next poll on this slide. `c`: close voting. `r`: reveal or hide results.
- `q`: toggle the QR code. `s`: slide only. `p`: show the poll.
- Ignored with modifiers or while typing in a field; letter keys ignore auto-repeat. Each key is gated by the same `can` state as its button.

### Session Menu
A `details.menu` whose summary is a small quiet button (`Session`, with a drawn chevron). The pop panel lists full-width buttons: Open screen, Copy audience link, Copy screen link, Results, Export CSV, then End session in red. It closes on an outside click or Escape.

### Thumb Dock (live cockpit, below 900px)
Sticky above the status line: Prev, the next step, Next, in a 1fr / 2fr / 1fr grid of 52px buttons. The middle button is the amber fill and names the step (Open poll, Reveal results, Close voting); with no step it is disabled and says why ("No poll on this slide", "Session ended"). While the dock shows, the in-page Prev/Next row is hidden and in-page primaries turn into amber outlines, so the dock holds the only fill.

### Status Line
A tmux-style line pinned to the bottom of the cockpit: panel background, 1px top rule, condensed 0.85rem, segments separated by 1px rules. Segments: state (bold, with a round green live dot or a square red ended dot), session label (grows, then ellipsis), `slide n/N`, audience and screen connections, `voted/audience`, `next [key] step`, and an amber "reconnecting…" when the stream drops. It never wraps. It drops `next` below 760px and on touch, and switches to short labels below 600px.

### Inputs / Fields
- **Style:** panel background, 1px rule-line border, 2px radius, padding 8px 10px, min-height 40px. Labels sit above in dim sage at 0.85rem.
- **Focus:** border turns amber and the 2px amber outline sits flush (offset 0).
- **Checkbox / radio:** drawn, 18px, dim border. Checked: amber border, selection tint, amber check or dot.
- **Disabled:** 50% opacity.

### Run List
A bordered radio group (max 17rem, scrolls) choosing which run the projector shows. Each row has a 44px minimum, the question with an ellipsis, then condensed meta (`15:35 · 27 voters · voting`). The chosen row takes the selection tint.

### Bar List
Results as rows: label left, `count · pct%` right (condensed), then a 6px rule-line track with a cyan fill that scales in over 0.25s with cubic-bezier(0.16, 1, 0.3, 1). Shared by the cockpit and the results report.

### Option Card (audience)
The one place the system uses a full-width box: a panel button 56px tall, 2px radius, a 22px drawn mark (circle for single, square for multi), and a label that wraps anywhere. Hover: amber border. Selected: amber border, inset 1px amber ring, selection tint, amber dot or check. Arrow keys move focus in single choice. Multi-choice submits through a sticky 52px full-width primary.

## Do's and Don'ts

### Do:
- **Do** scope every rule under `html.term` so the projector stays untouched.
- **Do** keep one filled amber button per area, and make it the next step in the live cockpit.
- **Do** set section headings as rule headings and states as bracket tags.
- **Do** use the three widths (112.5 / 87.5 / 75%) and tabular numerals for data.
- **Do** put the kbd chip inside the button it triggers, add `aria-keyshortcuts`, and keep the button working without the key.
- **Do** format times as local 24-hour `HH:MM` and dates as `YYYY-MM-DD`.
- **Do** keep audience targets at 48px or more (option cards 56px, submit 52px) and presenter targets at 44px on touch.
- **Do** darken the semantic colors in light theme for AA rather than reusing the dark values.

### Don't:
- **Don't** use rounded white panels, pill badges or rows of equal-weight outline buttons.
- **Don't** add a fake prompt, blinking cursor or function-key bar. The terminal lends type, palette, density and the status line, not theatre.
- **Don't** use color for decoration or give a semantic color a second meaning.
- **Don't** add drop shadows or radii above 2px.
- **Don't** use a cream or warm-paper light theme.
- **Don't** apply this system to the projector (Screen.svelte, ResultsBars.svelte, app.css).

## Open Issues

Known residuals, recorded and not fixed:
- The phone header link rows (live cockpit tools, editor session actions) wrap raggedly.
- `details.menu` styles in term.css are unused.
- The `term` class is toggled in an effect in App.svelte, so the first frame may render unthemed.
- The direction contract gave widths 112 / 87 / 75. The build ships 112.5 / 87.5 / 75%, and this file records the build.
