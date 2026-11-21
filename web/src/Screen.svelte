<script lang="ts">
  import { untrack } from "svelte";
  import { useStream } from "./lib/session.svelte";
  import { assertNever } from "./lib/exhaustive";
  import type { ScreenSnapshot } from "./lib/types";
  import ScreenQuestion from "./components/ScreenQuestion.svelte";
  import PdfSlide from "./components/PdfSlide.svelte";
  import ProjectorPoll from "./components/ProjectorPoll.svelte";
  import Qr from "./components/Qr.svelte";

  let { pid, code }: { pid: number; code: string } = $props();
  const viewer = Array.from(crypto.getRandomValues(new Uint32Array(4)), (n) => n.toString(16).padStart(8, "0")).join("");
  const url = $derived(`/api/screen/${pid}/${code}`);
  const s = useStream<ScreenSnapshot>(() => `${url}/stream?viewer=${viewer}`, () => url);
  const snap = $derived(s.snap);
  const overlay = $derived(snap?.stage.overlay ?? null);
  const shortUrl = $derived(snap?.join_url.replace(/^https?:\/\//, "") ?? "");
  const rotation = $derived(snap?.stage.rotation);
  let reports = Promise.resolve();

  function reportPage(open: boolean, page: number, total: number) {
    if (!s.connected) return;
    const poll = untrack(() => overlay);
    if (poll?.type !== "poll") return;
    const endpoint = `${url}/page`;
    const body = JSON.stringify({ viewer, run_id: poll.run_id, revealed: poll.revealed, open, page, total });
    let superseded = false;
    // Keep requests from this projector in order and skip measurements that are already obsolete.
    reports = reports.then(async () => {
      for (let attempt = 0; attempt < 2 && !superseded; attempt++) {
        try {
          const response = await fetch(endpoint, {
            method: "POST", headers: { "Content-Type": "application/json" }, body, signal: AbortSignal.timeout(5000),
          });
          if (response.status < 500) return;
        } catch { /* retry a failed measurement once */ }
      }
    });
    return () => { superseded = true; };
  }
</script>

<svelte:head><title>{snap ? `${snap.presentation.title} · screen` : "Screen"} · Orquelo</title></svelte:head>

<div class="stage">
  {#if s.phase !== "live"}
    <div class="msg"><h1>{s.phase === "ended" ? "This session has ended" : "Link not valid"}</h1></div>
  {:else if !snap}
    <div class="msg"><p>Connecting…</p></div>
  {:else}
    <PdfSlide url={`/api/screen/${pid}/${code}/slides.pdf`} page={snap.stage.slide} />

    {#if overlay}
      {#if overlay.type === "poll"}
        {#key `${overlay.run_id}:${overlay.revealed}`}
          <ProjectorPoll poll={overlay} joinUrl={snap.join_url} {rotation} {reportPage} />
        {/key}
      {:else if overlay.type === "qa"}
        <section class="qa-screen">
          <h1>Q&A</h1>
          {#if overlay.question}
            <ScreenQuestion text={overlay.question.text} />
          {:else}
            <div class="qa-invitation"><h2>{overlay.open ? "What would you like to ask?" : "Questions & answers"}</h2><p>{overlay.open ? "Open the Q&A tab on your phone to send a question." : "Follow along as we discuss your questions."}</p></div>
          {/if}
          <footer><span>{overlay.open ? "Questions welcome" : "Submissions closed"}</span><span class="join"><Qr url={snap.join_url} size={120} /><span class="joinurl">{shortUrl}</span></span></footer>
        </section>
      {:else if overlay.type === "qr"}
        <div class="qr">
          <div class="card">
            <Qr url={snap.join_url} size={420} />
            <p class="url">{shortUrl}</p>
          </div>
        </div>
      {:else}
        {@const _ = assertNever(overlay)}
      {/if}
    {/if}
    {#if !s.connected}<div class="offline">Reconnecting…</div>{/if}
  {/if}
</div>

<style>
  .stage { position: fixed; inset: 0; background: #000; color: #fff; overflow: hidden; cursor: none; }
  .msg { height: 100%; display: grid; place-items: center; text-align: center; font-size: clamp(1.5rem, 4vw, 3rem); }
  h1 { margin: 0; font-size: clamp(1.4rem, 5vh, 3.2rem); overflow-wrap: anywhere; display: -webkit-box; -webkit-line-clamp: 3; line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
  footer { font-size: clamp(0.9rem, 2.4vh, 1.5rem); opacity: 0.85; display: flex; justify-content: space-between; align-items: flex-end; gap: 1rem; }
  .join { display: flex; align-items: center; gap: 0.75rem; background: #fff; color: #000; padding: 0.4rem 0.75rem 0.4rem 0.4rem; border-radius: 12px; }
  .join :global(img) { width: clamp(64px, 13vh, 120px); height: auto; }
  .joinurl { font-weight: 700; font-size: clamp(0.8rem, 2vh, 1.2rem); overflow-wrap: anywhere; max-width: 22ch; }
  .qa-screen { position: absolute; inset: 0; display: grid; grid-template-rows: auto minmax(0, 1fr) auto; gap: 3vh; padding: clamp(1rem, 4vh, 3rem) clamp(1.5rem, 5vw, 5rem); background: rgba(6, 10, 18, 0.96); overflow: hidden; }
  .qa-invitation { align-self: center; max-width: 36ch; }
  .qa-invitation h2 { font-size: clamp(1.5rem, 6vh, 4rem); line-height: 1.2; }
  .qa-invitation p { font-size: clamp(1rem, 3vh, 2rem); margin-top: 1em; }
  .qr { position: absolute; inset: 0; display: grid; place-items: center; background: rgba(0, 0, 0, 0.6); }
  .card { background: #fff; color: #000; padding: clamp(1rem, 3vh, 2rem); border-radius: 20px; text-align: center; max-width: 90vw; max-height: 92vh; display: flex; flex-direction: column; align-items: center; }
  .card :global(img) { max-height: 68vh; width: auto; }
  .url { margin: 0.6em 0 0; font-size: clamp(1.1rem, 3.2vh, 2.2rem); font-weight: 700; overflow-wrap: anywhere; }
  .offline { position: absolute; top: 8px; right: 12px; font-size: 0.9rem; opacity: 0.7; }
</style>
