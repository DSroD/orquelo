<script lang="ts">
  import { ApiError, del, patch, post } from "../../lib/api";
  import type { Actions } from "../../lib/actions.svelte";
  import { limitMessage } from "../../lib/quota";
  import { navigate } from "../../lib/router";
  import type { Me, Presentation } from "../../lib/types";
  import type { Detail } from "./detail";

  let { deck, base, act, me }: { deck: Detail; base: string; act: Actions; me: Me } = $props();
  const access = $derived(deck.access);

  // deck is replaced on every reload; the server title only propagates when it changes,
  // so what the user is typing survives unrelated reloads
  const server = $derived(deck.title);
  let title = $derived(server);

  // deleting a deck with sessions also deletes their votes, so the owner has to type the title
  let confirming = $state(false);
  let typed = $state("");
  const hasSessions = $derived(deck.sessions.length > 0);

  const reallyDelete = () => act.run("delpres", async () => {
    try { await del(base); }
    catch (e) { throw e instanceof ApiError && e.error === "session_live" ? new Error("End the live session first") : e; }
    navigate("/decks");
    return "left";
  });
  const removeDeck = () => {
    if (hasSessions) confirming = true;
    else if (confirm("Delete this presentation?")) reallyDelete();
  };

  // the copy is a new deck owned by the user; it can fail on the user's limits
  const copyDeck = () => act.run("copy", async () => {
    try { navigate(`/decks/${(await post<Presentation>(`${base}/copy`)).id}`); }
    catch (e) { throw new Error(limitMessage(e, me.membership)); }
    return "left";
  });
</script>

<div class="bar between">
  {#if access.edit}
    <h1 class="sr">{deck.title}</h1>
    <form class="bar title" onsubmit={(e) => { e.preventDefault(); act.run("rename", () => patch(base, { title })); }}>
      <input class="h" bind:value={title} maxlength="200" aria-label="Title" />
      <button class="btn sm" disabled={title === deck.title || !title || act.is("rename")}>Rename</button>
    </form>
  {:else}
    <h1 class="title">{deck.title}</h1>
  {/if}
  <div class="bar">
    <span class="muted data">{deck.page_count} slides</span>
    {#if access.copy}<button class="btn sm" disabled={act.is("copy")} onclick={copyDeck}>Copy to my decks</button>{/if}
    {#if access.owner && !deck.disabled}
      <button class="btn sm" disabled={act.is("archive")} onclick={() => act.run("archive", () => post(`${base}/${deck.archived_at ? "unarchive" : "archive"}`))}>{deck.archived_at ? "Unarchive" : "Archive"}</button>
    {/if}
    {#if access.owner}<button class="btn sm danger" disabled={act.is("delpres")} onclick={removeDeck}>Delete</button>{/if}
  </div>
</div>
{#if confirming}
  <form class="stack confirm" onsubmit={(e) => { e.preventDefault(); reallyDelete(); }}>
    <p class="err" role="alert">All sessions and votes of this deck will be permanently deleted. Type the deck title to confirm.</p>
    <div class="bar">
      <input bind:value={typed} aria-label="Type the deck title to confirm" placeholder={deck.title} autocomplete="off" />
      <button class="btn sm danger" disabled={typed !== deck.title || act.is("delpres")}>Delete permanently</button>
      <button type="button" class="lnk" onclick={() => { confirming = false; typed = ""; }}>Cancel</button>
    </div>
  </form>
{/if}

<style>
  .confirm { padding: 12px; border: 1px solid var(--red); }
  .title { flex: 1; min-width: 0; flex-wrap: nowrap; }
  .title .h { flex: 1; min-width: 0; font-size: 1.15rem; font-weight: 600; font-stretch: 112.5%; }
  @media (max-width: 760px) { .title { flex: 1 1 100%; } }
</style>
