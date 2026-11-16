<script lang="ts">
  import { onDestroy } from 'svelte';
  import * as Card from '$lib/components/ui/card/index.js';
  import { Badge } from '$lib/components/ui/badge/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { APIError, type Job } from './lib/api';
  import { formatDuration, formatNumber, jobInsights, verificationInsights, type InsightStatus, type VerificationInsight } from './lib/job-insights';

  let { job, loadVerification, onAuthFailure }: { job: Job; loadVerification: (id: string, signal: AbortSignal) => Promise<unknown>; onAuthFailure: (problem: unknown) => void } = $props();
  const jobId = $derived(job.id);
  const insights = $derived(jobInsights(job.result));
  const stageLimit = 10;
  const reportLimit = 20;
  let stagePage = $state(0);
  let pageIndex = $state(0);
  let findingPage = $state(0);
  let flagCounts = $state<Record<number, number>>({});
  let report = $state<VerificationInsight | null>(null);
  let reportState = $state<'idle' | 'loading' | 'loaded' | 'missing' | 'error'>('idle');
  let reportError = $state('');
  let controller: AbortController | undefined;
  let revision = 0;
  let alive = true;
  const active = $derived(job.status === 'queued' || job.status === 'running');
  const stageCount = $derived(insights.metrics?.stages.length ?? 0);
  $effect(() => { if (stagePage > 0 && stagePage * stageLimit >= stageCount) stagePage = 0; });
  const visibleStages = $derived(insights.metrics?.stages.slice(stagePage * stageLimit, (stagePage + 1) * stageLimit) ?? []);
  const visiblePages = $derived(report?.pages.slice(pageIndex * reportLimit, (pageIndex + 1) * reportLimit) ?? []);
  const visibleFindings = $derived(report?.findings.slice(findingPage * reportLimit, (findingPage + 1) * reportLimit) ?? []);

  $effect(() => {
    jobId;
    revision++;
    controller?.abort();
    report = null;
    reportState = 'idle';
    reportError = '';
    stagePage = 0;
    pageIndex = 0;
    findingPage = 0;
    flagCounts = {};
  });

  async function viewReport() {
    if (active || reportState === 'loading') return;
    const id = jobId;
    const request = ++revision;
    controller?.abort();
    const pending = new AbortController();
    controller = pending;
    reportState = 'loading';
    reportError = '';
    try {
      const value = await loadVerification(id, pending.signal);
      if (!alive || request !== revision || jobId !== id) return;
      report = verificationInsights(value);
      reportState = 'loaded';
      pageIndex = 0;
      findingPage = 0;
      flagCounts = {};
    } catch (problem) {
      if (!alive || request !== revision || jobId !== id || pending.signal.aborted) return;
      if (problem instanceof APIError && (problem.status === 401 || problem.status === 403)) {
        onAuthFailure(problem);
        return;
      }
      report = null;
      reportState = problem instanceof APIError && problem.status === 404 ? 'missing' : 'error';
      reportError = problem instanceof Error ? problem.message : 'The verification report could not be loaded.';
    }
  }
  function label(value: InsightStatus) { return ({ ok: 'Completed', error: 'Error', skipped: 'Skipped', green: 'Passed', yellow: 'Review', red: 'Needs attention', unknown: 'Not recorded' })[value]; }
  function variant(value: InsightStatus): 'default' | 'destructive' | 'secondary' | 'outline' { return value === 'red' || value === 'error' ? 'destructive' : value === 'green' || value === 'ok' ? 'default' : value === 'yellow' ? 'outline' : 'secondary'; }
  function heading(name: string) { return name.replaceAll('_', ' '); }
  onDestroy(() => { alive = false; revision++; controller?.abort(); });
</script>

