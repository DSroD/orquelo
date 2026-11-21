<script lang="ts">
  import type { ProjectorOption } from "../lib/projector";
  let { options, revealed, denominator }: { options: ProjectorOption[]; revealed: boolean; denominator: number } = $props();
</script>

<ul class="projector-rows">
  {#each options as option (option.id)}
    <li>
      <div class="row">
        {#if option.rank !== null}<span class="rank">#{option.rank}</span>{/if}
        <span class="label">{option.label}</span>
        {#if revealed}<span class="number"><b>{option.count}</b> · {option.percent}%</span>{/if}
      </div>
      {#if revealed}<div class="track"><div class="fill" style:transform="scaleX({option.count / denominator})"></div></div>{/if}
    </li>
  {/each}
</ul>

<style>
  .projector-rows { list-style: none; margin: 0; padding: 0; display: grid; gap: 16px; width: 100%; }
  li { min-width: 0; }
  .row { display: flex; align-items: baseline; gap: 16px; font-size: clamp(24px, 3.5vh, 36px); line-height: 1.25; }
  .label { flex: 1; min-width: 0; overflow-wrap: anywhere; }
  .rank { color: #b9d9ec; font-size: 0.8em; min-width: 3ch; font-variant-numeric: tabular-nums; }
  .number { flex: none; white-space: nowrap; font-variant-numeric: tabular-nums; }
  .track { height: 8px; margin-top: 6px; background: rgba(255,255,255,0.18); border-radius: 999px; overflow: hidden; }
  .fill { height: 100%; background: #4cc2ff; transform-origin: left; }
</style>
