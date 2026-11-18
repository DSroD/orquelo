<script lang="ts">
  import { useResource } from "../lib/resource.svelte";
  import Crumbs from "../components/Crumbs.svelte";
  import { formatDuration, formatParticipation, formatSeconds, NONE } from "../lib/results";
  import BarList from "../components/BarList.svelte";
  import { slug } from "../lib/slug";
  import { localDateTime, localTime } from "../lib/time";
  import type { SessionResults } from "../lib/types";

  let { code }: { code: string } = $props();
  const res = useResource<SessionResults>(() => `/api/sessions/${code}/results`);
  const data = $derived(res.data);
  const error = $derived(res.error);

  const NOT_RECORDED = "Not recorded for sessions before this feature";
  const num = (n: number | null) => (n === null ? NONE : String(n));
  const summary = $derived(data ? [
    ["Unique voters", String(data.summary.unique_voters), false],
    ["Peak audience", num(data.summary.peak_audience), data.summary.peak_audience === null],
    ["Polls run", String(data.summary.runs), false],
    ["Avg participation", formatParticipation(data.summary.avg_participation), data.summary.avg_participation === null],
    ["Median time to vote", formatSeconds(data.summary.median_seconds_to_vote), data.summary.median_seconds_to_vote === null],
    ["Voters who changed", num(data.summary.changed_voters), data.summary.changed_voters === null],
    ["Answer changes", num(data.summary.changed_votes), data.summary.changed_votes === null],
  ] as [string, string, boolean][] : []);
</script>

<svelte:head><title>Results{data ? ` · ${data.session.label || data.presentation.title}` : ""} · Orquelo</title></svelte:head>

<div class="page">
  {#if res.status === 403}
    <h1>No access to results</h1>
    <p class="muted">The owner of this deck has not given you the results permission.</p>
  {:else if error}
    <p class="err" role="alert">{error}</p>
  {:else if !data}
    <p class="muted">Loading…</p>
  {:else}
    <Crumbs trail={[
      { label: "~ / decks", href: "/decks" },
      { label: slug(data.presentation.title), href: `/decks/${data.presentation.id}` },
      { label: slug(data.session.label || "session"), href: `/sessions/${code}` },
      { label: "results" },
    ]} />
    <header class="bar between head">
      <div class="stack">
        <h1>{data.presentation.title}</h1>
        <p class="muted data">{data.session.label || "Session"} · {localDateTime(data.session.started_at)}</p>
      </div>
      <nav class="bar" aria-label="Downloads">
        <a class="btn sm primary" href="/api/sessions/{code}/results.csv" download>Results CSV</a>
        <a class="btn sm" href="/api/sessions/{code}/export.csv" download>Raw votes CSV</a>
        {#if data.qa.enabled}<a class="btn sm" href="/api/sessions/{code}/qa.csv" download>Q&A CSV</a>{/if}
      </nav>
    </header>

    <section class="stack" aria-labelledby="sum-h">
      <h2 id="sum-h" class="rule">Summary</h2>
      <dl class="kv">
        {#each summary as [name, value, missing] (name)}
          <dt>{name}</dt>
          <dd title={missing ? NOT_RECORDED : undefined}>{value}</dd>
        {/each}
      </dl>
    </section>

    {#each data.runs as r (r.run_id)}
      <section class="stack" aria-labelledby="run{r.run_id}">
        <h2 id="run{r.run_id}" class="rule q">{r.question}</h2>
        <p class="muted data facts">
          <span class="tag">{r.kind}</span>
          {#if r.slide !== null}<span>slide {r.slide}</span>{/if}
          <span>{localTime(r.opened_at)} · {r.closed_at === null ? "open" : formatDuration(r.opened_at, r.closed_at)}</span>
          <span>{r.total_voters} / {num(r.peak_audience)} voted ({formatParticipation(r.participation)})</span>
          <span title={r.median_seconds_to_vote === null ? NOT_RECORDED : undefined}>median {formatSeconds(r.median_seconds_to_vote)}</span>
          <span title={r.changed_voters === null ? NOT_RECORDED : undefined}>changed {num(r.changed_voters)}</span>
        </p>
        <BarList options={r.options} total={r.total_voters} kind={r.kind} />
      </section>
    {:else}
      <p class="muted">No polls were run in this session.</p>
    {/each}
    {#if data.qa.enabled}
      <section class="stack" aria-labelledby="qa-results-h">
        <h2 id="qa-results-h" class="rule">Q&A</h2>
        <ol class="questions">
          {#each data.qa.questions as q (q.id)}
            <li class="stack"><p class="muted data">{localTime(q.created_at)} · {q.status}</p><p class="question-text">{q.text}</p></li>
          {:else}<li class="muted">No questions were submitted.</li>{/each}
        </ol>
      </section>
    {/if}
  {/if}
</div>

<style>
  .questions { list-style: none; margin: 0; padding: 0; }
  .questions li { padding: 16px 0; border-bottom: 1px solid var(--line); }
  .question-text { white-space: pre-wrap; overflow-wrap: anywhere; }
  .facts { display: flex; flex-wrap: wrap; gap: 2px 2ch; font-size: 0.85rem; }
  .rule { align-items: baseline; }
  .rule.q { color: var(--fg); font-weight: 600; }
</style>
