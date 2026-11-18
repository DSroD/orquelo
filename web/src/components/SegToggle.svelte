<script lang="ts" generics="T extends string | boolean">
  let { options, value, onchange, label }: {
    options: { value: T; label: string; kbd?: string; count?: number; disabled?: boolean }[];
    value: T; onchange: (v: T) => void; label: string;
  } = $props();
</script>

<div class="seg" role="group" aria-label={label}>
  {#each options as o (o.value)}
    <button class="btn sm" class:on={value === o.value} aria-pressed={value === o.value} aria-keyshortcuts={o.kbd} disabled={o.disabled} onclick={() => onchange(o.value)}>
      {o.label}{#if o.count !== undefined}{" "}<span class="data">{o.count}</span>{/if}{#if o.kbd}<kbd>{o.kbd}</kbd>{/if}
    </button>
  {/each}
</div>
