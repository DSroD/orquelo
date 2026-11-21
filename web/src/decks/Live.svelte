<script lang="ts">
  import { ApiError, post } from "../lib/api";
  import { actions } from "../lib/actions.svelte";
  import { useResource } from "../lib/resource.svelte";
  import { useStream } from "../lib/session.svelte";
  import { clampSlide, cockpit, type Choice, type Step } from "../lib/cockpit";
  import { handleShortcut, readLetterKeys, saveLetterKeys, type Shortcuts } from "../lib/shortcuts";
  import { slug } from "../lib/slug";
  import type { ModeratorSnapshot, Poll, Presentation, SessionSnapshot } from "../lib/types";
  import Crumbs from "../components/Crumbs.svelte";
  import CopyButton from "../components/CopyButton.svelte";
  import AddOption from "./live/AddOption.svelte";
  import QAPanel from "./live/QAPanel.svelte";
  import BarList from "../components/BarList.svelte";
  import Dock from "./live/Dock.svelte";
  import PollRow from "./live/PollRow.svelte";
  import RotationControls from "./live/RotationControls.svelte";
  import ScreenPanel from "./live/ScreenPanel.svelte";
  import SessionMenu from "./live/SessionMenu.svelte";
  import SlidesPanel from "./live/SlidesPanel.svelte";
  import StatusLine from "./live/StatusLine.svelte";
  import VotePanel from "./live/VotePanel.svelte";

  let { code }: { code: string } = $props();
  const s = useStream<SessionSnapshot>(() => `/api/sessions/${code}/stream`, () => `/api/sessions/${code}/results`);
  const session = $derived(s.snap);
  const snap = $derived(session?.stage ? session as ModeratorSnapshot : null);
  const ended = $derived(s.phase === "ended" || !!session?.session.ended_at);

  const pid = $derived(session?.presentation.id);
  const deck = useResource<Presentation & { polls: Poll[] }>(() => pid ? `/api/decks/${pid}` : null);
  const polls = $derived((deck.data?.polls ?? []).filter((pl) => pl.archived_at === null));
  // the deck can be edited in another tab while this one stays open
  $effect(() => {
    const stale = () => { if (!document.hidden) deck.reload(); };
    document.addEventListener("visibilitychange", stale);
    window.addEventListener("focus", stale);
    return () => { document.removeEventListener("visibilitychange", stale); window.removeEventListener("focus", stale); };
  });

  const a = actions({ onError: (e) => { if (e instanceof ApiError && e.error === "poll_archived") deck.reload(); } });
  const act = (path: string, body?: unknown, key = path) => a.run(key, () => post(`/api/sessions/${code}/${path}`, body));
  const stage = (path: string, body?: unknown) => act(path, body, "stage");
  const c = $derived(cockpit(snap, polls, ended, s.connected, a.is));
  const screenPages = $derived(snap?.screen_pages ?? []);
  const hasRotation = $derived(!ended && c.overlay?.type === "poll" && screenPages.some(({ total }) => total > 1));
  const rotationStatus = $derived(screenPages.length === 1
    ? `View ${screenPages[0].page} / ${screenPages[0].total}`
    : "Pages vary by screen");
  const actionQuestion = $derived(c.nextStep === "open" ? c.nextOpen?.question : c.nextStep ? c.cur?.question : undefined);
  let letterKeys = $state(readLetterKeys());

  function setLetterKeys(enabled: boolean) {
    letterKeys = enabled;
    saveLetterKeys(enabled);
  }

  const go = (n: number) => {
    if (!snap || ended) return;
    const t = clampSlide(n, snap.presentation.page_count);
    if (t !== c.slide) void act("slide", { slide: t });
  };
  const showRun = (run_id: number) => stage("overlay", { overlay: { type: "poll", run_id } });
  const showQA = (question_id: number | null) => stage("overlay", { overlay: { type: "qa", question_id } });
  function choose(ch: Choice) {
    if (!c.can.overlay || ch === c.choice) return;
    if (ch === "none") void stage("overlay", { overlay: null });
    else if (ch === "qr") void stage("overlay", { overlay: { type: "qr" } });
    else if (ch === "qa") void showQA(null);
    else if (c.can.poll) void showRun(c.pollTarget!);
  }
  const showCurrent = () => { if (c.can.show) void showRun(c.cur!.run_id); };
  const closePoll = () => { if (c.can.close) void stage("poll/close", { run_id: c.cur!.run_id }); };
  function toggleReveal() {
    if (!c.can.reveal || c.overlay?.type !== "poll") return;
    void stage(c.overlay.revealed ? "poll/hide" : "poll/reveal", { run_id: c.overlay.run_id });
  }
  function rotate(action: "pause" | "resume" | "next") {
    if (!c.can.reveal || c.overlay?.type !== "poll") return;
    void stage("poll/rotation", { run_id: c.overlay.run_id, revealed: c.overlay.revealed, action });
  }
  const openPoll = (poll_id: number) => { if (c.canStart) void stage("poll/open", { poll_id, only_if_idle: true }); };
  const resumePoll = (run_id: number) => { if (c.canStart) void stage("poll/resume", { run_id }); };
  function runStep(st: Step) {
    if (st === "open") { if (c.can.open) void openPoll(c.nextOpen!.id); }
    else if (st === "show") showCurrent();
    else if (st === "reveal") { if (c.liveOnScreen) toggleReveal(); }
    else closePoll();
  }
  const shortcuts: Shortcuts = {
    ArrowRight: [() => c.can.next, () => go(c.slide + 1)], PageDown: [() => c.can.next, () => go(c.slide + 1)],
    ArrowLeft: [() => c.can.prev, () => go(c.slide - 1)], PageUp: [() => c.can.prev, () => go(c.slide - 1)],
    o: [() => c.can.open, () => void openPoll(c.nextOpen!.id)],
    c: [() => c.can.close, closePoll],
    r: [() => c.can.reveal && c.liveOnScreen, toggleReveal],
    q: [() => c.can.overlay, () => choose(c.choice === "qr" ? "none" : "qr")],
    s: [() => c.can.overlay, () => choose("none")],
    p: [() => c.can.poll, () => c.can.show ? showCurrent() : choose("poll")],
  };
  const error = $derived(a.error || deck.error);
