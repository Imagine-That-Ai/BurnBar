import { create } from 'zustand';
import { fixtureUsageInsights } from '../daemonFixture.js';
import type { UsageInsights } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

let latestLoadID = 0;

export type InsightsState = {
  data: UsageInsights | null;
  loading: boolean;
  error: string | null;
  load(): Promise<void>;
};

export const useInsightsStore = create<InsightsState>()((set) => ({
  data: null,
  loading: false,
  error: null,
  async load() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      ++latestLoadID;
      set({ data: fixtureUsageInsights(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      ++latestLoadID;
      // Keep an existing snapshot visible when the bridge disappears. The
      // surface can mark it degraded and offer retry instead of going blank.
      set({ loading: false, error: 'Packaged shell required for live data.' });
      return;
    }
    const loadID = ++latestLoadID;
    set({ loading: true, error: null });
    try {
      const data = await bridge.usageInsights();
      if (loadID !== latestLoadID) return;
      set({ data, loading: false, error: null });
    } catch (e) {
      if (loadID !== latestLoadID) return;
      set({
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  }
}));
