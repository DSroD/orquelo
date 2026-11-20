<script lang="ts">
  import { post } from "../lib/api";
  import type { NavigationLink } from "../lib/ext";
  import { navigate } from "../lib/router";
  import { useSession } from "../lib/presenter-session.svelte";

  let { path, home, links = [] }: { path: string; home: string; links?: readonly NavigationLink[] } = $props();
  const session = useSession();
  const me = $derived(session.lastKnownUser);
  let busy = $state(false);
  let error = $state(false);

  async function logout() {
    busy = true;
    error = false;
    try {
      await post("/auth/logout");
      session.clear();
      navigate("/login");
    } catch {
      error = true;
    } finally {
      busy = false;
    }
  }
</script>

<header class="site-header">
  <div class="inner">
    <a class="skip" href="#page-content">Skip to content</a>
    <a class="brand" href={home} aria-label="Orquelo home">orquelo<span aria-hidden="true">.</span></a>
    <nav aria-label="Main navigation">
      {#if me}<a href="/decks" aria-current={path === "/decks" ? "page" : undefined}>Decks</a>{/if}
      {#each links as link (link.href)}
        {#if !link.when || (link.when === "signed-in" ? me : me === null)}
          <a href={link.href} aria-current={path === link.href ? "page" : undefined}>{link.label}</a>
        {/if}
      {/each}
      {#if me}
        <button class="lnk" type="button" disabled={busy} onclick={logout}>Log out</button>
      {:else if me === null && path !== "/login"}
        <a href="/login">Log in</a>
      {/if}
    </nav>
    {#if error}<p class="err" role="alert">Could not log out. Try again.</p>{/if}
  </div>
</header>

<style>
  .site-header { border-bottom: 1px solid var(--line); }
  .inner { max-width: 76rem; min-height: 64px; margin: 0 auto; padding: 0 16px; display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 0 16px; }
  .brand { font-size: 1.35rem; font-weight: 600; text-decoration: none; color: var(--fg); font-stretch: 112.5%; }
  .brand span { color: var(--amber); }
  nav { display: flex; flex-wrap: wrap; gap: 0 16px; }
  a, button { display: inline-flex; align-items: center; min-height: 48px; }
  a[aria-current="page"] { color: var(--fg); }
  .err { flex-basis: 100%; padding-bottom: 8px; }
  .skip { position: absolute; top: -100px; padding: 0 12px; background: var(--bg); z-index: 2; }
  .skip:focus { top: 8px; }
</style>
