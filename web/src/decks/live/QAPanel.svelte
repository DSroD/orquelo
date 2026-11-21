<script lang="ts">
  import { patch, post } from "../../lib/api";
  import { actions } from "../../lib/actions.svelte";
  import { localTime } from "../../lib/time";
  import type { ModeratorOverlay, ModeratorQA, QuestionStatus } from "../../lib/types";
  import SegToggle from "../../components/SegToggle.svelte";

  let { code, qa, overlay, ended, canShow, onshow }: {
    code: string; qa: ModeratorQA; overlay: ModeratorOverlay | null; ended: boolean; canShow: boolean; onshow: (id: number | null) => void;
  } = $props();
  let filter = $state<QuestionStatus>("pending");
  const act = actions();
  const shown = $derived(qa.questions.filter((q) => q.status === filter));
  const filters = $derived((["pending", "answered", "dismissed"] as const).map((value) => ({ value, label: value, count: qa.questions.filter((q) => q.status === value).length })));
  const toggle = () => act.run("open", () => post(`/api/sessions/${code}/qa`, { open: !qa.open }));
  const status = (id: number, value: QuestionStatus) => act.run(`q${id}`, () => patch(`/api/sessions/${code}/qa/questions/${id}`, { status: value }));
</script>

<section class="stack" aria-labelledby="qa-live-h">
  <h2 id="qa-live-h" class="rule">Q&A <span class="tag" class:live={qa.open}>{qa.open ? "open" : "closed"}</span></h2>
  <div class="bar">
    <button class="btn" disabled={ended || act.is("open")} onclick={toggle}>{qa.open ? "Close submissions" : "Open Q&A"}</button>
    <button class="btn" disabled={!canShow} onclick={() => onshow(null)}>Show Q&A screen</button>
  </div>
  <p class="muted">Only you and the question’s author see submissions. Showing Q&A starts with an invitation; select a question to put it on screen.</p>
  <SegToggle options={filters} value={filter} onchange={(v) => filter = v} label="Questions to show" />
  {#if act.error}<p class="err" role="alert">{act.error}</p>{/if}
  <ol class="questions">
    {#each shown as q (q.id)}
      <li class="stack">
        <div class="bar between"><span class="muted data">{localTime(q.created_at)}</span>{#if overlay?.type === "qa" && overlay.question_id === q.id}<span class="tag live">on screen</span>{/if}</div>
        <p class="text">{q.text}</p>
        <div class="bar">
          {#if q.status === "pending"}
            <button class="btn sm" disabled={!canShow} onclick={() => onshow(q.id)}>Show question</button>
            <button class="btn sm" disabled={ended || act.is(`q${q.id}`)} onclick={() => status(q.id, "answered")}>Mark answered</button>
            <button class="btn sm" disabled={ended || act.is(`q${q.id}`)} onclick={() => status(q.id, "dismissed")}>Dismiss</button>
          {:else}
            <button class="btn sm" disabled={ended || act.is(`q${q.id}`)} onclick={() => status(q.id, "pending")}>Restore to pending</button>
          {/if}
        </div>
      </li>
    {:else}<li class="muted empty">No {filter} questions.</li>{/each}
  </ol>
</section>

<style>
  .questions { list-style: none; margin: 0; padding: 0; }
  li { padding: 16px 0; border-bottom: 1px solid var(--line); }
  .text { white-space: pre-wrap; overflow-wrap: anywhere; }
  .muted { font-size: 0.85rem; }
  :global(.term) .btn { min-height: 48px; }
  section :global(.seg) { flex-wrap: wrap; }
  section :global(.seg .btn) { min-height: 48px; }
</style>
