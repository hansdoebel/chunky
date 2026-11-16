import { writable } from 'svelte/store';

export type Appearance = 'system' | 'light' | 'dark';
export type ResolvedAppearance = 'light' | 'dark';
export const appearanceKey = 'chunky.appearance';
export type AppearanceEnvironment = {
  read: () => string | null;
  write: (value: Appearance) => void;
  prefersDark: () => boolean;
  listen: (listener: () => void) => () => void;
  apply: (resolved: ResolvedAppearance, preference: Appearance) => void;
};

export function isAppearance(value: unknown): value is Appearance {
  return value === 'system' || value === 'light' || value === 'dark';
}

export function createAppearanceController(environment: AppearanceEnvironment) {
  let current: Appearance = 'system';
  try {
    const saved = environment.read();
    if (isAppearance(saved)) current = saved;
  } catch {}
  const store = writable(current);
  function apply() {
    const dark = current === 'dark' || (current === 'system' && environment.prefersDark());
    environment.apply(dark ? 'dark' : 'light', current);
  }
  const stop = environment.listen(apply);
  apply();
  return {
    subscribe: store.subscribe,
    set(value: Appearance) {
      if (!isAppearance(value)) return;
      current = value;
      store.set(value);
      try { environment.write(value); } catch {}
      apply();
    },
    destroy: stop,
  };
}

let controller: ReturnType<typeof createAppearanceController> | undefined;
export function initializeAppearance() {
  if (!controller) {
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    controller = createAppearanceController({
      read: () => window.localStorage.getItem(appearanceKey),
      write: (value) => window.localStorage.setItem(appearanceKey, value),
      prefersDark: () => media.matches,
      listen(listener) {
        media.addEventListener('change', listener);
        return () => media.removeEventListener('change', listener);
      },
      apply(resolved, preference) {
        document.documentElement.classList.toggle('dark', resolved === 'dark');
        document.documentElement.dataset.theme = resolved;
        document.documentElement.dataset.appearance = preference;
      },
    });
  }
  return controller;
}
