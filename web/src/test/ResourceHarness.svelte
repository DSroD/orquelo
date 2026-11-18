<script lang="ts">
  import { useResource } from "../lib/resource.svelte";

  let { url }: { url: string | null } = $props();
  const res = useResource<string>(() => url);
</script>

<output aria-label="data">{res.data ?? ""}</output>
<output aria-label="error">{res.error}</output>
<button onclick={() => res.reload()}>reload</button>
