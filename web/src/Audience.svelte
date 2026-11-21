<script lang="ts">
  import { untrack } from "svelte";
  import { ApiError, post } from "./lib/api";
  import { pending } from "./lib/pending.svelte";
  import { useStream } from "./lib/session.svelte";
  import type { AudienceSnapshot, VoteResponse } from "./lib/types";
  import Tabs from "./components/Tabs.svelte";
  import CookieSettings from "./audience/CookieSettings.svelte";
  import QA from "./audience/QA.svelte";
  import OptionCard from "./components/OptionCard.svelte";

  let { pid, code }: { pid: number; code: string } = $props();
  const s = useStream<AudienceSnapshot>(() => `/api/s/${pid}/${code}/stream?role=audience`, () => `/api/s/${pid}/${code}`);

  const poll = $derived(s.snap?.poll ?? null);
  const ballotKey = (ids: number[] | null | undefined) => [...(ids ?? [])].sort((a, b) => a - b).join(",");
  const voteKey = $derived(ballotKey(s.snap?.my_vote));
  let receipt = $state<{ runId: number; previous: string[]; ids: number[] } | null>(null);
  const pendingReceipt = $derived(receipt?.runId === poll?.run_id && receipt?.previous.includes(voteKey) ? receipt : null);
  const voted = $derived(pendingReceipt?.ids ?? s.snap?.my_vote ?? null);
  const multi = $derived(poll?.kind === "multi");
  let activity = $state<"poll" | "qa">("poll");
  const hasQA = $derived(!!s.snap?.qa?.enabled && s.snap.qa.started);
  const exclusivePicked = $derived(poll?.options.some((o) => o.exclusive && picked.includes(o.id)) ?? false);
  const blocked = (o: { id: number; exclusive: boolean }) => multi && !picked.includes(o.id) && (exclusivePicked || (o.exclusive && picked.length > 0));

  let picked = $state<number[]>([]);
  let focused = $state<number | null>(null);
  const tabStop = $derived(poll?.options.find((o) => o.id === focused)?.id ?? picked[0] ?? poll?.options[0]?.id);
  const pend = pending();
  const busy = $derived(pend.is(`vote:${poll?.run_id}`));
  let error = $state("");

  $effect(() => {
    if (!pendingReceipt) receipt = null;
    else {
      const seen = pendingReceipt.previous.lastIndexOf(voteKey);
      if (seen > 0) receipt = { ...pendingReceipt, previous: pendingReceipt.previous.slice(seen) };
    }
  });

  // Re-seed the local selection when the run or the server's record of my vote changes.
  const seedKey = $derived(`${poll?.run_id ?? ""}:${ballotKey(voted)}`);
  $effect(() => {
    seedKey;
    picked = untrack(() => [...(voted ?? [])]);
    error = "";
  });

  const dirty = $derived(
    picked.length > 0 && (picked.length !== (voted?.length ?? 0) || picked.some((id) => !voted?.includes(id))),
  );

  function submit(ids: number[]) {
    if (!poll?.open) return;
    const id = poll.run_id;
    void pend.run(`vote:${id}`, () => send(id, ids));
  }
  async function send(runId: number, ids: number[]) {
    const previous = pendingReceipt ? [...pendingReceipt.previous, ballotKey(pendingReceipt.ids)] : [voteKey];
    error = "";
    try {
      const vote = await post<VoteResponse>(`/api/s/${pid}/${code}/vote`, { run_id: runId, option_ids: ids });
      if (closed && closed.runId === vote.run_id) closed = { ...closed, outcome: "voted" };
      // A successful response can overtake snapshots for this and earlier ballots.
      const seen = previous.lastIndexOf(voteKey);
      if (poll?.run_id === vote.run_id && seen !== -1) {
        receipt = { runId: vote.run_id, previous: previous.slice(seen), ids: vote.option_ids };
      }
    } catch (e) {
      if (poll?.run_id !== runId) return;
      error = e instanceof ApiError && e.error === "poll_not_open"
        ? "Voting just closed."
        : "Couldn’t send your vote. Try again.";
    }
  }

  // Remember the poll that just disappeared so the phone says "voting closed" instead of silently going idle.
  type Closed = { runId: number; question: string; outcome: "voted" | "unchanged" | "unsent" | "none" };
  let closed = $state<Closed | null>(null);
  let last: Closed | null = null;
  $effect(() => {
    if (poll) {
      last = { runId: poll.run_id, question: poll.question, outcome: voted ? (dirty ? "unchanged" : "voted") : picked.length ? "unsent" : "none" };
      closed = null;
    } else if (last) { closed = last; last = null; }
  });

  // Moving focus never casts a vote. Enter, Space and taps activate the answer.
  function arrows(e: KeyboardEvent) {
    const step = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
    if (!step) return;
    const cards = [...(e.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button:not(:disabled)")];
    const i = cards.indexOf(document.activeElement as HTMLButtonElement);
    if (i < 0) return;
    e.preventDefault();
    cards[(i + step + cards.length) % cards.length].focus();
  }

  function leaveOptions(e: FocusEvent) {
    if (!(e.relatedTarget instanceof Node) || !(e.currentTarget as HTMLElement).contains(e.relatedTarget)) focused = null;
  }

  function tap(id: number) {
    if (!poll?.open) return;
    if (multi) picked = picked.includes(id) ? picked.filter((x) => x !== id) : [...picked, id];
    else { picked = [id]; if (!voted?.includes(id)) submit([id]); }
  }
</script>

<svelte:head><title>{s.snap ? `${s.snap.presentation.title} · Orquelo` : "Orquelo"}</title></svelte:head>

<main>
  {#if s.phase === "ended"}
    <section class="center"><h1>This session has ended</h1><p class="muted">Thanks for taking part.</p></section>
  {:else if s.phase === "missing"}
    <section class="center"><h1>Link not valid</h1><p class="muted">Ask your presenter for the current link.</p></section>
  {:else if s.phase === "full"}
    <section class="center" role="status"><h1>This session is full</h1><p class="muted">Keep this page open to join when a seat becomes available.</p></section>
  {:else if !s.snap}
    <section class="center"><p class="muted">Connecting…</p></section>
  {:else}
    <header>
      <span class="title">{s.snap.presentation.title}{s.snap.session.label ? ` · ${s.snap.session.label}` : ""}</span>
      <span class="offline" role="status">{s.connected ? "" : "Reconnecting…"}</span>
    </header>

    {#if hasQA}
      <Tabs tabs={["poll", "qa"] as const} bind:selected={activity} label="Activity">
        {#snippet tab(t)}{t === "poll" ? "Poll" : "Q&A"}{/snippet}
      </Tabs>
    {/if}
    <div class="activity" role={hasQA ? "tabpanel" : undefined} id="panel-poll" aria-labelledby={hasQA ? "tab-poll" : undefined} hidden={hasQA && activity !== "poll"}>
    {#if !poll && closed}
      <section class="center" role="status">
        <h1>Voting closed</h1>
        <p class="q">{closed.question}</p>
        <p class="muted">
          {#if closed.outcome === "voted"}Your vote was recorded.
          {:else if closed.outcome === "unchanged"}Your previous vote was recorded. Your changes weren’t sent.
          {:else if closed.outcome === "unsent"}Your selection wasn’t recorded.
          {:else}You didn't vote this time.{/if}
          Watch the screen for results.
        </p>
      </section>
    {:else if !poll}
      <section class="center"><h1>Nothing to answer right now</h1><p class="muted">Follow the screen. A question will appear here when the presenter opens one.</p></section>
    {:else}
      <section class="poll">
        <h1 dir="auto">{poll.question}</h1>
        <p class="hint" class:ok={voted && !busy} aria-live="polite">
          {#if busy}Sending vote…
          {:else if voted}Vote recorded{multi ? " · change it below if you like" : " · choose another option to change"}
          {:else}{multi ? "Choose all that apply" : "Choose one"}{/if}
        </p>
        {#if multi && poll.options.some((o) => o.exclusive)}<p class="muted exclusive-hint">Answers marked “select alone” cannot be combined. Deselect your current choices to switch.</p>{/if}
        {#if !multi}<p class="sr" id="single-vote-keys">Use the arrow keys to browse. Press Enter or Space to vote.</p>{/if}
        <div class="opts" role={multi ? "group" : "radiogroup"} aria-label={poll.question} aria-describedby={multi ? undefined : "single-vote-keys"} onkeydown={multi ? undefined : arrows}
          onfocusout={multi ? undefined : leaveOptions}>
          {#each poll.options as o (o.id)}
            <OptionCard label={o.exclusive ? `${o.label} · select alone` : o.label} {multi} selected={picked.includes(o.id)} {busy}
              disabled={!poll.open || blocked(o)} tabindex={multi ? undefined : o.id === tabStop ? 0 : -1}
              onfocus={multi ? undefined : () => { focused = o.id; }} onclick={() => tap(o.id)} />
          {/each}
        </div>
      </section>

      {#if poll.open && (multi || error)}
        <div class="sticky">
          <p class="err" role="alert">{error}</p>
          {#if multi || dirty}
            <button class="btn primary" disabled={!dirty || busy} onclick={() => submit(picked)}>
              {busy ? "Sending…" : error ? "Retry vote" : voted ? "Change vote" : "Submit"}{multi && picked.length ? ` (${picked.length})` : ""}
            </button>
          {/if}
        </div>
      {/if}
    {/if}
    </div>
    {#if hasQA && s.snap.qa}
      <div class="activity" role="tabpanel" id="panel-qa" aria-labelledby="tab-qa" hidden={activity !== "qa"}><QA {pid} {code} qa={s.snap.qa} /></div>
    {/if}
    <footer><CookieSettings prompt /></footer>
  {/if}
</main>

<style>
  main { max-width: 40rem; margin: 0 auto; padding: 0 16px; min-height: 100dvh; display: flex; flex-direction: column; }
  header { display: flex; justify-content: space-between; gap: 8px; padding: 12px 0; margin-bottom: 8px; border-bottom: 1px solid var(--line); font-size: 0.85rem; font-stretch: 75%; color: var(--dim); }
  footer { border-top: 1px solid var(--line); padding-bottom: env(safe-area-inset-bottom); }
  .activity { flex: 1; display: flex; flex-direction: column; padding-top: 12px; }
  .activity[hidden] { display: none; }
  .exclusive-hint { font-size: 0.85rem; }
  .title { overflow-wrap: anywhere; }
  .offline { color: var(--red); flex: none; }
  .center { flex: 1; display: flex; flex-direction: column; justify-content: center; gap: 12px; padding-bottom: 20vh; }
  .poll { flex: 1; padding-bottom: 24px; display: grid; gap: 12px; align-content: start; }
  h1 { font-size: clamp(1.1rem, 5vw, 1.5rem); }
  .q { font-weight: 600; }
  .hint { color: var(--dim); font-stretch: 75%; }
  .hint.ok { color: var(--green); }
  .opts { display: flex; flex-direction: column; gap: 8px; }
  .sticky {
    position: sticky; bottom: 0; margin: 0 -16px; padding: 12px 16px calc(12px + env(safe-area-inset-bottom));
    background: var(--bg); border-top: 1px solid var(--line);
  }
  .sticky .btn { width: 100%; min-height: 52px; justify-content: center; font-size: 1rem; }
  .sticky .err:not(:empty) { margin-bottom: 8px; }
</style>
