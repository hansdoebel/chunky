export const ELEMENT_TYPES = ['text', 'table', 'formula', 'figure', 'code'] as const;

export type SearchFilterDraft = {
  yearFrom: string;
  yearTo: string;
  author: string;
  doi: string;
  title: string;
  heading: string;
  contentType: '' | typeof ELEMENT_TYPES[number];
};

export type SearchPayloadFilter = {
  key: 'year' | 'authors' | 'doi' | 'doc_title' | 'headings' | 'content_type';
  gte?: number;
  lte?: number;
  text?: string;
  match?: string;
};

export type SearchFilterErrors = Partial<Record<keyof SearchFilterDraft, string>>;

export class SearchFilterError extends Error {
  constructor(public fields: SearchFilterErrors) {
    super(Object.values(fields).join(' '));
    this.name = 'SearchFilterError';
  }
}

export function emptySearchFilters(): SearchFilterDraft {
  return { yearFrom: '', yearTo: '', author: '', doi: '', title: '', heading: '', contentType: '' };
}

function year(value: string): number | undefined {
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  if (!/^[0-9]{1,4}$/.test(trimmed)) return NaN;
  const parsed = Number(trimmed);
  return parsed >= 1 && parsed <= 9999 ? parsed : NaN;
}

export function searchFilterErrors(draft: SearchFilterDraft): SearchFilterErrors {
  const errors: SearchFilterErrors = {};
  const from = year(draft.yearFrom);
  const to = year(draft.yearTo);
  if (from !== undefined && !Number.isFinite(from)) errors.yearFrom = 'From year must be a whole number from 1 to 9999.';
  if (to !== undefined && !Number.isFinite(to)) errors.yearTo = 'To year must be a whole number from 1 to 9999.';
  if (from !== undefined && to !== undefined && Number.isFinite(from) && Number.isFinite(to) && from > to) {
    errors.yearFrom = 'From year must not be later than to year.';
    errors.yearTo = 'To year must not be earlier than from year.';
  }
  if (draft.contentType && !ELEMENT_TYPES.includes(draft.contentType)) errors.contentType = 'Choose a supported element type.';
  return errors;
}

export function hasSearchFilters(draft: SearchFilterDraft): boolean {
  return Object.values(draft).some((value) => value.trim().length > 0);
}

export function buildSearchFilters(draft: SearchFilterDraft): SearchPayloadFilter[] {
  const errors = searchFilterErrors(draft);
  if (Object.keys(errors).length) throw new SearchFilterError(errors);
  const filters: SearchPayloadFilter[] = [];
  const from = year(draft.yearFrom);
  const to = year(draft.yearTo);
  if (from !== undefined || to !== undefined) filters.push({ key: 'year', ...(from !== undefined ? { gte: from } : {}), ...(to !== undefined ? { lte: to } : {}) });
  const author = draft.author.trim();
  if (author) filters.push({ key: 'authors', text: author });
  const doi = draft.doi.trim();
  if (doi) filters.push({ key: 'doi', match: doi });
  const title = draft.title.trim();
  if (title) filters.push({ key: 'doc_title', text: title });
  const heading = draft.heading.trim();
  if (heading) filters.push({ key: 'headings', text: heading });
  if (draft.contentType) filters.push({ key: 'content_type', match: draft.contentType });
  return filters;
}
