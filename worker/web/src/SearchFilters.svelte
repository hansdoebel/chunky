<script lang="ts">
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Label } from '$lib/components/ui/label';
  import * as NativeSelect from '$lib/components/ui/native-select';
  import { emptySearchFilters, hasSearchFilters, searchFilterErrors, type SearchFilterDraft } from './lib/search-filters';

  let { value, onChange }: { value: SearchFilterDraft; onChange: (value: SearchFilterDraft) => void } = $props();
  const errors = $derived(searchFilterErrors(value));
  function update<K extends keyof SearchFilterDraft>(field: K, next: SearchFilterDraft[K]) {
    onChange({ ...value, [field]: next });
  }
</script>

<details class="rounded-lg border border-border bg-card p-4 text-card-foreground">
  <summary class="cursor-pointer text-sm font-medium">Filter passages</summary>
  <div class="mt-4 grid gap-4 sm:grid-cols-2" aria-describedby="search-filter-help">
    <div class="grid gap-2">
      <Label for="search-year-from">From year</Label>
      <Input id="search-year-from" type="text" inputmode="numeric" value={value.yearFrom} oninput={(event) => update('yearFrom', event.currentTarget.value)} aria-invalid={!!errors.yearFrom} aria-describedby={errors.yearFrom ? 'search-year-from-error' : undefined} placeholder="Any year" />
      {#if errors.yearFrom}<p id="search-year-from-error" class="text-sm text-destructive" role="alert">{errors.yearFrom}</p>{/if}
    </div>
    <div class="grid gap-2">
      <Label for="search-year-to">To year</Label>
      <Input id="search-year-to" type="text" inputmode="numeric" value={value.yearTo} oninput={(event) => update('yearTo', event.currentTarget.value)} aria-invalid={!!errors.yearTo} aria-describedby={errors.yearTo ? 'search-year-to-error' : undefined} placeholder="Any year" />
      {#if errors.yearTo}<p id="search-year-to-error" class="text-sm text-destructive" role="alert">{errors.yearTo}</p>{/if}
    </div>
    <div class="grid gap-2"><Label for="search-author">Author contains</Label><Input id="search-author" value={value.author} oninput={(event) => update('author', event.currentTarget.value)} placeholder="Any author" /></div>
    <div class="grid gap-2"><Label for="search-doi">DOI</Label><Input id="search-doi" value={value.doi} oninput={(event) => update('doi', event.currentTarget.value)} placeholder="Exact DOI as stored" /></div>
    <div class="grid gap-2"><Label for="search-title">Document title contains</Label><Input id="search-title" value={value.title} oninput={(event) => update('title', event.currentTarget.value)} placeholder="Any title" /></div>
    <div class="grid gap-2"><Label for="search-heading">Heading contains</Label><Input id="search-heading" value={value.heading} oninput={(event) => update('heading', event.currentTarget.value)} placeholder="Any heading" /></div>
    <div class="grid gap-2">
      <Label for="search-content-type">Element type</Label>
      <NativeSelect.Root id="search-content-type" class="w-full" value={value.contentType} onchange={(event) => update('contentType', event.currentTarget.value as SearchFilterDraft['contentType'])}>
        <NativeSelect.Option value="">All element types</NativeSelect.Option><NativeSelect.Option value="text">Text</NativeSelect.Option><NativeSelect.Option value="table">Table</NativeSelect.Option><NativeSelect.Option value="formula">Formula</NativeSelect.Option><NativeSelect.Option value="figure">Figure</NativeSelect.Option><NativeSelect.Option value="code">Code</NativeSelect.Option>
      </NativeSelect.Root>
    </div>
    <div class="flex items-end"><Button type="button" variant="outline" size="sm" disabled={!hasSearchFilters(value)} onclick={() => onChange(emptySearchFilters())}>Clear filters</Button></div>
    <p id="search-filter-help" class="text-xs text-muted-foreground sm:col-span-2">Filters apply on the worker to every search page. Empty fields include all values.</p>
  </div>
</details>
