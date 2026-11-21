<script lang="ts">
  // a route that needs its param: rendering it without one throws, as an edition's pages may
  let { page }: { page: string } = $props();
</script>

<h1>Param {page.toUpperCase()}</h1>
