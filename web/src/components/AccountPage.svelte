<script lang="ts">
  import type { Snippet } from "svelte";
  import type { Me } from "../lib/types";
  import CookieSettings from "../audience/CookieSettings.svelte";
  import SignedIn from "../decks/SignedIn.svelte";

  let { title = "Account", children: details }: { title?: string; children: Snippet<[Me]> } = $props();
</script>

<svelte:head><title>{title} · Orquelo</title><meta name="robots" content="noindex" /></svelte:head>

<SignedIn>
  {#snippet children(me)}
    <main class="page account">
      <h1>{title}</h1>
      <p class="muted identity">{me.user.email ?? me.user.name}</p>
      {@render details(me)}
      <CookieSettings />
    </main>
  {/snippet}
</SignedIn>

<style>
  .account { max-width: 44rem; }
  .identity { overflow-wrap: anywhere; }
</style>
