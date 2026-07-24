import { create } from 'zustand';
import { fixtureSessionList } from '../daemonFixture.js';
import type { SessionEntry } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

export const ACTIVITY_PAGE_SIZE = 50;

// Activity search is user-driven and can overlap when a retry or a new query
// starts before the daemon answers the previous request. Only the newest
// request may publish rows or errors into the store.
let activityLoadGeneration = 0;

export type ActivityState = {
  sessions: SessionEntry[];
  loading: boolean;
  error: string | null;
  query: string;
  visibleCount: number;
  load(): Promise<void>;
  search(query: string): Promise<void>;
  loadMore(): void;
};

function filterFixtureSessions(sessions: SessionEntry[], query: string): SessionEntry[] {
  const q = query.trim().toLowerCase();
  if (!q) return sessions;
  return sessions.filter(
    (s) =>
      s.title.toLowerCase().includes(q) ||
      s.provider.toLowerCase().includes(q) ||
      s.model.toLowerCase().includes(q) ||
      s.id.toLowerCase().includes(q)
  );
}

export const useActivityStore = create<ActivityState>()((set, get) => ({
  sessions: [],
  loading: false,
  error: null,
  query: '',
  visibleCount: ACTIVITY_PAGE_SIZE,

  async load() {
    const requestGeneration = ++activityLoadGeneration;
    const { fixtureMode, bridge } = useShellStore.getState();
    const { query } = get();
    if (fixtureMode) {
      const all = fixtureSessionList().sessions;
      const sessions = query ? filterFixtureSessions(all, query) : all;
      set({ sessions, loading: false, error: null, visibleCount: ACTIVITY_PAGE_SIZE });
      return;
    }
    if (!bridge) {
      set({
        sessions: [],
        loading: false,
        error: null,
        visibleCount: ACTIVITY_PAGE_SIZE
      });
      return;
    }
    set({ loading: true, error: null });
    try {
      const result = query ? await bridge.sessionSearch(query) : await bridge.sessionList();
      if (requestGeneration !== activityLoadGeneration) return;
      set({
        sessions: result.sessions,
        loading: false,
        error: null,
        visibleCount: ACTIVITY_PAGE_SIZE
      });
    } catch (e) {
      if (requestGeneration !== activityLoadGeneration) return;
      set({
        sessions: [],
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed',
        visibleCount: ACTIVITY_PAGE_SIZE
      });
    }
  },

  async search(query: string) {
    set({ query, visibleCount: ACTIVITY_PAGE_SIZE });
    await get().load();
  },

  loadMore() {
    set((s) => ({ visibleCount: s.visibleCount + ACTIVITY_PAGE_SIZE }));
  }
}));
