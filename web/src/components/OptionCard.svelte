<script lang="ts">
  let { label, selected, multi, disabled = false, busy, tabindex, onfocus, onclick }: {
    label: string; selected: boolean; multi: boolean; disabled?: boolean; busy: boolean; tabindex?: number;
    onfocus?: () => void; onclick: () => void;
  } = $props();
</script>

<button
  type="button"
  class="card"
  class:selected
  role={multi ? "checkbox" : "radio"}
  aria-checked={selected}
  aria-disabled={busy || undefined}
  {disabled}
  {tabindex}
  {onfocus}
  onclick={() => { if (!busy) onclick(); }}
>
  <span class="mark" class:square={multi} aria-hidden="true"></span>
  <span class="label" dir="auto">{label}</span>
</button>

<style>
  .card {
    display: flex; align-items: center; gap: 14px; width: 100%; min-height: 56px; padding: 12px 14px;
    text-align: start; font: inherit; font-size: 1rem; line-height: 1.4; color: var(--fg);
    background: var(--bg2); border: 1px solid var(--line); border-radius: 2px; cursor: pointer;
    touch-action: manipulation; transition: background-color 0.18s, border-color 0.18s, box-shadow 0.18s;
  }
  .card:hover:not(:disabled, [aria-disabled="true"]) { border-color: var(--amber); }
  .card.selected { border-color: var(--amber); background: var(--sel); box-shadow: inset 0 0 0 1px var(--amber); }
  .card:disabled, .card[aria-disabled="true"] { opacity: 0.6; cursor: default; }
  .mark { flex: none; position: relative; width: 22px; height: 22px; border: 1px solid var(--dim); border-radius: 50%; transition: border-color 0.18s; }
  .mark.square { border-radius: 2px; }
  .selected .mark { border-color: var(--amber); }
  /* radio: a dot; checkbox: a check, both drawn */
  .selected .mark::after { content: ""; position: absolute; inset: 5px; border-radius: 50%; background: var(--amber); }
  .selected .mark.square::after { inset: 2px 7px 5px 6px; border: solid var(--amber); border-width: 0 2px 2px 0; border-radius: 0; background: none; transform: rotate(45deg); }
  .label { flex: 1; min-width: 0; overflow-wrap: anywhere; }
</style>
