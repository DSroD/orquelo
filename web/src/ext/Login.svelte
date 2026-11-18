<script lang="ts">
  import { ApiError, post } from "../lib/api";
  import { navigate, safeReturnTo } from "../lib/router";
  import type { PasswordLogin } from "../lib/types";
  import { genericMessage } from "./errors";

  const returnTo = safeReturnTo(new URLSearchParams(location.search).get("return_to"));

  let email = $state("");
  let password = $state("");
  let error = $state("");
  let busy = $state(false);

  function message(e: unknown): string {
    if (e instanceof ApiError) {
      if (e.status === 401) return "Wrong email or password.";
      if (e.status === 403 && e.error === "suspended") return "This account is suspended. Contact the person who runs this Orquelo.";
      if (e.status === 422) return "Enter your email and password.";
    }
    return genericMessage(e);
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    busy = true; error = "";
    try {
      const body: PasswordLogin = { email: email.trim(), password };
      await post("/auth/password", body);
      navigate(returnTo);
    } catch (err) {
      error = message(err);
    } finally { busy = false; }
  }
</script>

<svelte:head><title>Log in · Orquelo</title></svelte:head>

<main class="page login">
  <h1>Log in</h1>
  <p class="muted">Accounts are created by the person who runs this Orquelo.</p>
  <form class="stack" onsubmit={submit}>
    <label class="f">Email<input type="email" bind:value={email} required autocomplete="username" /></label>
    <label class="f">Password<input type="password" bind:value={password} required autocomplete="current-password" /></label>
    <div><button class="btn primary" disabled={busy}>Log in</button></div>
    {#if error}<p class="err" role="alert">{error}</p>{/if}
  </form>
</main>

<style>
  .login { max-width: 26rem; margin-top: 12vh; }
</style>