<Card.Root class="min-w-0" data-testid="job-insights">
  <Card.Header>
    <div class="flex flex-wrap items-center justify-between gap-3">
      <Card.Title><h3>Job insights</h3></Card.Title>
      <Badge variant={variant(insights.verificationStatus)}>Verification: {label(insights.verificationStatus)}</Badge>
    </div>
    <Card.Description>Recorded worker timings and read-only document verification.</Card.Description>
  </Card.Header>
  <Card.Content class="space-y-6">
    {#if insights.metrics}
      <dl class="grid grid-cols-2 gap-4 text-sm sm:grid-cols-4" aria-label="Job measurements">
        <div><dt class="text-muted-foreground">Total time</dt><dd>{formatDuration(insights.metrics.wallMs)}</dd></div>
        <div><dt class="text-muted-foreground">Pages per second</dt><dd>{formatNumber(insights.metrics.pagesPerSecond)}</dd></div>
        <div><dt class="text-muted-foreground">Chunks per second</dt><dd>{formatNumber(insights.metrics.chunksPerSecond)}</dd></div>
        <div><dt class="text-muted-foreground">Embeddings per second</dt><dd>{formatNumber(insights.metrics.embeddingsPerSecond)}</dd></div>
      </dl>
      <p class="break-words text-sm text-muted-foreground">Host: {insights.metrics.host ?? 'Not recorded'}{#if insights.metrics.gpuName} · GPU: {insights.metrics.gpuName}{/if}{#if insights.metrics.vramUsedMb !== null || insights.metrics.vramTotalMb !== null} · GPU memory: {formatNumber(insights.metrics.vramUsedMb, ' MB')} / {formatNumber(insights.metrics.vramTotalMb, ' MB')}{/if}</p>
      {#if insights.metrics.stages.length}
        <div class="overflow-x-auto">
          <table class="w-full text-left text-sm" aria-label="Stage measurements">
            <thead><tr class="border-b border-border"><th class="p-2">Stage</th><th class="p-2">Status</th><th class="p-2">Runtime</th><th class="p-2">Duration</th><th class="p-2">Counts</th></tr></thead>
            <tbody>{#each visibleStages as stage}<tr class="border-b border-border"><th class="p-2 font-medium capitalize">{heading(stage.name)}</th><td class="p-2"><Badge variant={variant(stage.status)}>{label(stage.status)}</Badge></td><td class="p-2">{stage.runtime ?? 'Not recorded'}</td><td class="p-2 whitespace-nowrap">{formatDuration(stage.durationMs)}</td><td class="p-2">{#if stage.pages !== null}<span>{stage.pages} pages </span>{/if}{#if stage.chunks !== null}<span>{stage.chunks} chunks </span>{/if}{#if stage.tokens !== null}<span>{stage.tokens} tokens</span>{/if}{#if stage.pages === null && stage.chunks === null && stage.tokens === null}Not recorded{/if}</td></tr>{/each}</tbody>
          </table>
        </div>
        {#if insights.metrics.stages.length > stageLimit}<div class="flex flex-wrap items-center justify-between gap-3 text-sm"><span>Stage page {stagePage + 1} · up to {stageLimit} stages per page</span><div class="flex max-w-full flex-wrap gap-2"><Button variant="outline" size="sm" disabled={stagePage === 0} onclick={() => stagePage--}>Previous stages</Button><Button variant="outline" size="sm" disabled={(stagePage + 1) * stageLimit >= (insights.metrics?.stages.length ?? 0)} onclick={() => stagePage++}>Next stages</Button></div></div>{/if}
      {:else}<p class="text-sm text-muted-foreground">No stage timings were recorded.</p>{/if}
    {:else}<p class="text-sm text-muted-foreground">No timing measurements were returned for this job.</p>{/if}
    <div class="flex flex-wrap items-center justify-between gap-3 border-t border-border pt-4">
      <div><h3 class="text-sm font-semibold">Verification report</h3><p class="text-sm text-muted-foreground">Stored checks only. Viewing does not re-run verification or change the collection.</p></div>
      <Button variant="outline" size="sm" disabled={active || reportState === 'loading'} onclick={viewReport}>{reportState === 'loading' ? 'Loading report…' : reportState === 'loaded' ? 'Refresh verification report' : 'View verification report'}</Button>
    </div>
    {#if active}<p class="text-sm text-muted-foreground">Verification becomes available after processing finishes.</p>{/if}
    {#if reportState === 'missing'}<p class="text-sm text-muted-foreground" role="status">No verification report is available for this job.</p>{/if}
    {#if reportState === 'error'}<p class="text-sm text-destructive" role="alert">{reportError}</p>{/if}
    {#if reportState === 'loaded' && report}
      <section class="space-y-4" aria-label="Verification results">
        <div class="flex flex-wrap items-center gap-3"><Badge variant={variant(report.status)}>{label(report.status)}</Badge><span class="min-w-0 max-w-full break-words text-sm text-muted-foreground">{report.filename ?? job.filename}{#if report.generatedAt} · {report.generatedAt}{/if}</span></div>
        <div class="grid gap-3 sm:grid-cols-2">{#each report.checks as check}<div class="rounded-md border border-border p-3"><div class="flex flex-wrap items-center justify-between gap-2"><h4 class="text-sm font-medium">{check.name}</h4><Badge variant={variant(check.status)}>{label(check.status)}</Badge></div>{#if check.detail}<p class="mt-2 break-words text-sm text-muted-foreground">{check.detail}</p>{/if}</div>{/each}</div>
        <section class="space-y-3" aria-label="Verification pages">
          <h4 class="text-sm font-semibold">Pages · {report.pages.length}</h4>
          {#if !report.pages.length}<p class="text-sm text-muted-foreground">No page measurements were recorded.</p>{/if}
          {#each visiblePages as item, index}{@const flagKey = pageIndex * reportLimit + index}{@const visibleFlagCount = flagCounts[flagKey] ?? 10}<article class="rounded-md border border-border p-3"><div class="flex flex-wrap items-center gap-3 text-sm"><h5 class="font-medium">Page {item.page ?? 'Not recorded'}</h5><Badge variant={variant(item.status)}>{label(item.status)}</Badge><span>Coverage: {item.coverage === null ? 'Not recorded' : `${Math.round(item.coverage * 100)}%`}</span></div>{#if item.flags.length}<ul class="mt-2 space-y-1 text-sm text-muted-foreground">{#each item.flags.slice(0, visibleFlagCount) as flag}<li class="break-words">{flag}</li>{/each}</ul>{#if item.flags.length > visibleFlagCount}<Button class="mt-2" variant="outline" size="sm" onclick={() => flagCounts[flagKey] = visibleFlagCount + 10}>Show more flags for page {item.page ?? index + 1}</Button>{/if}{/if}</article>{/each}
          {#if report.pages.length > reportLimit}<div class="flex flex-wrap items-center justify-between gap-3 text-sm"><span>Page results {pageIndex * reportLimit + 1}–{Math.min((pageIndex + 1) * reportLimit, report.pages.length)} of {report.pages.length}</span><div class="flex max-w-full flex-wrap gap-2"><Button variant="outline" size="sm" disabled={pageIndex === 0} onclick={() => pageIndex--}>Previous verification pages</Button><Button variant="outline" size="sm" disabled={(pageIndex + 1) * reportLimit >= report.pages.length} onclick={() => pageIndex++}>Next verification pages</Button></div></div>{/if}
        </section>
        <section class="space-y-3" aria-label="Verification details">
          <h4 class="text-sm font-semibold">Check details · {report.findings.length}</h4>
          {#if !report.findings.length}<p class="text-sm text-muted-foreground">No detailed findings were recorded.</p>{/if}
          {#each visibleFindings as item}<article class="rounded-md border border-border p-3"><div class="flex flex-wrap items-center justify-between gap-2"><h5 class="min-w-0 max-w-full break-words text-sm font-medium">{item.name}{#if item.page !== null} · page {item.page}{/if}</h5><Badge variant={variant(item.status)}>{label(item.status)}</Badge></div><p class="mt-2 whitespace-pre-wrap break-words text-sm text-muted-foreground">{item.detail}</p></article>{/each}
          {#if report.findings.length > reportLimit}<div class="flex flex-wrap items-center justify-between gap-3 text-sm"><span>Details {findingPage * reportLimit + 1}–{Math.min((findingPage + 1) * reportLimit, report.findings.length)} of {report.findings.length}</span><div class="flex max-w-full flex-wrap gap-2"><Button variant="outline" size="sm" disabled={findingPage === 0} onclick={() => findingPage--}>Previous verification details</Button><Button variant="outline" size="sm" disabled={(findingPage + 1) * reportLimit >= report.findings.length} onclick={() => findingPage++}>Next verification details</Button></div></div>{/if}
        </section>
      </section>
    {/if}
  </Card.Content>
</Card.Root>
