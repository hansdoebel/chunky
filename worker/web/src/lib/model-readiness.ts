export type ModelRow = { name: string; kind: string; state: 'Reported available' | 'Not detected' | 'Unknown'; source: string; revision: string | null; size: number | null; recommended: boolean };
const object = (v: unknown): Record<string, unknown> => v !== null && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, unknown> : {};
const rows = (v: unknown): Record<string, unknown>[] => Array.isArray(v) ? v.map(object) : [];
const text = (v: unknown): string | null => typeof v === 'string' && v.trim() ? v : null;
const compatible = (name: string) => !name.toLowerCase().includes('mlx');
export function modelReadiness(value: unknown): { rows: ModelRow[]; warnings: string[] } {
  const data = object(value);
  if (!['embeddings', 'vlm', 'installed', 'recommended'].some((key) => key in data)) throw new Error('The worker returned an invalid model catalog.');
  const recommendations = new Set((Array.isArray(object(data.recommended).devbox) ? object(data.recommended).devbox as unknown[] : []).filter((v): v is string => typeof v === 'string' && compatible(v)));
  const warnings: string[] = [];
  if (data.embeddings_error) warnings.push('Embedding model discovery is incomplete.');
  if (data.cache_error) warnings.push('Hugging Face cache discovery is incomplete.');
  if (data.ollama_error) warnings.push('Ollama model discovery is incomplete.');
  const result: ModelRow[] = [];
  for (const [field, kind] of [['embeddings', 'Embedding'], ['vlm', 'Document'], ['installed', 'Installed']] as const) {
    for (const row of rows(data[field])) {
      const name = text(row.name);
      if (!name || !compatible(name) || row.engine === 'mlx') continue;
      const source = text(row.engine) ?? text(row.source) ?? (field === 'embeddings' ? 'Worker embedding provider' : field === 'vlm' ? 'Worker document catalog' : 'Worker inventory');
      const uncertain = field === 'embeddings' ? !!data.embeddings_error : field === 'vlm' ? !!data.cache_error || source === 'vllm' : row.source === 'ollama' ? !!data.ollama_error : !!data.cache_error;
      const available = field === 'installed' ? !uncertain : row.available === true;
      result.push({ name, kind, source, state: available ? 'Reported available' : row.available === false && !uncertain ? 'Not detected' : 'Unknown', revision: text(row.revision), size: typeof row.size === 'number' && Number.isFinite(row.size) && row.size >= 0 ? row.size : null, recommended: recommendations.has(name) || recommendations.has(text(row.repo_id) ?? '') });
    }
  }
  for (const name of recommendations) if (!result.some((r) => r.name === name || r.recommended && rows(data.vlm).some((v) => v.name === r.name && v.repo_id === name))) result.push({ name, kind: 'Recommended', state: 'Unknown', source: 'Worker devbox recommendation', revision: null, size: null, recommended: true });
  return { rows: result, warnings };
}
