<script lang="ts">
  import { fitScale } from "../lib/fit";
  import { columnsFor } from "../lib/layout";
  import { percents } from "../lib/percent";
  import type { CountedOption, PollKind } from "../lib/types";

  let { options, total, kind, showCounts = true }: {
    options: CountedOption[]; total: number; kind: PollKind; showCounts?: boolean;
  } = $props();
  const cols = $derived(columnsFor(options.length));
  const pcts = $derived(percents(options.map((o) => o.count), total, kind));
  const max = $derived(Math.max(1, ...options.map((o) => o.count)));
  let ul: HTMLUListElement;

  // Shrink --s step by step until the list fits its box; re-run on resize and when content changes.
  function fit() {
    const s = fitScale((sc) => {
      ul.style.setProperty("--s", String(sc));
      return ul;
    });
    ul.style.setProperty("--s", String(s));
  }
  $effect(() => {
    options; cols;
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(ul);
    return () => ro.disconnect();
  });
</script>

<ul bind:this={ul} class="bars" class:two={cols === 2} class:compact={cols === "compact"} class:dense={cols === "dense"}>
  {#each options as o, i (o.id)}
    <li>
      <div class="row">
        <span class="label">{o.label}</span>
        {#if showCounts}<span class="num"><b>{o.count}</b> · {pcts[i]}%</span>{/if}
      </div>
      {#if showCounts}<div class="track"><div class="fill" style="transform:scaleX({o.count / max})"></div></div>{/if}
    </li>
  {/each}
</ul>

<style>
  .bars {
    list-style: none; margin: 0; padding: 0; width: 100%; height: 100%; min-height: 0; --s: 1;
    display: grid; grid-template-columns: 1fr; gap: calc(clamp(0.4rem, 1.6vh, 1rem) * var(--s)) clamp(1rem, 3vw, 3rem);
    align-content: start;
  }
  .bars.two, .bars.compact { grid-template-columns: 1fr 1fr; }
  .bars.dense { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .bars.compact, .bars.dense { gap: calc(0.3rem * var(--s)) 2rem; }
  li { min-width: 0; }
  .row { display: flex; justify-content: space-between; gap: 1rem; align-items: baseline; font-size: calc(clamp(1rem, 2.6vh, 2rem) * var(--s)); line-height: 1.2; }
  .two .row { font-size: calc(clamp(0.9rem, 2.2vh, 1.6rem) * var(--s)); }
  .compact .row, .dense .row { font-size: calc(clamp(0.75rem, 1.7vh, 1.1rem) * var(--s)); }
  li:not(:has(.track)) { padding: 0.15em 0; }
  .label { min-width: 0; overflow-wrap: anywhere; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .num { flex: none; font-variant-numeric: tabular-nums; }
  .track { height: calc(clamp(0.6rem, 2.4vh, 1.6rem) * var(--s)); background: rgba(255,255,255,0.18); border-radius: 999px; overflow: hidden; margin-top: 0.2em; }
  .compact .track, .dense .track { height: calc(clamp(0.35rem, 1.2vh, 0.7rem) * var(--s)); }
  .fill { height: 100%; background: #4cc2ff; transform-origin: left; transition: transform 0.5s cubic-bezier(0.16, 1, 0.3, 1); }
</style>
