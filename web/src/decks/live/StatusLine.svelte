<script lang="ts">
  import { STEP_KEY, type Step } from "../../lib/cockpit";
  import type { ModeratorSnapshot } from "../../lib/types";

  let { ended, label, slide, pageCount, connections, cur, nextStep, connected, letterKeys }: {
    ended: boolean; label: string; slide: number; pageCount: number;
    connections: ModeratorSnapshot["connections"]; cur: ModeratorSnapshot["open_run"]; nextStep: Step | null; connected: boolean; letterKeys: boolean;
  } = $props();
</script>

<footer class="statusline" aria-label="Session status">
  <span class={ended ? "ended" : "live"}><i class="dot" class:sq={ended}></i>{ended ? "ended" : "live"}</span>
  <span class="grow">{label}</span>
  <span><span class="full">slide&nbsp;</span>{slide}/{pageCount}</span>
  <span>{connections.audience}<span class="full">&nbsp;audience</span><span class="short">&nbsp;aud</span></span>
  <span>{connections.screen} screen</span>
  {#if cur}<span>{cur.total_voters} voted</span>{/if}
  {#if nextStep}<span class="next">next{#if letterKeys} <kbd>{STEP_KEY[nextStep]}</kbd>{/if} {nextStep}</span>{/if}
  {#if !connected}<span class="warn">reconnecting…</span>{/if}
</footer>

<style>
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: currentColor; margin-right: 0.8ch; }
  .dot.sq { border-radius: 0; }
</style>
