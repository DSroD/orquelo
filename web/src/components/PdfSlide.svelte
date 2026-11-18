<script lang="ts">
  import { loadPdf, type PdfDoc } from "../lib/pdf";

  let { url, page, onpages }: { url: string; page: number; onpages?: (n: number) => void } = $props();

  let box: HTMLDivElement;
  let canvas: HTMLCanvasElement;
  let doc = $state<PdfDoc | null>(null);
  let size = $state({ w: 0, h: 0 });
  let failed = $state(false);

  $effect(() => {
    let dead = false;
    failed = false;
    loadPdf(url).then(
      (d) => { if (!dead) { doc = d; onpages?.(d.numPages); } },
      () => { if (!dead) failed = true; },
    );
    return () => { dead = true; };
  });

  $effect(() => {
    const ro = new ResizeObserver(([e]) => {
      size = { w: e.contentRect.width, h: e.contentRect.height };
    });
    ro.observe(box);
    return () => ro.disconnect();
  });

  // Render offscreen, then blit: resizing the visible canvas would blank it (white flash) before the
  // new page is ready. Renders are chained so a cancelled one settles before the next starts.
  let chain: Promise<void> = Promise.resolve();
  let shown = $state(0);
  $effect(() => {
    if (!doc || !size.w || !size.h) return;
    const d = doc, p = Math.min(Math.max(page, 1), d.numPages), { w, h } = size;
    let task: { cancel(): void; promise: Promise<unknown> } | undefined;
    let dead = false;
    chain = chain.then(async () => {
      if (dead) return;
      const pg = await d.getPage(p);
      if (dead) return;
      const base = pg.getViewport({ scale: 1 });
      const dpr = window.devicePixelRatio || 1;
      const vp = pg.getViewport({ scale: Math.min(w / base.width, h / base.height) * dpr });
      const off = document.createElement("canvas");
      off.width = Math.floor(vp.width);
      off.height = Math.floor(vp.height);
      task = pg.render({ canvasContext: off.getContext("2d")!, viewport: vp });
      await task.promise;
      if (dead) return;
      canvas.width = off.width;
      canvas.height = off.height;
      canvas.style.width = `${vp.width / dpr}px`;
      canvas.style.height = `${vp.height / dpr}px`;
      canvas.getContext("2d")!.drawImage(off, 0, 0);
      shown = p;
    }).catch((e: { name?: string }) => {
      if (!dead && e?.name !== "RenderingCancelledException") failed = true;
    });
    return () => { dead = true; task?.cancel(); };
  });
</script>

<div class="slide" bind:this={box} role="img" aria-label={shown ? `Slide ${shown}` : "Loading slide"}>
  <canvas bind:this={canvas} class:blank={!shown}></canvas>
  {#if failed}<p class="err">Could not load slides</p>{/if}
</div>

<style>
  .slide { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; background: #000; position: relative; }
  canvas { display: block; background: #fff; }
  canvas.blank { visibility: hidden; }
  .err { position: absolute; color: #fff; }
</style>
