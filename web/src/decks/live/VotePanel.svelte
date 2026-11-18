<script lang="ts">
  import BarList from "../../components/BarList.svelte";
  import { voters } from "../../lib/cockpit";
  import type { ModeratorOverlay, ModeratorSnapshot } from "../../lib/types";

  let { cur, overlay, canClose, primary, onclose }: {
    cur: ModeratorSnapshot["open_run"]; overlay: ModeratorOverlay | null; canClose: boolean; primary: boolean; onclose: () => void;
  } = $props();
</script>

{#if cur}
  <div class="bar between">
    <b class="q2">{cur.question}</b>
    <span class="tag live">open</span>
  </div>
  <BarList options={cur.options} total={cur.total_voters} kind={cur.kind} />
  <div class="bar between">
    <span class="muted data">{voters(cur.total_voters)}{overlay?.type === "poll" && overlay.run_id === cur.run_id && overlay.revealed ? "" : " · hidden on screen"}</span>
    <button class="btn sm" class:primary disabled={!canClose} aria-keyshortcuts="c" onclick={onclose}>Close voting<kbd>c</kbd></button>
  </div>
{:else}
  <p class="muted">No vote is running.</p>
{/if}

<style>
  .q2 { min-width: 0; overflow-wrap: anywhere; }
</style>
