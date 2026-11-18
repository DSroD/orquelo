<script lang="ts">
  import { tick } from "svelte";
  import { fitScale, SCALES } from "../lib/fit";

  let { text }: { text: string } = $props();
  let box: HTMLDivElement;
  let content: HTMLParagraphElement;
  async function fit() {
    await tick();
    if (!box) return;
    const scale = fitScale((value) => {
      box.style.setProperty("--scale", String(value));
      return { scrollHeight: content.scrollHeight, clientHeight: box.clientHeight };
    }, [...SCALES, 0.36, 0.3, 0.25, 0.2]);
    box.style.setProperty("--scale", String(scale));
  }
  $effect(() => {
    text;
    void fit();
    const observer = new ResizeObserver(() => void fit());
    observer.observe(box);
    return () => observer.disconnect();
  });
</script>

<div class="question" bind:this={box}><p bind:this={content}>{text}</p></div>

<style>
  .question { --scale: 1; min-height: 0; overflow: hidden; display: flex; align-items: center; }
  p { width: 100%; font-size: calc(clamp(1.5rem, 5vh, 4rem) * var(--scale)); line-height: 1.35; overflow-wrap: anywhere; }
</style>
