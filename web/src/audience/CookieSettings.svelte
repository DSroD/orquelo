<script lang="ts">
  import { onMount } from "svelte";
  import { get, post } from "../lib/api";
  import { actions } from "../lib/actions.svelte";

  let { prompt = false }: { prompt?: boolean } = $props();

  type Choice = { remember: boolean | null };
  const endpoint = "/api/s/cookies";
  const act = actions();
  let choice = $state<Choice>();
  let expanded = $state(false);
  let summary: HTMLElement;
  const needsChoice = $derived(prompt && choice?.remember === null);
  const busy = $derived(act.is("load") || act.is("save"));

  onMount(() => {
    void act.run("load", async () => {
      choice = await get<Choice>(endpoint);
      if (prompt && choice.remember === null) expanded = true;
    });
  });

  function save(remember: boolean) {
    void act.run("save", async () => {
      choice = await post<Choice>(endpoint, { remember });
      if (prompt) {
        expanded = false;
        summary?.focus();
      }
    });
  }
</script>

<details bind:open={expanded}>
  <summary bind:this={summary} onclick={(event) => { if (needsChoice) event.preventDefault(); }}>Cookie settings</summary>
  <p>Orquelo uses a cookie for this live session so you can change your vote and see your questions. You can optionally let Orquelo recognise your browser across future sessions for up to a year. That can link responses across sessions, including in vote exports. You can change this choice here at any time.</p>
  <div class="choices">
    <button type="button" class="btn" disabled={busy} onclick={() => save(false)}>Only this session</button>
    <button type="button" class="btn" disabled={busy} onclick={() => save(true)}>Allow across sessions</button>
  </div>
  {#if choice && typeof choice.remember === "boolean"}
    <p role="status">{choice.remember ? "Cross-session recognition is on." : "Cross-session recognition is off."}</p>
  {/if}
  {#if act.error}<p role="alert">Could not update cookie settings. Please try again.</p>{/if}
</details>

<style>
  details { padding-block: 12px; font-size: 0.875rem; }
  summary { cursor: pointer; width: fit-content; min-height: 48px; align-content: center; }
  p { margin-block: 8px; }
  .choices { display: flex; flex-wrap: wrap; gap: 8px; }
  .choices button { min-height: 48px; }
</style>
