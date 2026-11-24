<script lang="ts">
  import { ApiError, put } from "../lib/api";
  import { loginRedirect } from "../lib/expired";
  import type { PasswordChange } from "../lib/types";
  import AccountPage from "../components/AccountPage.svelte";
  import { genericMessage } from "./errors";

  let current = $state("");
  let next = $state("");
  let repeat = $state("");
  let error = $state("");
  let done = $state(false);
  let busy = $state(false);

  function message(e: unknown): string {
    if (e instanceof ApiError) {
      if (e.status === 401 && e.error === "invalid_credentials") return "The current password is wrong.";
      if (e.status === 422) return "The new password must be 10 to 1024 characters.";
    }
    return genericMessage(e);
  }

  async function change(e: SubmitEvent) {
    e.preventDefault();
    error = ""; done = false;
    if (next !== repeat) { error = "The new passwords do not match."; return; }
    busy = true;
    try {
      const body: PasswordChange = { current, new: next };
      await put("/api/me/password", body);
      current = next = repeat = "";
      done = true;
    } catch (err) {
      // a 401 is an expired session unless it is the wrong current password
      const to = err instanceof ApiError && err.error === "invalid_credentials" ? null : loginRedirect(err, location.pathname);
      if (to) location.href = to;
      else error = message(err);
    } finally { busy = false; }
  }
</script>

<AccountPage>
  {#snippet children(me)}
    <p><a href="/connected-apps">Connected apps</a></p>
    <form class="stack" onsubmit={change}>
      <h2>Change password</h2>
      <input class="sr-only" type="text" value={me.user.email ?? me.user.name} readonly autocomplete="username" aria-hidden="true" tabindex="-1" />
      <label class="f">Current password<input type="password" bind:value={current} required autocomplete="current-password" /></label>
      <label class="f">New password<input type="password" bind:value={next} required minlength="10" maxlength="1024" autocomplete="new-password" /></label>
      <label class="f">Repeat new password<input type="password" bind:value={repeat} required minlength="10" maxlength="1024" autocomplete="new-password" /></label>
      <div><button class="btn primary" disabled={busy}>Change password</button></div>
      {#if error}<p class="err" role="alert">{error}</p>{/if}
      {#if done}<p role="status">Password changed. Your other browsers were signed out.</p>{/if}
    </form>
  {/snippet}
</AccountPage>

<style>
  form { max-width: 26rem; }
  .sr-only { position: absolute; width: 1px; height: 1px; opacity: 0; overflow: hidden; }
</style>
