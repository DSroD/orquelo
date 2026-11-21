<script lang="ts">
  import CopyButton from "../../components/CopyButton.svelte";

  let { code, screenUrl, audienceUrl, ended, ending, canResults, letterKeys, onletterkeys, onend }: {
    code: string; screenUrl: string; audienceUrl: string; ended: boolean; ending: boolean; canResults: boolean;
    letterKeys: boolean; onletterkeys: (enabled: boolean) => void; onend: () => void;
  } = $props();
  let menu = $state<HTMLDetailsElement>();
  function closeOutside(e: Event) {
    if (menu?.open && !(e.target instanceof Node && menu.contains(e.target))) menu.open = false;
  }
  function escape(e: KeyboardEvent) {
    if (e.key === "Escape" && menu?.open) {
      menu.open = false;
      menu.querySelector("summary")?.focus();
    }
  }
</script>

<svelte:window onclick={closeOutside} onkeydown={escape} />

<details class="menu" bind:this={menu}>
  <summary class="btn sm">Session</summary>
  <nav class="pop" aria-label="Session">
    <a class="btn" href={screenUrl} target="_blank" rel="noopener">Open screen</a>
    <CopyButton cls="btn" text={audienceUrl} label="Copy audience link" />
    <CopyButton cls="btn" text={screenUrl} label="Copy screen link" />
    {#if canResults}
      <a class="btn" href="/sessions/{code}/results">Results</a>
      <a class="btn" href="/api/sessions/{code}/export.csv" download>Export CSV</a>
    {/if}
    <label class="check"><input type="checkbox" checked={letterKeys} onchange={(e) => onletterkeys(e.currentTarget.checked)} /> Letter shortcuts</label>
    {#if !ended}<button class="btn danger" disabled={ending} onclick={() => confirm("End this session?") && onend()}>End session</button>{/if}
  </nav>
</details>

<style>
  .menu .pop .danger { margin-top: 6px; }
  .menu .pop .check { min-height: 44px; }
</style>
