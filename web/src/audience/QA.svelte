<script lang="ts">
  import { post } from "../lib/api";
  import { actions } from "../lib/actions.svelte";
  import { localTime } from "../lib/time";
  import type { AudienceQA } from "../lib/types";

  let { pid, code, qa }: { pid: number; code: string; qa: AudienceQA } = $props();
  let text = $state("");
  const act = actions();
  const limit = $derived(qa.questions.length >= 20);
  async function send(e: SubmitEvent) {
    e.preventDefault();
    if (!qa.open || limit || !text.trim()) return;
    await act.run("send", async () => {
      await post(`/api/s/${pid}/${code}/qa`, { text: text.trim() });
      text = "";
    });
  }
</script>

<section class="stack" aria-labelledby="ask-h">
  <h1 id="ask-h">Q&A</h1>
  <p class="muted">Your questions go to the moderator. Other participants cannot see them here; the presenter may select one for the screen.</p>
  {#if qa.open}
    <form class="stack" onsubmit={send}>
      <label class="f">Your question<textarea bind:value={text} maxlength="1000" rows="4" required disabled={limit || act.is("send")}></textarea></label>
      <p class="muted count">{text.length} / 1,000 characters · {qa.questions.length} / 20 questions</p>
      {#if limit}<p role="status">You have reached this session’s 20-question limit.</p>{/if}
      <button class="btn primary" disabled={limit || act.is("send") || !text.trim()}>{act.is("send") ? "Sending…" : "Send question"}</button>
      <p class="muted">You can send a question every 10 seconds.</p>
    </form>
  {:else}<p class="muted" role="status">Submissions are closed. Your questions stay below.</p>{/if}
  {#if act.error}<p class="err" role="alert">{act.error}</p>{/if}
  <h2 class="rule">Your questions</h2>
  <ol>
    {#each qa.questions as q (q.id)}
      <li class="stack">
        <div class="bar between"><span class="muted data">{localTime(q.created_at)}</span><span class="tag">{q.status === "pending" ? "received" : q.status}</span></div>
        <p class="text">{q.text}</p>
      </li>
    {:else}<li class="muted">You haven’t sent a question yet.</li>{/each}
  </ol>
</section>

<style>
  section { padding-bottom: 24px; }
  .btn { min-height: 52px; justify-content: center; }
  .muted { font-size: 0.85rem; }
  .count { font-variant-numeric: tabular-nums; }
  ol { list-style: none; padding: 0; margin: 0; }
  li { border-bottom: 1px solid var(--line); padding: 16px 0; }
  .text { white-space: pre-wrap; overflow-wrap: anywhere; }
</style>
