<script lang="ts">
  import { ApiError, post } from "../lib/api";
  import { useResource } from "../lib/resource.svelte";
  import SegToggle from "../components/SegToggle.svelte";
  import { pageCountOf } from "../lib/pdf";
  import { localDate } from "../lib/time";
  import { navigate } from "../lib/router";
  import { accessTag } from "../lib/accessTag";
  import { limitMessage, mb, tooLargeMessage, usage } from "../lib/quota";
  import type { Me, Presentation, PresentationListItem } from "../lib/types";

  let { me }: { me: Me } = $props();
  let archived = $state(false);
  let uploadError = $state("");
  let title = $state("");
  let file = $state<File | null>(null);
  let uploading = $state(false);
  let creating = $state(false);

  const res = useResource<PresentationListItem[]>(() => `/api/decks${archived ? "?archived=1" : ""}`);
  const items = $derived(res.data ?? []);
  const loaded = $derived(res.data !== null);
  const error = $derived(uploadError || res.error);

  async function upload(e: SubmitEvent) {
    e.preventDefault();
    if (!file) return;
    uploadError = "";
    if (file.size > me.membership.max_upload_bytes) { uploadError = tooLargeMessage(me.membership); return; }
    uploading = true;
    try {
      const fd = new FormData();
      fd.set("title", title || file.name.replace(/\.pdf$/i, ""));
      fd.set("page_count", String(await pageCountOf(file)));
      fd.set("pdf", file);
      const p = await post<Presentation>("/api/decks", fd);
      navigate(`/decks/${p.id}`);
    } catch (err) {
      uploadError = err instanceof ApiError ? limitMessage(err, me.membership) : "Could not read that PDF.";
    } finally { uploading = false; }
  }
</script>

<svelte:head><title>Decks · Orquelo</title></svelte:head>

<div class="page">
  <div class="bar between">
    <h1>Decks</h1>
    <span class="muted data" aria-label="Storage used">{usage(me.membership)}</span>
  </div>

  <div class="stack">
    <div class="bar between">
      <details class="new" bind:open={creating}>
        <summary class="btn">New deck</summary>
        <form class="stack" onsubmit={upload}>
          <label class="f">Title (optional)<input bind:value={title} maxlength="200" /></label>
          <label class="f">PDF file (max {mb(me.membership.max_upload_bytes)} MB)<input type="file" accept="application/pdf" required onchange={(e) => (file = e.currentTarget.files?.[0] ?? null)} /></label>
          <div><button class="btn primary" disabled={!file || uploading}>{uploading ? "Uploading…" : "Upload"}</button></div>
        </form>
      </details>
      <SegToggle label="Decks to show" value={archived} onchange={(v) => (archived = v)}
        options={[{ value: false, label: "active" }, { value: true, label: "archived" }]} />
    </div>
    {#if error}<p class="err" role="alert">{error}</p>{/if}
  </div>

  <section class="stack" aria-label="Decks">
    <ul class="rows">
      {#each items as p (p.id)}
        <li class="deck">
          <a class="t" href="/decks/{p.id}">{p.title}</a>
          <span class="tags">{#if p.live_sessions}<span class="tag live">{p.live_sessions} live</span>{/if}{#if p.archived_at}<span class="tag">archived</span>{/if}{#if accessTag(p.access)}<span class="tag" title="Owner: {p.owner.name || p.owner.email}">{accessTag(p.access)}</span>{/if}</span>
          <span class="muted data n">{p.page_count} slides</span>
          <span class="muted data d">{localDate(p.created_at)}</span>
        </li>
      {:else}
        <li class="empty">{!loaded ? "Loading…" : archived ? "No archived decks." : "No decks yet. Use New deck to upload a PDF."}</li>
      {/each}
    </ul>
  </section>
</div>

<style>
  .new { flex: 1; min-width: 0; }
  .new > summary { list-style: none; display: inline-flex; }
  .new > summary::-webkit-details-marker { display: none; }
  .new[open] > summary { border-color: var(--amber); color: var(--amber); }
  .new form { margin-top: 12px; max-width: 32rem; padding: 12px; border: 1px solid var(--line); background: var(--bg2); }
  .rows > li.deck { grid-template-columns: minmax(0, 1fr) 9ch 12ch auto; align-items: baseline; gap: 4px 2ch; }
  .deck .t { grid-column: 1; overflow-wrap: anywhere; }
  .deck .tags { grid-column: 4; grid-row: 1; justify-self: end; }
  .deck .n { grid-column: 2; } .deck .d { grid-column: 3; }
  @media (max-width: 640px) {
    .rows > li.deck { grid-template-columns: auto auto 1fr; }
    .deck .t { grid-column: 1 / -1; }
    .deck .tags { grid-column: 3; grid-row: 2; justify-self: end; }
    .deck .n { grid-column: 1; } .deck .d { grid-column: 2; }
  }
</style>
