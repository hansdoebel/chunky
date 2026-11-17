import { describe, expect, it } from 'vitest';
import { modelReadiness } from './model-readiness';
describe('worker model discovery', () => {
  it('preserves zero bytes, revision and worker recommendation provenance without exposing MLX', () => {
    const parsed = modelReadiness({ vlm: [{ name: 'granite', repo_id: 'ibm/granite', available: true, size: 0, revision: 'fixture', engine: 'transformers' }, { name: 'granite-mlx', available: true }], recommended: { devbox: ['ibm/granite', 'extra'], mac: ['mac-only'] } });
    expect(parsed.rows).toHaveLength(2);
    expect(parsed.rows[0]).toMatchObject({ state: 'Reported available', size: 0, revision: 'fixture', recommended: true });
    expect(parsed.rows[1]).toMatchObject({ name: 'extra', state: 'Unknown' });
  });
  it('distinguishes not detected from failed discovery and an unobservable vLLM server', () => {
    expect(modelReadiness({ vlm: [{ name: 'model', available: false, engine: 'transformers' }] }).rows[0].state).toBe('Not detected');
    const failed = modelReadiness({ cache_error: 'private internal error', vlm: [{ name: 'model', available: false }] });
    expect(failed.rows[0].state).toBe('Unknown');
    expect(failed.warnings).toEqual(['Hugging Face cache discovery is incomplete.']);
    expect(modelReadiness({ vlm: [{ name: 'model', available: false, engine: 'vllm' }] }).rows[0].state).toBe('Unknown');
  });
  it('handles legacy names and partial malformed metadata without inventing availability', () => {
    const parsed = modelReadiness({ embeddings: [{ name: 'custom' }, null, { name: 7 }], installed: [{ name: 'local', size: -2, source: 'ollama' }], ollama_error: 'failed' });
    expect(parsed.rows.map((r) => r.state)).toEqual(['Unknown', 'Unknown']);
    expect(parsed.rows[1].size).toBeNull();
    for (const bad of [null, [], {}, { other: true }]) expect(() => modelReadiness(bad)).toThrow();
  });
});
