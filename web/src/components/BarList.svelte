<script lang="ts">
  import { percents } from "../lib/percent";
  import type { CountedOption, PollKind } from "../lib/types";

  let { options, total, kind }: { options: CountedOption[]; total: number; kind: PollKind } = $props();
  const pct = $derived(percents(options.map((o) => o.count), total, kind));
</script>

<ul class="bars">
  {#each options as o, i (o.id)}
    <li>
      <div class="row"><span class="lbl">{o.label}</span><span class="num data"><b>{o.count}</b> · {pct[i]}%</span></div>
      <div class="track"><div class="fill" style="transform:scaleX({total ? o.count / total : 0})"></div></div>
    </li>
  {/each}
</ul>

<style>
  .bars { list-style: none; padding: 0; margin: 0; display: grid; gap: 10px; }
  .row { display: flex; justify-content: space-between; gap: 2ch; align-items: baseline; }
  .lbl { min-width: 0; overflow-wrap: anywhere; }
  .num { white-space: nowrap; }
  .track { height: 6px; background: var(--line); margin-top: 3px; overflow: hidden; }
  .fill { height: 100%; background: var(--cyan); transform-origin: left; transition: transform 0.25s cubic-bezier(0.16, 1, 0.3, 1); }
</style>
