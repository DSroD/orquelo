<script lang="ts">
  import { del, put } from "../../lib/api";
  import { actions } from "../../lib/actions.svelte";
  import { useResource } from "../../lib/resource.svelte";
  import type { Share } from "../../lib/types";

  let { base }: { base: string } = $props();

  const FLAGS = ["edit", "moderate", "copy", "results"] as const;
  type Flags = Pick<Share, (typeof FLAGS)[number]>;
  const NONE: Flags = { edit: false, moderate: false, copy: false, results: false };

  const url = $derived(`${base}/shares`);
  const res = useResource<Share[]>(() => url);
  const act = actions({ reload: res.reload });
  const flagsOf = (s: Share): Flags => ({ edit: s.edit, moderate: s.moderate, copy: s.copy, results: s.results });

  let email = $state("");
  let fresh = $state<Flags>({ ...NONE });

  const add = (e: SubmitEvent) => {
    e.preventDefault();
    act.run("add", async () => { await put(`${url}/${encodeURIComponent(email.trim())}`, fresh); email = ""; fresh = { ...NONE }; });
  };
  const setFlag = (s: Share, f: (typeof FLAGS)[number], on: boolean) =>
    act.run(`set${s.email}`, () => put(`${url}/${encodeURIComponent(s.email)}`, { ...flagsOf(s), [f]: on }));
  const remove = (s: Share) => act.run(`rm${s.email}`, () => del(`${url}/${encodeURIComponent(s.email)}`));
</script>

<section class="stack" aria-labelledby="share-h">
  <h2 id="share-h" class="rule">Share this deck</h2>
  <p class="muted">Anyone with a share can view the deck. The email must be the one they log in with. Results include personal data, so they are a separate permission.</p>
  {#if act.error || res.error}<p class="err" role="alert">{act.error || res.error}</p>{/if}

  <form class="stack" onsubmit={add}>
    <label class="f">Email<input type="email" bind:value={email} required autocomplete="off" placeholder="colleague@example.org" /></label>
    <div class="bar">
      {#each FLAGS as f (f)}<label class="check"><input type="checkbox" bind:checked={fresh[f]} /> {f}</label>{/each}
      <button class="btn" disabled={!email || act.is("add")}>Share</button>
    </div>
  </form>

  <ul class="rows">
    {#each res.data ?? [] as s (s.email)}
      <li class="share">
        <span class="data who">{s.email}</span>
        <span class="bar">
          {#each FLAGS as f (f)}
            <label class="check"><input type="checkbox" checked={s[f]} disabled={act.is(`set${s.email}`)} onchange={(e) => setFlag(s, f, e.currentTarget.checked)} /> {f}</label>
          {/each}
          <button class="lnk danger" disabled={act.is(`rm${s.email}`)} aria-label="Remove {s.email}" onclick={() => remove(s)}>Remove</button>
        </span>
      </li>
    {:else}<li class="empty">{res.data ? "Not shared with anyone." : "Loading…"}</li>{/each}
  </ul>
</section>

<style>
  .who { overflow-wrap: anywhere; }
</style>
