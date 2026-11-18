<script lang="ts">
  import { actions } from "../lib/actions.svelte";
  import { useResource } from "../lib/resource.svelte";
  import { slug } from "../lib/slug";
  import Crumbs from "../components/Crumbs.svelte";
  import Tabs from "../components/Tabs.svelte";
  import DeckHeader from "./editor/DeckHeader.svelte";
  import QAPanel from "./editor/QAPanel.svelte";
  import PollsPanel from "./editor/PollsPanel.svelte";
  import SessionsPanel from "./editor/SessionsPanel.svelte";
  import SharePanel from "./editor/SharePanel.svelte";
  import type { Me } from "../lib/types";
  import type { Detail } from "./editor/detail";

  let { id, me }: { id: number; me: Me } = $props();

  const base = $derived(`/api/decks/${id}`);
  const res = useResource<Detail>(() => base);
  const act = actions({ reload: res.reload });
  const d = $derived(res.data);
  // Sessions is the phone-first job (start, control, share), so the page always opens on it
  type Tab = "sessions" | "polls" | "qa" | "share";
  const tabs = $derived<readonly Tab[]>(d?.access.owner ? ["sessions", "polls", "qa", "share"] : ["sessions", "polls", "qa"]);
  let current = $state<Tab>("sessions");
  const label = (t: Tab) => (t === "sessions" ? "Sessions" : t === "polls" ? "Polls" : t === "qa" ? "Q&A" : "Share");
  const activePolls = $derived(d ? d.polls.filter((pl) => pl.archived_at === null).length : 0);
  const hasLive = $derived(d ? d.sessions.some((s) => !s.ended_at) : false);
</script>

<svelte:head><title>{d ? d.title : "Presentation"} · Orquelo</title></svelte:head>

<div class="page">
  <Crumbs trail={[{ label: "~ / decks", href: "/decks" }, { label: d ? slug(d.title) : "…" }]} />
  {#if act.error || res.error}<p class="err" role="alert">{act.error || res.error}</p>{/if}
  {#if d}
    <DeckHeader deck={d} {base} {act} {me} />

    <Tabs {tabs} bind:selected={current} label="Deck">
      {#snippet tab(t)}
        {label(t)}{#if t === "sessions" || t === "polls"}<span class="n data">{t === "sessions" ? d.sessions.length : activePolls}</span>{/if}{#if t === "sessions" && hasLive}<span class="tag live">live</span>{/if}
      {/snippet}
    </Tabs>

    <div class="stack panel" role="tabpanel" id="panel-sessions" aria-labelledby="tab-sessions" hidden={current !== "sessions"}>
      <SessionsPanel sessions={d.sessions} {base} {act} access={d.access} />
    </div>

    <div class="stack panel" role="tabpanel" id="panel-polls" aria-labelledby="tab-polls" hidden={current !== "polls"}>
      <PollsPanel polls={d.polls} pdf="{base}/pdf" pageCount={d.page_count} {base} {act} reload={res.reload} canEdit={d.access.edit} />
    </div>

    <div class="stack panel" role="tabpanel" id="panel-qa" aria-labelledby="tab-qa" hidden={current !== "qa"}>
      <QAPanel enabled={d.qa_enabled} canEdit={d.access.edit} {base} {act} />
    </div>

    {#if d.access.owner}
      <div class="stack panel" role="tabpanel" id="panel-share" aria-labelledby="tab-share" hidden={current !== "share"}>
        <SharePanel {base} />
      </div>
    {/if}
  {/if}
</div>

<style>
  .panel[hidden] { display: none; }
  @media (max-width: 480px) {
    .page :global(.tabs .n), .page :global(.tabs .tag) { display: none; }
    .page :global(.tabs [role="tab"]) { padding-inline: 10px; }
  }
</style>
