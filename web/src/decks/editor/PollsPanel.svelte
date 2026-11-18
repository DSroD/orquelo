<script lang="ts">
  import { del, patch, post, put } from "../../lib/api";
  import type { Actions } from "../../lib/actions.svelte";
  import SegToggle from "../../components/SegToggle.svelte";
  import PdfSlide from "../../components/PdfSlide.svelte";
  import type { Poll } from "../../lib/types";
  import PollForm from "../PollForm.svelte";

  let { polls, pdf, pageCount, base, act, reload, canEdit }: {
    polls: Poll[]; pdf: string; pageCount: number; base: string; act: Actions; reload: () => Promise<unknown>; canEdit: boolean;
  } = $props();

  let editing = $state<Poll | "new" | null>(null);
  // archived polls keep their history (runs, results) but are no longer offered in any cockpit
  let archivedView = $state(false);
  const archivedCount = $derived(polls.filter((pl) => pl.archived_at !== null).length);
  const shown = $derived(polls.filter((pl) => (pl.archived_at !== null) === archivedView));

  // errors go to PollForm, so this bypasses act.run
  const savePoll = async (v: object) => {
    if (editing === "new") await post(`${base}/polls`, v);
    else if (editing) await put(`/api/polls/${editing.id}`, v);
    editing = null;
    await reload();
  };
  // the checkbox flips before the PATCH; put it back if the save fails
  const toggleShowResults = (pl: Poll, box: HTMLInputElement) => act.run(`sr${pl.id}`, async () => {
    try { await patch(`/api/polls/${pl.id}`, { show_results: box.checked }); }
    catch (e) { box.checked = pl.show_results; throw e; }
  });
  const setView = (archived: boolean) => {
    archivedView = archived;
    if (archived && editing === "new") editing = null;
  };
</script>

<section class="stack" aria-labelledby="polls-h">
  <h2 id="polls-h" class="sr">Polls</h2>
  <div class="bar between">
    <SegToggle label="Polls to show" value={archivedView} onchange={setView}
      options={[{ value: false, label: "active" }, { value: true, label: "archived", count: archivedCount }]} />
    {#if canEdit && !editing && !archivedView}<button class="btn sm" onclick={() => (editing = "new")}>New poll</button>{/if}
  </div>
  {#if editing === "new" && !archivedView}<PollForm poll={null} {pdf} {pageCount} onsave={savePoll} oncancel={() => (editing = null)} />{/if}
  <ul class="rows">
    {#each shown as pl (pl.id)}
      {#if editing !== "new" && editing?.id === pl.id}
        <li><PollForm poll={pl} {pdf} {pageCount} onsave={savePoll} oncancel={() => (editing = null)} /></li>
      {:else}
        <li class="poll">
          <div class="thumb" aria-hidden="true">
            {#if pl.slide}<PdfSlide url={pdf} page={pl.slide} />{:else}<span class="any">any slide</span>{/if}
          </div>
          <div class="body">
            <span class="data meta">
              <span class="muted">{pl.slide ? `slide ${pl.slide}` : "any slide"}</span>
              <span class="tag">{pl.kind}</span>{#if pl.allow_additional_answers}<span class="tag">live additions</span>{/if}{#if pl.has_runs}<span class="tag" title="It has been run, so its options are fixed">locked</span>{/if}
            </span>
            <b>{pl.question}</b>
            <span class="muted opts">{pl.options.map((o) => o.label).join(" · ")}</span>
          </div>
          {#if canEdit}<div class="ctl">
            <span class="links">
              {#if pl.has_runs}
                <button class="lnk" disabled={act.is(`dup${pl.id}`)} onclick={() => act.run(`dup${pl.id}`, () => post(`/api/polls/${pl.id}/duplicate`))}>Duplicate to edit</button>
                {#if pl.archived_at}
                  <button class="lnk" disabled={act.is(`arc${pl.id}`)} onclick={() => act.run(`arc${pl.id}`, () => post(`/api/polls/${pl.id}/unarchive`))}>Unarchive</button>
                {:else}
                  <button class="lnk" disabled={act.is(`arc${pl.id}`)} title="Keeps its results; it is no longer offered in sessions"
                    onclick={() => act.run(`arc${pl.id}`, () => post(`/api/polls/${pl.id}/archive`))}>Archive</button>
                {/if}
              {:else}
                <button class="lnk" disabled={!!editing} onclick={() => (editing = pl)}>Edit</button>
                <button class="lnk danger" disabled={act.is(`del${pl.id}`)} onclick={() => confirm("Delete this poll?") && act.run(`del${pl.id}`, () => del(`/api/polls/${pl.id}`))}>Delete</button>
              {/if}
            </span>
            {#if !pl.archived_at}<label class="check"><input type="checkbox" checked={pl.show_results} disabled={act.is(`sr${pl.id}`)} onchange={(e) => toggleShowResults(pl, e.currentTarget)} /> Show results on start</label>{/if}
          </div>{/if}
        </li>
      {/if}
    {:else}<li class="empty">{archivedView ? "No archived polls. Polls that have been run can be archived to keep their results out of new sessions." : "No polls yet. Add one per slide, or one for any slide."}</li>{/each}
  </ul>
</section>

<style>
  .rows > li.poll { grid-template-columns: 8rem minmax(0, 1fr) auto; align-items: start; gap: 4px 2ch; }
  .thumb { aspect-ratio: 16 / 9; outline: 1px solid var(--line); overflow: hidden; }
  .any { display: grid; place-items: center; height: 100%; font-stretch: 75%; font-size: 0.8rem; color: var(--dim); border: 1px dashed var(--line); }
  .body { display: grid; gap: 2px; min-width: 0; overflow-wrap: anywhere; }
  .opts { font-size: 0.9em; }
  .ctl { display: grid; justify-items: end; gap: 4px; }
  .ctl .links { justify-content: flex-end; }
  @media (max-width: 760px) {
    .rows > li.poll { grid-template-columns: 5rem minmax(0, 1fr); }
    .ctl { grid-column: 1 / -1; justify-items: start; }
    .ctl .links { justify-content: flex-start; }
  }
</style>
