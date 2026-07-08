import { create } from 'zustand';
import { fixtureAccountStatus } from '../daemonFixture.js';
import type { AccountStatus } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

export type AccountState = {
  data: AccountStatus | null;
  loading: boolean;
  error: string | null;
  load(): Promise<void>;
};

export const useAccountStore = create<AccountState>()((set) => ({
  data: null,
  loading: false,
  error: null,
  async load() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ data: fixtureAccountStatus(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      set({ data: null, loading: false, error: 'Packaged shell required for live data.' });
      return;
    }
    set({ loading: true, error: null });
    try {
      const data = await bridge.accountStatus();
      set({ data, loading: false, error: null });
    } catch (e) {
      set({
        data: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  }
}));