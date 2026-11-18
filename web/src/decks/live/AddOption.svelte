<script lang="ts">
  import { post } from "../../lib/api";
  import { actions } from "../../lib/actions.svelte";
  import type { ModeratorSnapshot } from "../../lib/types";

  let { code, run, ended }: { code: string; run: NonNullable<ModeratorSnapshot["open_run"]>; ended: boolean } = $props();
  let label = $state("");
  let exclusive = $state(false);
  const act = actions();
  const full = $derived(run.options.length >= 30);
  async function add(e: SubmitEvent) {
    e.preventDefault();
    if (ended || full || !label.trim()) return;
    await act.run("add", async () => {
      await post(`/api/sessions/${code}/poll/options`, { run_id: run.run_id, label: label.trim(), exclusive: run.kind === "multi" && exclusive });
      label = "";
      exclusive = false;
    });
  }
</script>

<form class="stack" onsubmit={add}>
  <label class="f">Additional answer<input bind:value={label} maxlength="200" required disabled={ended || full || act.is("add")} /></label>
  <div class="bar between">
    {#if run.kind === "multi"}<label class="check"><input type="checkbox" bind:checked={exclusive} disabled={ended || full || act.is("add")} /> Exclusive</label>{/if}
    <button class="btn sm" disabled={ended || full || act.is("add") || !label.trim()}>{act.is("add") ? "Adding…" : "Add answer"}</button>
  </div>
  <p class="muted">{full ? "This vote has reached the 30-option limit." : "Added to this vote only. Existing votes stay unchanged."}</p>
  {#if act.error}<p class="err" role="alert">{act.error}</p>{/if}
</form>

<style>
  form { border-top: 1px solid var(--line); padding-top: 12px; }
  p { font-size: 0.85rem; }
  :global(.term) label.check, :global(.term) .btn { min-height: 48px; }
</style>
