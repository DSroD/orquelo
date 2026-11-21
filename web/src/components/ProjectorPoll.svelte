<script lang="ts">
  import { tick, untrack } from "svelte";
  import type { PollRotation, ScreenPollOverlay } from "../lib/types";
  import { projectorAdvance, projectorDwell, projectorOptions, projectorPages, type ProjectorPage } from "../lib/projector";
  import { localTime } from "../lib/time";
  import ResultsBars from "./ResultsBars.svelte";
  import Qr from "./Qr.svelte";

  let { poll, joinUrl, rotation = { paused: false, advance: 0 }, reportPage }: {
    poll: ScreenPollOverlay; joinUrl: string; rotation?: PollRotation;
    reportPage?: (open: boolean, page: number, total: number) => (() => void) | void;
  } = $props();
  let captured = $state(untrack(() => poll));
  let capturedAt = $state(new Date().toISOString());
  let pages = $state<ProjectorPage[]>([]);
  let index = $state(0);
  let laidOutOpen = $state<boolean>();
  let section: HTMLElement;
  let question: HTMLHeadingElement;
  let viewport: HTMLDivElement;
  let probe: HTMLDivElement;
  let generation = 0;
  let previousAdvance = untrack(() => rotation.advance);
  let wasOpen = untrack(() => poll.open);
  let pendingAdvance = 0;
  const rows = $derived(projectorOptions(captured.options.map((option) => ({ ...option, count: option.count ?? 0 })), captured.total_voters, captured.kind, captured.revealed));
  const denominator = $derived(Math.max(1, captured.total_voters));
  const page = $derived(pages[index]);
  const open = $derived(poll.open);
  const pageCount = $derived(pages.length);
  const displayedTotal = $derived(poll.revealed ? captured.total_voters : poll.total_voters);
  const shortUrl = $derived(joinUrl.replace(/^https?:\/\//, ""));
  const capturedTime = $derived(localTime(capturedAt));

  function capture() {
    captured = poll;
    capturedAt = new Date().toISOString();
  }

  async function layout() {
    const current = ++generation;
    await tick();
    if (current !== generation || !viewport || !probe) return;
    question.style.removeProperty("font-size");
    const heights = Array.from(probe.querySelectorAll("li"), (element) => element.getBoundingClientRect().height);
    const tallest = Math.max(0, ...heights);
    let size = parseFloat(getComputedStyle(question).fontSize);
    while (tallest > viewport.clientHeight && size > 20) {
      size = Math.max(20, size - 2);
      question.style.fontSize = `${size}px`;
    }
    pages = projectorPages(rows, heights, viewport.clientHeight, 16, captured.revealed);
    index = Math.min(index, Math.max(0, pages.length - 1));
    laidOutOpen = captured.open;
    if (pendingAdvance) {
      const count = pendingAdvance;
      pendingAdvance = 0;
      forward(count);
    }
  }

  function forward(count = 1) {
    const next = projectorAdvance(0, count, index, pages.length);
    index = next.index;
    if (next.wrapped) capture();
  }

  $effect(() => {
    const open = poll.open;
    untrack(() => {
      if (wasOpen && !open) {
        index = 0;
        pendingAdvance = 0;
        previousAdvance = rotation.advance;
      }
      if (open !== wasOpen || pages.length <= 1) capture();
      wasOpen = open;
    });
  });
  $effect(() => {
    rows;
    untrack(() => { void layout(); });
  });
  $effect(() => {
    const observer = new ResizeObserver(() => { void layout(); });
    observer.observe(section);
    observer.observe(viewport);
    return () => { generation++; observer.disconnect(); };
  });
  $effect(() => {
    const advance = rotation.advance;
    untrack(() => {
      const delta = Math.max(0, advance - previousAdvance);
      previousAdvance = advance;
      if (delta && pages.length) forward(delta);
      else pendingAdvance += delta;
    });
  });
  $effect(() => {
    if (rotation.paused || pages.length <= 1 || !page) return;
    const timer = setTimeout(() => forward(), projectorDwell(captured.question, page.options, index === 0));
    return () => clearTimeout(timer);
  });
  $effect(() => {
    // Report geometry for this view once the same snapshot has been laid out.
    if (pageCount && laidOutOpen === open) return reportPage?.(open, index + 1, pageCount);
  });
</script>

<section class="results" bind:this={section}>
  <h1 bind:this={question}>{poll.question}</h1>
  <div class="body">
    <div class="view-label">
      {#if page?.leaders}Leading answers · {page.options.length} shown{#if page.cutoffTies} · {page.cutoffTies} more tied at #{page.options.at(-1)?.rank}{/if}
      {:else if poll.revealed && captured.total_voters === 0}No votes yet
      {:else if pages.length > 1}{poll.revealed ? "Results" : "Answers"}{/if}
    </div>
    <div class="answers" bind:this={viewport}>
      {#if page}<ResultsBars options={page.options} revealed={poll.revealed} {denominator} />{/if}
      <div class="probe" aria-hidden="true" bind:this={probe}><ResultsBars options={rows} revealed={poll.revealed} {denominator} /></div>
    </div>
  </div>
  <footer>
    <div class="status">
      <span>{displayedTotal} {poll.revealed ? (displayedTotal === 1 ? "vote" : "votes") : "voted"} · {captured.open ? "voting open" : "voting closed"}{poll.kind === "multi" ? " · multiple choice" : ""}</span>
      <span class="rotation-meta">{#if pages.length > 1}View {index + 1} / {pages.length}{rotation.paused ? " · paused" : ""}{poll.revealed && (poll.open || captured.open) ? ` · Results as of ${capturedTime}` : ""}{/if}</span>
    </div>
    {#if !poll.revealed}<span class="join"><Qr url={joinUrl} size={120} /><span class="joinurl">{shortUrl}</span></span>{/if}
  </footer>
</section>

<style>
  .results { position: absolute; inset: 0; background: rgba(6,10,18,0.94); color: #fff; display: grid; grid-template-rows: auto minmax(0,1fr) auto; gap: 12px; padding: 24px 4vw; overflow: hidden; }
  h1 { margin: 0; font-size: clamp(24px,4vh,40px); line-height: 1.2; overflow-wrap: anywhere; }
  .body { min-height: 0; display: grid; grid-template-rows: auto minmax(0,1fr); gap: 10px; }
  .view-label { min-height: 24px; font-size: 18px; line-height: 1.3; color: #b9d9ec; }
  .answers { min-height: 0; position: relative; }
  .probe { position: absolute; top: 0; left: 0; width: 100%; height: 0; overflow: hidden; visibility: hidden; pointer-events: none; }
  footer { font-size: clamp(16px,2.3vh,24px); display: flex; justify-content: space-between; align-items: flex-end; gap: 16px; }
  .status { display: grid; gap: 4px; }
  .rotation-meta { min-height: 1.4em; }
  .join { display: flex; align-items: center; gap: 12px; background: #fff; color: #000; padding: 6px; border-radius: 12px; }
  .join :global(img) { width: clamp(64px,9vh,96px); height: auto; }
  .joinurl { font-weight: 700; font-size: clamp(14px,2vh,20px); overflow-wrap: anywhere; max-width: 22ch; }
</style>
