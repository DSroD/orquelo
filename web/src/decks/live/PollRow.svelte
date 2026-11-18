<script lang="ts">
  import { localTime } from "../../lib/time";
  import type { Poll, RunSummary } from "../../lib/types";

  let { poll, first, primary, hasRun, resumable, ended, opening, resuming, onopen, onresume }: {
    poll: Poll; first: boolean; primary: boolean; hasRun: boolean; resumable: RunSummary | null;
    ended: boolean; opening: boolean; resuming: boolean; onopen: (pollId: number) => void; onresume: (runId: number) => void;
  } = $props();
</script>

<li class="poll">
  <span class="q">{poll.question} <span class="tag">{poll.kind}</span></span>
  <span class="acts">
    {#if resumable?.poll_id === poll.id}
      <button class="btn sm" disabled={ended || resuming} onclick={() => onresume(resumable.run_id)}
        title="Reopen voting on the {localTime(resumable.opened_at)} run; votes already cast are kept">Resume</button>
    {/if}
    {#if primary}
      <button class="btn sm primary" disabled={ended || opening} onclick={() => onopen(poll.id)} aria-keyshortcuts="o">Open<kbd>o</kbd></button>
    {:else}
      <button class="btn sm" disabled={ended || opening} onclick={() => onopen(poll.id)}
        aria-keyshortcuts={first ? "o" : undefined}
        title={hasRun ? "Starts a fresh vote; earlier votes stay in their own run" : undefined}>{hasRun ? "Start new vote" : "Open"}{#if first}<kbd>o</kbd>{/if}</button>
    {/if}
  </span>
</li>

<style>
  .poll { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 6px 0; border-top: 1px solid var(--line); }
  .poll:first-child { border-top: 0; }
  .q { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .poll .q { white-space: normal; overflow-wrap: anywhere; }
  .acts { display: flex; gap: 6px; flex-shrink: 0; flex-wrap: wrap; justify-content: flex-end; }

  @media (max-width: 600px) {
    .poll { flex-wrap: wrap; }
    .acts { width: 100%; }
    .acts .btn { flex: 1; justify-content: center; min-height: 48px; }
  }
</style>
