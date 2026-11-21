<script lang="ts">
  import type { Snippet } from "svelte";
  import SegToggle from "../../components/SegToggle.svelte";
  import { STEP_LABEL, voters, type Choice, type Step } from "../../lib/cockpit";
  import { localTime } from "../../lib/time";
  import type { ModeratorOverlay, RunSummary } from "../../lib/types";

  let { runs, overlay, choice, pollTarget, qaEnabled = false, can, nextStep, liveOnScreen, letterKeys, onchoose, ontogglereveal, onshowrun, onshowcurrent, controls }: {
    qaEnabled?: boolean; runs: RunSummary[]; overlay: ModeratorOverlay | null; choice: Choice; pollTarget: number | null;
    can: { overlay: boolean; poll: boolean; reveal: boolean; show: boolean }; nextStep: Step | null;
    liveOnScreen: boolean; letterKeys: boolean;
    onchoose: (c: Choice) => void; ontogglereveal: () => void; onshowrun: (runId: number) => void; onshowcurrent: () => void;
    controls: Snippet;
  } = $props();
  const options = $derived<{ value: Choice; label: string; kbd?: string; disabled: boolean }[]>([
    { value: "none", label: "Slide only", kbd: letterKeys ? "s" : undefined, disabled: !can.overlay },
    { value: "qr", label: "QR code", kbd: letterKeys ? "q" : undefined, disabled: !can.overlay },
    { value: "poll", label: "Poll", kbd: letterKeys && nextStep !== "show" ? "p" : undefined, disabled: !can.poll },
    ...(qaEnabled ? [{ value: "qa" as const, label: "Q&A", disabled: !can.overlay }] : []),
  ]);
</script>

<div class="bar between">
  <SegToggle {options} value={choice} onchange={onchoose} label="Over the slide" />
  {#if nextStep === "show" || liveOnScreen}
    {@const show = nextStep === "show"}
    {@const key = show ? "p" : "r"}
    <button class="btn sm" class:primary={show || nextStep === "reveal"} disabled={show ? !can.show : !can.reveal}
      aria-keyshortcuts={letterKeys ? key : undefined} onclick={show ? onshowcurrent : ontogglereveal}>
      {show ? STEP_LABEL.show : overlay?.type === "poll" && overlay.revealed ? "Hide results" : STEP_LABEL.reveal}{#if letterKeys}<kbd>{key}</kbd>{/if}
    </button>
  {/if}
</div>
{#if overlay?.type === "poll"}
  {@render controls()}
  <ul class="runs" role="radiogroup" aria-label="Poll on screen">
    {#each runs as r (r.run_id)}
      {@const on = overlay.run_id === r.run_id}
      <li class:on>
        <label>
          <input type="radio" name="run" checked={on} disabled={!can.overlay} onchange={() => onshowrun(r.run_id)} />
          <span class="q">{r.question}</span>
          <span class="meta data">{`${localTime(r.opened_at)} · ${voters(r.total_voters)}`}{#if !r.closed_at}{" · "}<b>voting</b>{/if}</span>
        </label>
      </li>
    {/each}
  </ul>
  {#if !liveOnScreen}
    {@const selected = runs.find((r) => r.run_id === overlay.run_id)}
    <div class="bar between">
      <p class="muted selected-run" id="selected-screen-run">Previous vote on screen{selected ? ` · ${selected.question}` : ""}</p>
      <button class="btn sm" disabled={!can.reveal} aria-describedby="selected-screen-run" onclick={ontogglereveal}>
        {overlay.revealed ? "Hide previous results" : "Reveal previous results"}
      </button>
    </div>
  {/if}
{:else}
  <p class="muted">{choice === "qr" ? "The join QR code is over the slide." : choice === "qa" ? "Q&A is on screen. Choose a question in the Q&A inbox below." : "The slide alone."}{pollTarget === null ? " Open a poll to show its results here." : ""}</p>
{/if}

<style>
  .runs { list-style: none; margin: 0; padding: 0; max-height: 17rem; overflow-y: auto; border: 1px solid var(--line); }
  .runs li { display: flex; align-items: center; gap: 8px; padding: 0 8px 0 0; border-top: 1px solid var(--line); transition: background-color 0.18s; }
  .runs li:first-child { border-top: 0; }
  .runs li.on { background: var(--sel); }
  .runs label { flex: 1; min-width: 0; display: grid; grid-template-columns: auto minmax(0, 1fr); align-items: center; gap: 4px 10px;
    min-height: 44px; padding: 6px 0 6px 12px; cursor: pointer; }
  .runs .meta { grid-column: 2; font-size: 0.85rem; color: var(--dim); white-space: nowrap; }
  .runs .meta b { color: var(--green); font-weight: 600; }
  .q { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .selected-run { overflow-wrap: anywhere; }
</style>
