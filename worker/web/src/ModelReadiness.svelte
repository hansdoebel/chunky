<script lang="ts">
  import { onDestroy, onMount } from 'svelte';
  import * as Card from '$lib/components/ui/card';
  import { Button } from '$lib/components/ui/button';
  import { Badge } from '$lib/components/ui/badge';
  import { APIError } from './lib/api';
  import { modelReadiness, type ModelRow } from './lib/model-readiness';
  let { load, onAuthFailure }: { load: (signal: AbortSignal) => Promise<unknown>; onAuthFailure: (error: unknown) => void } = $props();
  let models = $state<ModelRow[]>([]);
  let warnings = $state<string[]>([]);
  let catalogState = $state<'loading' | 'loaded' | 'error'>('loading');
  let page = $state(0);
  let controller: AbortController | undefined;
  let alive = true;
  let revision = 0;
  async function refresh() {
    const request = ++revision;
    controller?.abort();
    controller = new AbortController();
    catalogState = 'loading';
    models = [];
    warnings = [];
    page = 0;
    try {
      const result = modelReadiness(await load(controller.signal));
      if (!alive || request !== revision) return;
      models = result.rows;
      warnings = result.warnings;
      catalogState = 'loaded';
    } catch (problem) {
      if (!alive || request !== revision) return;
      if (problem instanceof APIError && (problem.status === 401 || problem.status === 403)) onAuthFailure(problem);
      else catalogState = 'error';
    }
  }
  onMount(() => { void refresh(); });
  onDestroy(() => { alive = false; revision++; controller?.abort(); });
</script>
<Card.Root class="mt-6 min-w-0" data-testid="model-readiness">
  <Card.Header><div class="flex flex-wrap items-center justify-between gap-3"><Card.Title><h2>Worker model readiness</h2></Card.Title><Button variant="outline" disabled={catalogState === 'loading'} onclick={refresh}>Refresh model catalog</Button></div><Card.Description>Worker-reported discovery only. Cached or listed models may still need runtime resources to load. Custom endpoints are not checked here.</Card.Description></Card.Header>
  <Card.Content class="space-y-4">
    {#if catalogState === 'loading'}<p role="status">Loading model catalog…</p>{:else if catalogState === 'error'}<p role="status">Model readiness is unknown because the catalog could not be loaded. You can still enter a model name.</p>{:else}
      {#each warnings as warning}<p role="status" class="text-sm text-muted-foreground">{warning}</p>{/each}
      {#if !models.length}<p>No compatible models were reported. Availability is unknown.</p>{/if}
      {#each models.slice(page * 20, (page + 1) * 20) as model}<article class="space-y-2 rounded-md border border-border p-3"><div class="flex flex-wrap items-center justify-between gap-2"><h3 class="break-all">{model.name}</h3><Badge variant={model.state === 'Reported available' ? 'default' : 'secondary'}>{model.state}</Badge></div><p class="break-words text-sm text-muted-foreground">{model.kind} · {model.source}{#if model.revision} · Revision: {model.revision}{/if}{#if model.size !== null} · {(model.size / 1024 / 1024).toLocaleString('en-US', { maximumFractionDigits: 1 })} MiB{/if}</p>{#if model.recommended}<p class="text-sm text-muted-foreground">Recommended by the worker devbox catalog</p>{/if}</article>{/each}
      {#if models.length > 20}<div class="flex flex-wrap items-center gap-3"><span>Models {page * 20 + 1}–{Math.min((page + 1) * 20, models.length)} of {models.length}</span><Button variant="outline" disabled={page === 0} onclick={() => page--}>Previous models</Button><Button variant="outline" disabled={(page + 1) * 20 >= models.length} onclick={() => page++}>Next models</Button></div>{/if}
    {/if}
  </Card.Content>
</Card.Root>
