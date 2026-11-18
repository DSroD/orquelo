<script lang="ts">
  import { post } from "../../lib/api";
  import type { Actions } from "../../lib/actions.svelte";
  import CopyButton from "../../components/CopyButton.svelte";
  import { navigate } from "../../lib/router";
  import type { Access, Session } from "../../lib/types";
  import { localDateTime, localTime } from "../../lib/time";

  let { sessions, base, act, access }: { sessions: Session[]; base: string; act: Actions; access: Access } = $props();

  let label = $state("");
  const live = $derived(sessions.filter((s) => !s.ended_at));
  const past = $derived(sessions.filter((s) => s.ended_at));
</script>

{#if live.length}
  <section class="stack" aria-labelledby="live-h">
    <h2 id="live-h" class="rule">Live now</h2>
    <ul class="rows">
      {#each live as s (s.id)}
        <li class="sess">
          <span class="who"><span class="tag live">live</span> <b>{s.label || "(no label)"}</b> <span class="muted data">since {localTime(s.started_at)}</span></span>
          {#if access.edit && !access.moderate}<a class="btn" href="/sessions/{s.code}">Add answers</a>{/if}
          {#if access.moderate}<span class="bar go">
            <a class="btn primary" href="/sessions/{s.code}">Control</a>
            <CopyButton cls="btn sm" text={s.audience_url} label="Copy audience link" />
            {#if s.screen_url}<CopyButton cls="btn sm" text={s.screen_url} label="Copy screen link" />{/if}
            <button class="btn sm danger" disabled={act.is(`end${s.code}`)} onclick={() => confirm("End this session?") && act.run(`end${s.code}`, () => post(`/api/sessions/${s.code}/end`))}>End</button>
          </span>{/if}
        </li>
      {/each}
    </ul>
  </section>
{/if}

{#if access.moderate}<section class="stack" aria-labelledby="sessions-h">
  <h2 id="sessions-h" class="rule">New session</h2>
  <form class="bar start" onsubmit={(e) => { e.preventDefault(); act.run("start", async () => { const s = await post<Session>(`${base}/sessions`, { label }); label = ""; navigate(`/sessions/${s.code}`); return "left"; }); }}>
    <input bind:value={label} maxlength="100" placeholder="Label, e.g. Class A" aria-label="Session label" />
    <button class="btn" class:primary={!live.length} disabled={act.is("start")}>Start session</button>
  </form>
</section>{/if}

<section class="stack" aria-labelledby="history-h">
  <h2 id="history-h" class="rule">History</h2>
  {#if past.length}
    <ul class="rows">
      {#each past as s (s.id)}
        <li class="sess">
          <span class="who"><span class="tag ended">ended</span> <b>{s.label || "(no label)"}</b> <span class="muted data">{localDateTime(s.started_at)}</span></span>
          {#if access.results}<span class="links">
            <a class="lnk" href="/sessions/{s.code}/results">Results</a>
            <a class="lnk" href="/api/sessions/{s.code}/export.csv" download>CSV</a>
          </span>{/if}
        </li>
      {/each}
    </ul>
  {:else}<p class="muted">No ended sessions yet. {access.results ? "Results and CSVs of each session stay here." : ""}</p>{/if}
</section>

<style>
  .rows > li.sess { grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 8px 2ch; }
  .who { min-width: 0; overflow-wrap: anywhere; }
  @media (max-width: 760px) {
    .rows > li.sess { grid-template-columns: minmax(0, 1fr); }
    .go { display: grid; grid-template-columns: 1fr 1fr; }
    .go .btn { justify-content: center; }
    .go .btn.primary { grid-column: 1 / -1; min-height: 52px; }
    .go .danger { grid-column: 1 / -1; }
    .start input { flex: 1 1 100%; }
    .start .btn { flex: 1 1 100%; justify-content: center; min-height: 48px; }
  }
</style>
