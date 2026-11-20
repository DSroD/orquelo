<script lang="ts">
  import type { Snippet } from "svelte";
  import { ApiError } from "../lib/api";
  import { loginRedirect } from "../lib/expired";
  import { useSession } from "../lib/presenter-session.svelte";
  import type { Me } from "../lib/types";

  let { children }: { children: Snippet<[me: Me]> } = $props();
  const session = useSession();
  const me = $derived(session.me);
  const failure = $derived(session.failure);
  $effect(() => {
    const to = loginRedirect(failure, location.pathname);
    if (to) location.href = to;
  });
</script>

{#if me}
  {@render children(me)}
{:else if failure && me !== null}
  <main class="nf">
    {#if failure instanceof ApiError && failure.error === "suspended"}
      <h1>Account suspended</h1>
      <p class="muted">This account can no longer use Orquelo. Contact the person who runs this service.</p>
    {:else}
      <h1>Could not load your account</h1>
      <p class="err" role="alert">{failure.message}</p>
    {/if}
  </main>
{/if}

<style>
  .nf { max-width: 28rem; margin: 20vh auto; padding: 0 16px; text-align: center; display: grid; gap: 12px; }
</style>
