<script lang="ts">
  let { status, paused, disabled, onrotate }: {
    status: string; paused: boolean; disabled: boolean; onrotate: (action: "pause" | "resume" | "next") => void;
  } = $props();
</script>

<div class="controls" role="group" aria-label="Projector pages">
  <span class="muted data page-status" role="status">{status}</span>
  <button class="btn sm" {disabled} onclick={() => onrotate(paused ? "resume" : "pause")}>
    {paused ? "Resume rotation" : "Pause rotation"}
  </button>
  <button class="btn sm" {disabled} onclick={() => onrotate("next")}>Next page</button>
</div>

<style>
  .controls { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 8px; }
  .page-status { font-size: .85rem; }
  @media (max-width: 899px) {
    .controls { display: grid; grid-template-columns: 1fr 1fr; }
    .page-status { grid-column: 1 / -1; }
    .controls .btn { min-height: 44px; justify-content: center; text-align: center; }
  }
</style>
