<script lang="ts">
  import { untrack } from "svelte";
  import { actions } from "../lib/actions.svelte";
  import type { OptionDraft, Poll, PollKind } from "../lib/types";
  import PdfSlide from "../components/PdfSlide.svelte";

  let { poll, pdf, pageCount, onsave, oncancel }: {
    poll: Poll | null; pdf: string; pageCount: number;
    onsave: (v: { slide: number | null; question: string; kind: PollKind; options: OptionDraft[]; show_results: boolean; allow_additional_answers: boolean }) => Promise<void>;
    oncancel: () => void;
  } = $props();

  const init = untrack(() => poll); // the draft is seeded once; later prop changes don't reset it
  let slide = $state<string>(init?.slide?.toString() ?? "");
  let question = $state(init?.question ?? "");
  let kind = $state<PollKind>(init?.kind ?? "single");
  let options = $state<OptionDraft[]>(init ? init.options.map(({ label, exclusive }) => ({ label, exclusive })) : [{ label: "", exclusive: false }, { label: "", exclusive: false }]);
  let additionalAnswers = $state(init?.allow_additional_answers ?? false);
  let showResults = $state(init?.show_results ?? false);
  const act = actions();
  // the slide the preview shows, only while the field holds a page that exists
  const previewPage = $derived.by(() => {
    const n = Number(slide);
    return slide !== "" && Number.isInteger(n) && n >= 1 && n <= pageCount ? n : null;
  });

  const move = (i: number, d: number) => {
    const j = i + d;
    if (j < 0 || j >= options.length) return;
    [options[i], options[j]] = [options[j], options[i]];
  };

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    await act.run("save", () => onsave({
      slide: slide === "" ? null : Number(slide), question: question.trim(), kind,
      options: options.filter((o) => o.label.trim()).map((o) => ({ label: o.label.trim(), exclusive: kind === "multi" && o.exclusive })),
      allow_additional_answers: additionalAnswers,
      show_results: showResults,
    }));
  }
</script>

<form class="stack" onsubmit={submit}>
  <div class="top">
    <div class="stack">
      <label class="f">Question<textarea bind:value={question} rows="2" maxlength="500" required></textarea></label>
      <div class="bar">
        <label class="f">Slide (1–{pageCount}, empty = any)<input class="slide" type="number" min="1" max={pageCount} placeholder="any" bind:value={slide} /></label>
        <label class="f">Type
          <select bind:value={kind}><option value="single">Single choice</option><option value="multi">Multiple choice</option></select>
        </label>
      </div>
    </div>
    <figure class="preview" aria-hidden="true">
      {#if previewPage}<PdfSlide url={pdf} page={previewPage} />{:else}<span>shown with any slide</span>{/if}
    </figure>
  </div>
  <fieldset class="stack opts">
    <legend class="muted">Options (2–30)</legend>
    {#each options as _, i}
      <div class="bar">
        <input class="opt" bind:value={options[i].label} maxlength="200" aria-label="Option {i + 1}" />
        {#if kind === "multi"}<label class="check exclusive"><input type="checkbox" bind:checked={options[i].exclusive} /> Exclusive</label>{/if}
        <button type="button" class="btn sm" onclick={() => move(i, -1)} disabled={i === 0} aria-label="Move up">Up</button>
        <button type="button" class="btn sm" onclick={() => move(i, 1)} disabled={i === options.length - 1} aria-label="Move down">Down</button>
        <button type="button" class="btn sm danger" onclick={() => options.splice(i, 1)} disabled={options.length <= 2} aria-label="Remove option {i + 1}">Remove</button>
      </div>
    {/each}
    <div><button type="button" class="btn sm" onclick={() => options.push({ label: "", exclusive: false })} disabled={options.length >= 30}>Add option</button></div>
  </fieldset>
  {#if kind === "multi"}<p class="muted hint">An exclusive answer must be selected on its own, for example “I don’t know”.</p>{/if}
  <label class="check"><input type="checkbox" bind:checked={additionalAnswers} /> Allow additional answers during voting</label>
  <p class="muted hint">Editors can add options to the current vote. The saved poll and earlier votes stay unchanged.</p>
  <label class="check"><input type="checkbox" bind:checked={showResults} /> Show results when poll starts</label>
  {#if act.error}<p class="err">{act.error}</p>{/if}
  <div class="bar">
    <button class="btn primary" disabled={act.is("save")}>Save poll</button>
    <button type="button" class="btn" onclick={oncancel}>Cancel</button>
  </div>
</form>

<style>
  form { padding: 12px; border: 1px solid var(--line); background: var(--bg2); }
  fieldset { border: 0; padding: 0; margin: 0; min-width: 0; }
  legend { padding: 0; margin-bottom: 8px; font-size: 0.85rem; }
  .slide { width: 6rem; }
  .top { display: grid; grid-template-columns: minmax(0, 1fr) 16rem; gap: 16px; align-items: start; }
  .preview { margin: 0; aspect-ratio: 16 / 9; outline: 1px solid var(--line); overflow: hidden; }
  .preview span { display: grid; place-items: center; height: 100%; font-stretch: 75%; font-size: 0.8rem; color: var(--dim); border: 1px dashed var(--line); }
  @media (max-width: 640px) { .top { grid-template-columns: minmax(0, 1fr); } .preview { max-width: 16rem; } }
  .hint { font-size: 0.85rem; }
  .exclusive { min-height: 48px; }
  .opt { flex: 1; min-width: 10rem; }
</style>
