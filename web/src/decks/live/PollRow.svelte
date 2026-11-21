<script lang="ts">
  import { localTime } from "../../lib/time";
  import type { Poll, RunSummary } from "../../lib/types";

  let { poll, shortcut, primary, hasRun, resumable, canStart, onopen, onresume }: {
    poll: Poll; shortcut: boolean; primary: boolean; hasRun: boolean; resumable: RunSummary | null;
    canStart: boolean; onopen: (pollId: number) => void; onresume: (runId: number) => void;
  } = $props();
</script>

<li class="poll">
  <span class="q">{poll.question} <span class="tag">{poll.kind}</span></span>
  <span class="acts">
    {#if resumable?.poll_id === poll.id}
      <button class="btn sm" disabled={!canStart} onclick={() => onresume(resumable.run_id)}
        title="Reopen voting on the {localTime(resumable.opened_at)} run; votes already cast are kept">Resume</button>
    {/if}
    <button class="btn sm" class:primary disabled={!canStart} onclick={() => onopen(poll.id)}
      aria-keyshortcuts={shortcut ? "o" : undefined}
      title={hasRun ? "Starts a fresh vote; earlier votes stay in their own run" : undefined}>{hasRun ? "Start new vote" : "Open"}{#if shortcut}<kbd>o</kbd>{/if}</button>
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
