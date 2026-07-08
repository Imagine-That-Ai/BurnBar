import { create } from 'zustand';
import { fixtureProviderCatalog } from '../daemonFixture.js';
import type { ProviderCatalog } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

export type ProvidersState = {
  catalog: ProviderCatalog | null;
  loading: boolean;
  error: string | null;
  load(): Promise<void>;
};

export const useProvidersStore = create<ProvidersState>()((set) => ({
  catalog: null,
  loading: false,
  error: null,
  async load() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ catalog: fixtureProviderCatalog(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      set({
        catalog: null,
        loading: false,
        error: 'Packaged shell required for live data.'
      });
      return;
    }
    set({ loading: true, error: null });
    try {
      const catalog = await bridge.providerCatalog();
      set({ catalog, loading: false, error: null });
    } catch (e) {
      set({
        catalog: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  }
}));