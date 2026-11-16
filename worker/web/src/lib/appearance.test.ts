import { describe, expect, it, vi } from 'vitest';
import { get } from 'svelte/store';
import { createAppearanceController, isAppearance, type AppearanceEnvironment } from './appearance';

function environment(saved: string | null = null, dark = false) {
  let change = () => {};
  const write = vi.fn();
  const apply = vi.fn();
  const stop = vi.fn();
  const current = { dark };
  const adapter: AppearanceEnvironment = {
    read: () => saved, write, apply,
    prefersDark: () => current.dark,
    listen(listener) { change = listener; return stop; },
  };
  return { adapter, write, apply, stop, change: () => change(), current };
}

describe('appearance preference', () => {
  it('defaults to system without persisting anything and follows OS changes', () => {
    const env = environment();
    const appearance = createAppearanceController(env.adapter);
    expect(get(appearance)).toBe('system');
    expect(env.apply).toHaveBeenLastCalledWith('light', 'system');
    env.current.dark = true;
    env.change();
    expect(env.apply).toHaveBeenLastCalledWith('dark', 'system');
    expect(env.write).not.toHaveBeenCalled();
  });
  it('loads only a valid saved preference and keeps an explicit choice across OS changes', () => {
    const env = environment('dark');
    const appearance = createAppearanceController(env.adapter);
    expect(get(appearance)).toBe('dark');
    env.current.dark = false;
    env.change();
    expect(env.apply).toHaveBeenLastCalledWith('dark', 'dark');
    expect(env.write).not.toHaveBeenCalled();
  });
  it('persists only an explicit valid enum and can return to system', () => {
    const env = environment(null, true);
    const appearance = createAppearanceController(env.adapter);
    appearance.set('light');
    expect(env.write).toHaveBeenLastCalledWith('light');
    expect(env.apply).toHaveBeenLastCalledWith('light', 'light');
    appearance.set('system');
    expect(env.write).toHaveBeenLastCalledWith('system');
    expect(env.apply).toHaveBeenLastCalledWith('dark', 'system');
  });
  it('ignores malformed stored values and rejects invalid selections', () => {
    const env = environment('{"token":"not-an-appearance"}', true);
    const appearance = createAppearanceController(env.adapter);
    expect(get(appearance)).toBe('system');
    expect(isAppearance('token')).toBe(false);
    appearance.set('token' as never);
    expect(env.write).not.toHaveBeenCalled();
    expect(env.apply).toHaveBeenLastCalledWith('dark', 'system');
  });
  it('still changes appearance when browser persistence is blocked', () => {
    const env = environment();
    env.adapter.read = () => { throw new Error('blocked'); };
    env.adapter.write = () => { throw new Error('blocked'); };
    const appearance = createAppearanceController(env.adapter);
    expect(get(appearance)).toBe('system');
    expect(() => appearance.set('dark')).not.toThrow();
    expect(get(appearance)).toBe('dark');
    expect(env.apply).toHaveBeenLastCalledWith('dark', 'dark');
  });
  it('releases the system preference listener when disposed', () => {
    const env = environment();
    const appearance = createAppearanceController(env.adapter);
    appearance.destroy();
    expect(env.stop).toHaveBeenCalledOnce();
  });
});
