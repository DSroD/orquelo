<script lang="ts">
  import { onDestroy } from "svelte";
  import { copyText } from "../lib/clipboard";

  let { text, label, cls = "lnk" }: { text: string; label: string; cls?: string } = $props();
  let copied = $state(false);
  let timer: ReturnType<typeof setTimeout> | undefined;

  onDestroy(() => clearTimeout(timer));

  async function copy() {
    // last resort: let the user copy it by hand
    if (!(await copyText(text))) { window.prompt("Copy this link:", text); return; }
    copied = true;
    clearTimeout(timer);
    timer = setTimeout(() => (copied = false), 1500);
  }
</script>

<button class={cls} onclick={copy}>{copied ? "Copied" : label}</button>
<span class="sr" role="status">{copied ? "Link copied" : ""}</span>

<style>
  .sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
</style>
