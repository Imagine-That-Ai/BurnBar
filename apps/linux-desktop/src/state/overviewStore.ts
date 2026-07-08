import { create } from 'zustand';
import { fixtureUsageInsights, fixtureUsageSummary } from '../daemonFixture.js';
import type { UsageSummary } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

export type OverviewState = {
  summary: UsageSummary | null;
  cacheHitRatePct: number | null;
  lastRefreshedAt: Date | null;
  loading: boolean;
  error: string | null;
  load(): Promise<void>;
};

export const useOverviewStore = create<OverviewState>()((set) => ({
  summary: null,
  cacheHitRatePct: null,
  lastRefreshedAt: null,
  loading: false,
  error: null,
  async load() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({
        summary: fixtureUsageSummary(),
        cacheHitRatePct: fixtureUsageInsights().cacheHitRatePct,
        lastRefreshedAt: new Date(),
        loading: false,
        error: null
      });
      return;
    }
    if (!bridge) {
      set({
        summary: null,
        cacheHitRatePct: null,
        loading: false,
        error: 'Packaged shell required for live data.'
      });
      return;
    }
    set({ loading: true, error: null });
    try {
      const [summary, insights] = await Promise.all([
        bridge.usageSummary(),
        bridge.usageInsights().catch(() => null)
      ]);
      set({
        summary,
        cacheHitRatePct: insights?.cacheHitRatePct ?? null,
        lastRefreshedAt: new Date(),
        loading: false,
        error: null
      });
    } catch (e) {
      set({
        summary: null,
        cacheHitRatePct: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  }
}));