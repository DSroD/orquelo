<script lang="ts" generics="T extends string">
  import type { Snippet } from "svelte";
  import { nextTabIndex } from "../lib/tabs";

  let { tabs, selected = $bindable(), label, tab }: {
    tabs: readonly T[]; selected: T; label: string; tab: Snippet<[T]>;
  } = $props();
  let els = $state<Record<string, HTMLButtonElement | undefined>>({});

  function onkey(e: KeyboardEvent) {
    const j = nextTabIndex(tabs.length, tabs.indexOf(selected), e.key);
    if (j === null) return;
    e.preventDefault();
    selected = tabs[j];
    els[selected]?.focus();
  }
</script>

<div class="tabs" role="tablist" aria-label={label}>
  {#each tabs as t (t)}
    <button role="tab" id="tab-{t}" aria-controls="panel-{t}" aria-selected={selected === t} tabindex={selected === t ? 0 : -1}
      bind:this={els[t]} onclick={() => (selected = t)} onkeydown={onkey}>
      {@render tab(t)}
    </button>
  {/each}
</div>

<style>
  /* tabs as a window list: rule underneath, the selected tab in amber with a 2px underline */
  .tabs { display: flex; border-bottom: 1px solid var(--line); gap: 0; }
  .tabs [role="tab"] {
    font: inherit; font-stretch: 100%; display: inline-flex; align-items: baseline; gap: 1ch; min-height: 44px; padding: 8px 16px 6px;
    background: none; border: 0; border-bottom: 2px solid transparent; margin-bottom: -1px; color: var(--dim); cursor: pointer;
  }
  .tabs [role="tab"]:hover { color: var(--fg); }
  .tabs [role="tab"][aria-selected="true"] { color: var(--amber); border-bottom-color: var(--amber); font-weight: 600; }
  .tabs [role="tab"]:focus-visible { outline-offset: -2px; }
  /* content comes from the caller's snippet */
  .tabs :global(.n) { color: var(--dim); font-weight: 400; }
  .tabs :global(.tag) { font-weight: 400; }
  @media (max-width: 760px) { .tabs [role="tab"] { flex: 1; justify-content: center; min-height: 48px; } }
</style>
