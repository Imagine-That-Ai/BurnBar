import { create } from 'zustand';
import { fixtureIntegrationsStatus } from '../daemonFixture.js';
import type { IntegrationsStatus } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

const OFFLINE_ERROR = 'Packaged shell or openburnbar-cli is required for integration status.';

export type IntegrationsState = {
  status: IntegrationsStatus | null;
  loading: boolean;
  error: string | null;
  loadStatus(): Promise<void>;
};

export const useIntegrationsStore = create<IntegrationsState>()((set) => ({
  status: null,
  loading: false,
  error: null,

  async loadStatus() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ status: fixtureIntegrationsStatus(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      set({ status: null, loading: false, error: OFFLINE_ERROR });
      return;
    }
    set({ loading: true, error: null });
    try {
      const status = await bridge.integrationsStatus();
      set({ status, loading: false, error: null });
    } catch (e) {
      set({
        status: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Integration status request failed'
      });
    }
  }
}));
