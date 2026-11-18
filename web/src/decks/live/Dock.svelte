<script lang="ts">
  import { STEP_KEY, STEP_LABEL, type Step } from "../../lib/cockpit";

  let { canPrev, canNext, step, canStep, idleLabel, onprev, onnext, onstep }: {
    canPrev: boolean; canNext: boolean; step: Step | null; canStep: boolean; idleLabel: string;
    onprev: () => void; onnext: () => void; onstep: () => void;
  } = $props();
</script>

<div class="dock" role="group" aria-label="Lecture controls">
  <button class="btn" onclick={onprev} disabled={!canPrev} aria-label="Previous slide" aria-keyshortcuts="ArrowLeft PageUp">Prev</button>
  {#if step}
    <button class="btn primary step" onclick={onstep} disabled={!canStep} aria-keyshortcuts={STEP_KEY[step]}>{STEP_LABEL[step]}</button>
  {:else}
    <button class="btn step" disabled>{idleLabel}</button>
  {/if}
  <button class="btn" onclick={onnext} disabled={!canNext} aria-label="Next slide" aria-keyshortcuts="ArrowRight PageDown">Next</button>
</div>

<style>
  .dock { display: none; }
  @media (max-width: 899px) {
    /* the run view on a phone: slide and next step under the thumb, so the in-page copies go quiet */
    .dock { display: grid; grid-template-columns: 1fr 2fr 1fr; gap: 8px; padding: 8px 16px; background: var(--bg); border-top: 1px solid var(--line); }
    .dock .btn { min-height: 52px; justify-content: center; text-align: center; }
    .dock .step:not(.primary) { color: var(--dim); }
  }
</style>
