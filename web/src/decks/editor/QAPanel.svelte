<script lang="ts">
  import { put } from "../../lib/api";
  import type { Actions } from "../../lib/actions.svelte";

  let { enabled, canEdit, base, act }: { enabled: boolean; canEdit: boolean; base: string; act: Actions } = $props();

  function toggle(box: HTMLInputElement) {
    void act.run("qa", async () => {
      try { await put(`${base}/qa`, { enabled: box.checked }); }
      catch (e) { box.checked = enabled; throw e; }
    });
  }
</script>

<section class="stack" aria-labelledby="qa-h">
  <h2 id="qa-h" class="rule">Questions from the audience</h2>
  <label class="check"><input type="checkbox" checked={enabled} disabled={!canEdit || act.is("qa")} onchange={(e) => toggle(e.currentTarget)} /> Allow Q&A</label>
  <p class="muted">Applies to new sessions. Open submissions from session controls when you are ready.</p>
  <p>Questions go to a private moderator inbox. Participants see only their own questions; you choose which question to show on the projector.</p>
</section>

<style>
  :global(.term) label.check { min-height: 48px; }
  p { max-width: 70ch; }
</style>
