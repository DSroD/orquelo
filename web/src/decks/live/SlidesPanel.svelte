<script lang="ts">
  import PdfSlide from "../../components/PdfSlide.svelte";

  let { pdf, slide, pageCount, canPrev, canNext, ongo }: {
    pdf: string; slide: number; pageCount: number; canPrev: boolean; canNext: boolean; ongo: (n: number) => void;
  } = $props();
</script>

<div class="thumbs">
  <figure><div class="frame big"><PdfSlide url={pdf} page={slide} /></div><figcaption>Current</figcaption></figure>
  <figure><div class="frame"><PdfSlide url={pdf} page={Math.min(slide + 1, pageCount)} /></div><figcaption>Next</figcaption></figure>
</div>
<div class="bar nav">
  <button class="btn" onclick={() => ongo(slide - 1)} disabled={!canPrev} aria-keyshortcuts="ArrowLeft PageUp">Prev <kbd>←</kbd></button>
  <b class="data">{slide} / {pageCount}</b>
  <button class="btn" onclick={() => ongo(slide + 1)} disabled={!canNext} aria-keyshortcuts="ArrowRight PageDown">Next <kbd>→</kbd></button>
</div>

<style>
  .thumbs { display: grid; grid-template-columns: minmax(0, 2fr) minmax(0, 1fr); gap: 12px; align-items: end; }
  figure { margin: 0; } figcaption { font-size: 0.8rem; color: var(--dim); }
  .frame { aspect-ratio: 16 / 9; overflow: hidden; outline: 1px solid var(--line); }
  .nav { justify-content: center; }
  /* .bar.nav: must outrank the global .term .bar { display: flex } */
  @media (max-width: 899px) { .bar.nav { display: none; } }
</style>
