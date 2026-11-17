import { expect, it } from 'vitest';
import { buildSearchRequest, type SearchOptions, type WorkerConfig } from './api';
import { emptySearchFilters } from './search-filters';
const config: WorkerConfig = { embedding_backend: 'ollama', embedding_model: 'fixture', qdrant_available: true, qdrant_label: 'Worker', vlm_models: ['standard'] };
const options: SearchOptions = { query: 'papers', backend: 'ollama', model: 'fixture', endpoint: '', mode: 'dense' };
it('preserves passage requests and explicitly requests paper expansion with paper offsets', () => {
  expect(buildSearchRequest('docs', options, config)).not.toHaveProperty('papers_first');
  expect(buildSearchRequest('docs', { ...options, resultKind: 'papers' }, config, 10)).toMatchObject({ papers_first: true, expand_documents: false, offset: 10, limit: 10 });
  expect(buildSearchRequest('docs', { ...options, resultKind: 'papers-with-passages' }, config)).toMatchObject({ papers_first: true, expand_documents: true, use_worker_qdrant: true });
});
it('rejects ignored passage filters while retaining document metadata filters', () => {
  for (const resultKind of ['papers', 'papers-with-passages'] as const) for (const filter of [{ doi: '10.1234/fixture' }, { heading: 'Results' }, { contentType: 'table' as const }]) expect(() => buildSearchRequest('docs', { ...options, resultKind, filters: { ...emptySearchFilters(), ...filter } }, config)).toThrow('Clear DOI');
  expect(buildSearchRequest('docs', { ...options, resultKind: 'papers', filters: { ...emptySearchFilters(), author: 'Ada' } }, config)).toMatchObject({ filters: [{ key: 'authors', text: 'Ada' }] });
});

it('keeps exact DOI filtering in passage mode', () => {
  expect(buildSearchRequest('docs', { ...options, filters: { ...emptySearchFilters(), doi: '10.1234/fixture' } }, config)).toMatchObject({ filters: [{ key: 'doi', match: '10.1234/fixture' }] });
});
