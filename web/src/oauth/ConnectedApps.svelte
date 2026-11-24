<script lang="ts">
  import { ApiError, del, get } from "../lib/api";
  import { loginRedirect } from "../lib/expired";
  import { genericMessage } from "../ext/errors";
  import { localDate } from "../lib/time";
  import type { OAuthGrant } from "../lib/types";

  let grants = $state<OAuthGrant[] | null>(null);
  let error = $state("");
  let busy = $state<string | null>(null);

  $effect(() => {
    get<OAuthGrant[]>("/api/oauth/grants").then((g) => (grants = g), (e) => (error = genericMessage(e)));
  });

  async function disconnect(g: OAuthGrant) {
    busy = g.id; error = "";
    try {
      await del(`/api/oauth/grants/${g.id}`);
    } catch (e) {
      const to = loginRedirect(e, location.pathname);
      if (to) { location.href = to; return; }
      if (!(e instanceof ApiError && e.status === 404)) { error = genericMessage(e); busy = null; return; }
    }
    grants = grants!.filter((x) => x.id !== g.id);
    busy = null;
  }
</script>

<svelte:head><title>Connected apps · Orquelo</title><meta name="robots" content="noindex" /></svelte:head>

<main class="page apps">
  <h1>Connected apps</h1>
  {#if error}<p class="err" role="alert">{error}</p>{/if}
  {#if grants}
    <ul class="rows">
      {#each grants as g (g.id)}
        <li>
          <div class="head">
            <strong class="name">{g.client.verified ? g.client.host : g.client.name}</strong>
            {#if !g.client.verified}<span class="tag warn">unverified</span>{/if}
            {#if g.needs_reconnect}<span class="tag warn">reconnect needed</span>{/if}
          </div>
          {#if g.client.verified}<span class="muted">calls itself “{g.client.name}”</span>{/if}
          <span class="muted">Access: {g.scopes.join(", ")}</span>
          <span class="muted">Connected {localDate(g.created_at)}{g.last_used_at ? ` · last used ${localDate(g.last_used_at)}` : ""}</span>
          <div><button class="btn sm danger" disabled={busy === g.id} onclick={() => disconnect(g)}>Disconnect</button></div>
        </li>
      {:else}
        <li class="empty">No apps are connected.</li>
      {/each}
    </ul>
  {/if}
</main>

<style>
  .apps { max-width: 44rem; }
  .head { display: flex; gap: 8px; flex-wrap: wrap; align-items: baseline; }
  .name { overflow-wrap: anywhere; }
</style>
