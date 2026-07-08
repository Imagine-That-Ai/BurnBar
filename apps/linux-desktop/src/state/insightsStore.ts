import { create } from 'zustand';
import { fixtureUsageInsights } from '../daemonFixture.js';
import type { UsageInsights } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

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
      set({ data: fixtureUsageInsights(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      set({ data: null, loading: false, error: 'Packaged shell required for live data.' });
      return;
    }
    set({ loading: true, error: null });
    try {
      const data = await bridge.usageInsights();
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