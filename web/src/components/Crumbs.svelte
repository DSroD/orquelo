<script lang="ts">
  let { trail }: { trail: { label: string; href?: string }[] } = $props();
</script>

<nav class="crumbs" aria-label="Path">
  {#each trail as t, i}
    {#if i < trail.length - 1}<a href={t.href}>{t.label}</a><span class="sep">/</span>{:else}<span aria-current="page">{t.label}</span>{/if}
  {/each}
</nav>
