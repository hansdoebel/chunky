import { describe, expect, it } from 'vitest';
import { ELEMENT_TYPES, SearchFilterError, buildSearchFilters, emptySearchFilters, hasSearchFilters, searchFilterErrors, type SearchFilterDraft } from './search-filters';

describe('worker search filter serialization', () => {
  it('preserves unfiltered requests and does not share cleared drafts', () => {
    const first = emptySearchFilters();
    first.author = 'Ada';
    expect(emptySearchFilters().author).toBe('');
    expect(buildSearchFilters(emptySearchFilters())).toEqual([]);
    expect(buildSearchFilters({ ...emptySearchFilters(), yearFrom: ' ', title: '\t', doi: '\n' })).toEqual([]);
    expect(hasSearchFilters(emptySearchFilters())).toBe(false);
    expect(hasSearchFilters(first)).toBe(true);
  });

  it('uses existing worker field operators for a combined scientific-paper query', () => {
    const draft: SearchFilterDraft = {
      yearFrom: ' 2020 ', yearTo: '2024', author: ' Ada Lovelace ', doi: ' 10.1234/example ',
      title: ' Scientific methods ', heading: ' Results ', contentType: 'table',
    };
    const snapshot = { ...draft };
    expect(buildSearchFilters(draft)).toEqual([
      { key: 'year', gte: 2020, lte: 2024 },
      { key: 'authors', text: 'Ada Lovelace' },
      { key: 'doi', match: '10.1234/example' },
      { key: 'doc_title', text: 'Scientific methods' },
      { key: 'headings', text: 'Results' },
      { key: 'content_type', match: 'table' },
    ]);
    expect(draft).toEqual(snapshot);
  });

  it('supports open and inclusive year ranges', () => {
    expect(buildSearchFilters({ ...emptySearchFilters(), yearFrom: '1' })).toEqual([{ key: 'year', gte: 1 }]);
    expect(buildSearchFilters({ ...emptySearchFilters(), yearTo: '9999' })).toEqual([{ key: 'year', lte: 9999 }]);
    expect(buildSearchFilters({ ...emptySearchFilters(), yearFrom: '2024', yearTo: '2024' })).toEqual([{ key: 'year', gte: 2024, lte: 2024 }]);
  });

  it.each(['2020.5', '2020.0', '2e3', 'Infinity', 'NaN', '0', '-1', '10000', 'abcd', '2024 years'])('rejects invalid year %s before any request can be sent', (value) => {
    for (const field of ['yearFrom', 'yearTo'] as const) {
      const draft = { ...emptySearchFilters(), [field]: value };
      expect(searchFilterErrors(draft)).toHaveProperty(field);
      expect(() => buildSearchFilters(draft)).toThrow(SearchFilterError);
    }
  });

  it('reports both fields for inverted ranges', () => {
    const draft = { ...emptySearchFilters(), yearFrom: '2025', yearTo: '2020' };
    expect(searchFilterErrors(draft)).toEqual({
      yearFrom: 'From year must not be later than to year.',
      yearTo: 'To year must not be earlier than from year.',
    });
    expect(() => buildSearchFilters(draft)).toThrow('From year must not be later');
  });

  it.each(ELEMENT_TYPES)('uses the canonical backend element type %s', (kind) => {
    expect(buildSearchFilters({ ...emptySearchFilters(), contentType: kind })).toEqual([{ key: 'content_type', match: kind }]);
  });

  it('refuses unsupported element types instead of sending an unintended match', () => {
    const draft = { ...emptySearchFilters(), contentType: 'unknown' } as unknown as SearchFilterDraft;
    expect(() => buildSearchFilters(draft)).toThrow('supported element type');
  });
});