</script>

<svelte:window onkeydown={(e) => { if (snap) handleShortcut(e, shortcuts, letterKeys); }} />
<svelte:head><title>{snap ? `Live · ${snap.session.label || snap.presentation.title}` : "Live"} · Orquelo</title></svelte:head>

{#snippet rotationControls()}
  <RotationControls status={rotationStatus} paused={snap?.stage.rotation?.paused ?? false} disabled={!c.can.reveal} onrotate={rotate} />
{/snippet}

<div class="live-root">
<div class="live-scroll">
<div class="page">
  {#if !session}
    <p class="muted">{s.phase === "missing" ? "Session not found." : s.phase === "forbidden" ? "You need edit or moderate permission on this deck to access its sessions." : "Connecting…"}</p>
  {:else if !snap}
    <Crumbs trail={[{ label: "~ / decks", href: "/decks" }, { label: slug(session.presentation.title), href: `/decks/${session.presentation.id}` }, { label: slug(session.session.label || "Session") }]} />
    <h1>{session.session.label || "Session"} <span class="tag">{ended ? "ended" : "editor"}</span></h1>
    <p class="muted">You can add answers to eligible votes. Session controls and the Q&A inbox require moderation permission.</p>
    <section class="stack" aria-labelledby="editor-vote-h">
      <h2 id="editor-vote-h" class="rule">Current vote</h2>
      {#if session.open_run}
        <h3>{session.open_run.question}</h3>
        <BarList options={session.open_run.options} total={session.open_run.total_voters} kind={session.open_run.kind} />
        {#if session.open_run.allow_additional_answers}
          {#key session.open_run.run_id}<AddOption {code} run={session.open_run} {ended} />{/key}
        {:else}<p class="muted">Additional answers are disabled for this poll.</p>{/if}
      {:else}<p class="muted">No vote is running.</p>{/if}
    </section>
    {#if !s.connected}<p class="err" role="status">Reconnecting…</p>{/if}
  {:else}
    {@const pdf = `/api/decks/${snap.presentation.id}/pdf`}
    {@const name = snap.session.label || "Session"}
    <div class="session-path">
      <Crumbs trail={[{ label: "~ / decks", href: "/decks" }, { label: slug(snap.presentation.title), href: `/decks/${snap.presentation.id}` }, { label: slug(name) }]} />
    </div>
    <header class="bar between head">
      <h1>{name}</h1>
      <SessionMenu {code} screenUrl={snap.screen_url} audienceUrl={snap.audience_url} {ended} ending={a.is("end")} canResults={deck.data?.access.results ?? false}
        {letterKeys} onletterkeys={setLetterKeys} onend={() => act("end")} />
    </header>
    {#if error}<p class="err" role="alert">{error}</p>{/if}

    <div class="cockpit">
      <section class="stack slides" aria-labelledby="slides-h">
        <h2 id="slides-h" class="rule">Slides</h2>
        <SlidesPanel {pdf} slide={c.slide} pageCount={snap.presentation.page_count} canPrev={c.can.prev} canNext={c.can.next} ongo={go} />
      </section>

      <div class="right">
        <section class="stack screen" aria-labelledby="screen-h">
          <h2 id="screen-h" class="rule">On screen</h2>
          {#if !ended && snap.connections.screen === 0}
            <div class="setup">
              <p class="muted">No projector connected</p>
              <div class="bar">
                <a class="btn sm" href={snap.screen_url} target="_blank" rel="noopener">Open screen</a>
                <CopyButton cls="btn sm" text={snap.audience_url} label="Copy audience link" />
              </div>
            </div>
          {/if}
          <ScreenPanel runs={snap.runs} overlay={c.overlay} choice={c.choice} pollTarget={c.pollTarget} qaEnabled={snap.qa.enabled} can={c.can} nextStep={c.nextStep}
            liveOnScreen={c.liveOnScreen} {letterKeys} onchoose={choose} ontogglereveal={toggleReveal} onshowrun={showRun} onshowcurrent={showCurrent}>
            {#snippet controls()}{#if hasRotation}<div class="rotation-desktop">{@render rotationControls()}</div>{/if}{/snippet}
          </ScreenPanel>
        </section>

        <section class="stack vote" aria-labelledby="vote-h">
          <h2 id="vote-h" class="rule">Voting</h2>
          <VotePanel cur={c.cur} overlay={c.overlay} canClose={c.can.close} primary={c.nextStep === "close"} {letterKeys} onclose={closePoll} />
          {#if deck.data?.access.edit && c.cur?.allow_additional_answers}
            {#key c.cur.run_id}<AddOption {code} run={c.cur} {ended} />{/key}
          {/if}
        </section>

      </div>
      <section class="stack polls-sec" aria-labelledby="polls-h">
        <h2 id="polls-h" class="rule">Polls</h2>
        {#if c.cur && !ended && (c.slidePolls.length || c.anyPolls.length)}
          <p class="muted">Close the current vote before opening another poll.</p>
        {/if}
        {#each [["This slide", c.slidePolls], ["Any slide", c.anyPolls]] as [name, list] (name)}
          {#if (list as Poll[]).length}
            <h3>{name}</h3>
            <ul class="polls">
              {#each list as Poll[] as pl (pl.id)}
                {@const first = c.nextOpen?.id === pl.id}
                <PollRow poll={pl} shortcut={first && letterKeys && !c.cur} primary={first && c.nextStep === "open"}
                  hasRun={c.hasRun(pl)} resumable={c.resumable} canStart={c.canStart} onopen={openPoll} onresume={resumePoll} />
              {/each}
            </ul>
          {/if}
        {/each}
        {#if !c.slidePolls.length && !c.anyPolls.length}<p class="muted">No polls for this slide.</p>{/if}
      </section>
      {#if snap.qa.enabled}<div class="qa-sec"><QAPanel {code} qa={snap.qa} overlay={c.overlay} {ended} canShow={c.can.overlay} onshow={showQA} /></div>{/if}
    </div>
  {/if}
</div>
</div>

{#if snap}
  <div class="bottom">
    {#if hasRotation}
      <div class="rotation-mobile">{@render rotationControls()}</div>
    {/if}
    <Dock canPrev={c.can.prev} canNext={c.can.next} step={c.nextStep} canStep={c.nextStep !== null && c.can[c.nextStep]} idleLabel={c.idleLabel} {letterKeys} question={actionQuestion}
      onprev={() => go(c.slide - 1)} onnext={() => go(c.slide + 1)} onstep={() => c.nextStep && runStep(c.nextStep)} />
    <StatusLine {ended} label={snap.session.label || "Session"} slide={c.slide} pageCount={snap.presentation.page_count}
      connections={snap.connections} cur={c.cur} nextStep={c.nextStep} connected={s.connected} {letterKeys} />
  </div>
{/if}
</div>

<style>
  .head { flex-wrap: nowrap; align-items: flex-start; }
  .head h1 { min-width: 0; }
  :global(#app:has(> #page-content > .live-root)) { display: grid; grid-template-rows: auto minmax(0, 1fr); height: 100dvh; }
  .live-root { height: 100%; display: flex; flex-direction: column; }
  .live-scroll { flex: 1; min-height: 0; overflow: auto; scroll-padding-block: 8px; }
  .bottom { flex: none; }
  .bottom :global(.statusline) { position: static; }
  .setup { display: grid; gap: 6px; border: 1px solid var(--line); padding: 8px 12px; }
  .rotation-mobile { display: none; }
  @media (max-width: 899px) {
    .rotation-desktop { display: none; }
    .rotation-mobile { display: block; padding: 6px 16px; background: var(--bg); border-top: 1px solid var(--line); }
    /* the run view on a phone: the in-page primaries go quiet next to the dock's */
    .cockpit :global(.btn.primary) { background: transparent; border-color: var(--amber); color: var(--amber); }
    .screen :global(.seg) { display: flex; width: 100%; }
    .screen :global(.seg .btn) { flex: 1; justify-content: center; min-height: 48px; }
    .session-path :global([aria-current]), .session-path :global(.sep:has(+ [aria-current])) { display: none; }
  }
  .cockpit { display: grid; gap: 24px; grid-template-columns: minmax(0, 1fr); padding-bottom: 24px; }
  .right { display: contents; }
  .qa-sec { order: 5; min-width: 0; }
  .slides { order: 1; } .screen { order: 2; } .vote { order: 3; } .polls-sec { order: 4; }
  .cockpit :is(.slides, .vote, .screen, .polls-sec) { min-width: 0; }
  @media (min-width: 900px) {
    .cockpit { grid-template-columns: minmax(0, 3fr) minmax(0, 2fr); grid-template-rows: auto 1fr; grid-template-areas: "slides right" "polls right"; align-items: start; gap: 24px 32px; }
    .qa-sec { grid-column: 1 / -1; }
    .right { grid-area: right; display: grid; grid-template-columns: minmax(0, 1fr); gap: 24px; align-content: start; min-width: 0; }
    .slides { grid-area: slides; order: 0; } .polls-sec { grid-area: polls; order: 0; }
    .screen { order: 1; } .vote { order: 2; }
  }
  h3 { margin-top: 12px; }
  .polls { list-style: none; margin: 0; padding: 0; }

  @media (max-width: 600px) {
    .screen :global(.seg .btn) { padding-inline: 8px; }
    .screen :global(.seg .btn kbd) { display: none; }
  }
</style>
