<script lang="ts">
  import type { Snippet } from "svelte";
  import { ApiError, requireUser } from "../lib/api";
  import type { Me } from "../lib/types";

  let { children }: { children: Snippet<[me: Me]> } = $props();
  let me = $state<Me | null>(null);
  let failure = $state<ApiError | Error | null>(null);
  $effect(() => { requireUser().then((m) => (me = m), (e) => (failure = e)); });
</script>

{#if me}
  {@render children(me)}
{:else if failure}
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
