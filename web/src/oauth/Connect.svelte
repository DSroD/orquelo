<script lang="ts">
  import { ApiError, get, post } from "../lib/api";
  import { loginRedirect } from "../lib/expired";
  import { genericMessage } from "../ext/errors";
  import type { OAuthRedirect, OAuthRequest } from "../lib/types";

  let { id }: { id: string } = $props();
  const url = $derived(`/api/oauth/requests/${id}`);

  let request = $state<OAuthRequest | null>(null);
  let chosen = $state<string[]>([]);
  let gone = $state(false);
  let error = $state("");
  let busy = $state(false);

  const GONE = "This request has expired or was already used — start connecting again from your app.";
  const framed = window.top !== window.self;
  const LOOPBACK = ["127.0.0.1", "localhost", "[::1]", "::1"];
  const loopback = $derived(request ? LOOPBACK.includes(request.redirect_host) : false);
  const offered = $derived(request?.scopes.filter((s) => s.requested) ?? []);

  $effect(() => {
    if (framed) return;
    get<OAuthRequest>(url).then(
      (r) => { request = r; chosen = r.scopes.filter((s) => s.requested).map((s) => s.name); },
      fail,
    );
  });

  function fail(e: unknown) {
    const to = loginRedirect(e, location.pathname);
    if (to) { location.href = to; return; }
    if (e instanceof ApiError && e.status === 404) gone = true;
    else error = genericMessage(e);
  }

  async function answer(path: "approve" | "deny", body?: unknown) {
    busy = true; error = "";
    try {
      const r = await post<OAuthRedirect>(`${url}/${path}`, body);
      location.assign(r.redirect_to);
    } catch (e) {
      fail(e);
      busy = false;
    }
  }

  const approve = () => answer("approve", { scopes: offered.filter((s) => chosen.includes(s.name)).map((s) => s.name) });
</script>

<svelte:head><title>Connect an app · Orquelo</title><meta name="robots" content="noindex" /></svelte:head>

<main class="page connect">
  {#if framed}
    <h1>Open this page directly</h1>
    <p>For your safety, this page cannot be used inside another page. Open it in its own tab.</p>
  {:else if gone}
    <h1>Request not found</h1>
    <p role="alert">{GONE}</p>
  {:else if request}
    {@const c = request.client}
    <h1>Connect an app to Orquelo</h1>
    <div class="stack">
      {#if c.verified}
        <p class="who">{c.host}</p>
        <p class="muted">calls itself “{c.name}”</p>
      {:else}
        <p class="who">{c.name} <span class="tag warn">unverified</span></p>
        <p class="muted">This app did not prove who it is. Only continue if you started this yourself.</p>
      {/if}
      <p class="muted">After you decide, you will be sent back to <strong>{request.redirect_host}</strong>.</p>
      {#if loopback}
        <p class="muted">You'll be sent back to an app on this device.</p>
      {:else if request.redirect_host_differs}
        <p class="err" role="alert">Careful: that address is not the app's own site.</p>
      {/if}
    </div>
    <fieldset class="stack">
      <legend>Allow this app to</legend>
      {#each offered as s (s.name)}
        <label class="scope">
          <input type="checkbox" value={s.name} bind:group={chosen} />
          <span>{s.description}</span>
        </label>
      {/each}
    </fieldset>
    <div class="actions">
      <button class="btn primary" disabled={busy || chosen.length === 0} onclick={approve}>Approve</button>
      <button class="btn" disabled={busy} onclick={() => answer("deny")}>Deny</button>
    </div>
    {#if error}<p class="err" role="alert">{error}</p>{/if}
  {:else if error}
    <p class="err" role="alert">{error}</p>
  {/if}
</main>

<style>
  .connect { max-width: 34rem; }
  .who { font-size: 1.3em; overflow-wrap: anywhere; margin: 0; }
  fieldset { border: 1px solid var(--line); margin: 0; padding: 12px; }
  .scope { display: flex; gap: 12px; align-items: center; min-height: 48px; }
  .scope input { width: 24px; height: 24px; flex: none; }
  .actions { display: flex; gap: 12px; flex-wrap: wrap; }
  .actions .btn { min-height: 48px; flex: 1 1 8rem; }
</style>
