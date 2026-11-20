<script lang="ts">
  import { tick } from "svelte";
  import { match } from "./lib/router";
  import Audience from "./Audience.svelte";
  import SignedIn from "./decks/SignedIn.svelte";
  import SiteHeader from "./components/SiteHeader.svelte";
  import { provideSession } from "./lib/presenter-session.svelte";
  import ext from "$ext";
  // Students only load the audience view; pdf.js and the signed-in pages come with the routes that use them
  // (SignedIn, the tiny auth wrapper, is bundled here).
  const Screen = () => import("./Screen.svelte");
  const List = () => import("./decks/List.svelte");
  const Editor = () => import("./decks/Editor.svelte");
  const Live = () => import("./decks/Live.svelte");
  const Results = () => import("./decks/Results.svelte");

  let path = $state(location.pathname);
  const route = $derived(match(path, ext.routes));
  const presenterSession = $derived(route.name !== "audience" && route.name !== "screen");
  provideSession(() => presenterSession ? path : null);

  // signed-in + audience share the .term theme; the projector page keeps the plain document
  $effect(() => {
    document.documentElement.classList.toggle("term", route.name !== "screen");
  });

  // an edition without a home page sends / to the decks
  $effect(() => {
    if (route.name === "home" && !ext.Home) { history.replaceState(null, "", "/decks"); path = "/decks"; }
  });

  $effect(() => {
    const sync = () => (path = location.pathname);
    // SPA navigation for same-origin links, except /auth and /api which are server routes
    const click = async (e: MouseEvent) => {
      const a = (e.target as Element).closest("a");
      if (!a || e.defaultPrevented || e.metaKey || e.ctrlKey || e.shiftKey || a.target || a.hasAttribute("download")) return;
      const u = new URL(a.href, location.href);
      if (u.origin !== location.origin || /^\/(api|auth)\//.test(u.pathname)) return;
      if (u.pathname === location.pathname && u.search === location.search && u.hash) return;
      e.preventDefault();
      history.pushState(null, "", u.pathname + u.search + u.hash);
      sync();
      await tick();
      if (u.hash) document.getElementById(u.hash.slice(1))?.scrollIntoView();
      else window.scrollTo(0, 0);
    };
    window.addEventListener("popstate", sync);
    document.addEventListener("click", click);
    return () => { window.removeEventListener("popstate", sync); document.removeEventListener("click", click); };
  });
</script>

{#snippet failed()}
  <main class="nf"><h1>Could not load this page</h1><p class="muted">The app may have been updated. <a href={location.href}>Reload</a></p></main>
{/snippet}

{#snippet page()}
  {#if route.name === "home"}
    {#if ext.Home}{#await ext.Home() then { default: C }}<C />{:catch}{@render failed()}{/await}{/if}
  {:else if route.name === "ext"}
    {#await ext.routes[route.i].load() then { default: C }}{#key path}<C {...(route.params as any)} />{/key}{:catch}{@render failed()}{/await}
  {:else if route.name === "audience"}
    {#key `${route.pid}/${route.code}`}<Audience pid={route.pid} code={route.code} />{/key}
  {:else if route.name === "screen"}
    {#await Screen() then { default: C }}{#key `${route.pid}/${route.code}`}<C pid={route.pid} code={route.code} />{/key}{:catch}{@render failed()}{/await}
  {:else if route.name === "login"}
    {#await ext.Login() then { default: C }}<C />{:catch}{@render failed()}{/await}
  {:else if route.name === "decks"}
    {#await List() then { default: C }}<SignedIn>{#snippet children(me)}<C {me} />{/snippet}</SignedIn>{:catch}{@render failed()}{/await}
  {:else if route.name === "deck"}
    {#await Editor() then { default: C }}{#key route.id}<SignedIn>{#snippet children(me)}<C id={route.id} {me} />{/snippet}</SignedIn>{/key}{:catch}{@render failed()}{/await}
  {:else if route.name === "session-live"}
    {#await Live() then { default: C }}{#key route.code}<SignedIn><C code={route.code} /></SignedIn>{/key}{:catch}{@render failed()}{/await}
  {:else if route.name === "session-results"}
    {#await Results() then { default: C }}{#key route.code}<SignedIn><C code={route.code} /></SignedIn>{/key}{:catch}{@render failed()}{/await}
  {:else}
    <main class="nf"><h1>Page not found</h1><p class="muted">Check the link you were given.</p></main>
  {/if}
{/snippet}

{#if presenterSession}
  <SiteHeader {path} home={ext.Home ? "/" : "/decks"} links={ext.navigation} />
  <div id="page-content" tabindex="-1">{@render page()}</div>
{:else}
  {@render page()}
{/if}

<style>
  #page-content:focus { outline: none; }
  .nf { max-width: 28rem; margin: 20vh auto; padding: 0 16px; text-align: center; }
</style>
