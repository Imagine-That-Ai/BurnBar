import { create } from 'zustand';
import { fixtureSessionList } from '../daemonFixture.js';
import type { ActivityRouteSelection } from '../routes.js';
import type { SessionEntry } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

export const ACTIVITY_PAGE_SIZE = 50;

// Activity search is user-driven and can overlap when a retry or a new query
// starts before the daemon answers the previous request. Only the newest
// request may publish rows or errors into the store.
let activityLoadGeneration = 0;
let activityTargetGeneration = 0;

export type ActivityState = {
  sessions: SessionEntry[];
  loading: boolean;
  error: string | null;
  query: string;
  visibleCount: number;
  target: ActivityRouteSelection | null;
  targetSession: SessionEntry | null;
  targetLoading: boolean;
  targetError: string | null;
  load(): Promise<void>;
  search(query: string): Promise<void>;
  openTarget(target: ActivityRouteSelection): Promise<void>;
  clearTarget(): void;
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

function activityTargetID(target: ActivityRouteSelection): string {
  return target.kind === 'conversation' ? target.conversationID : target.sessionID;
}

export function sessionMatchesActivityTarget(
  session: SessionEntry,
  target: ActivityRouteSelection
): boolean {
  const targetID = activityTargetID(target);
  if (target.kind === 'conversation') {
    return session.sourceIDVerified === true && session.sourceID === targetID;
  }
  return session.id === targetID
    || (session.sourceIDVerified === true && session.sourceID === targetID);
}

function exactTargetMatch(
  sessions: SessionEntry[],
  target: ActivityRouteSelection
): { session: SessionEntry | null; ambiguous: boolean } {
  const matches = sessions.filter((session) => sessionMatchesActivityTarget(session, target));
  return {
    session: matches.length === 1 ? matches[0]! : null,
    ambiguous: matches.length > 1
  };
}

export const useActivityStore = create<ActivityState>()((set, get) => ({
  sessions: [],
  loading: false,
  error: null,
  query: '',
  visibleCount: ACTIVITY_PAGE_SIZE,
  target: null,
  targetSession: null,
  targetLoading: false,
  targetError: null,

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

  async openTarget(target) {
    const requestGeneration = ++activityTargetGeneration;
    const targetID = activityTargetID(target);
    const { fixtureMode, bridge } = useShellStore.getState();
    set({
      target,
      targetSession: null,
      targetLoading: true,
      targetError: null
    });

    const publish = (session: SessionEntry | null, error: string | null) => {
      if (requestGeneration !== activityTargetGeneration) return;
      set({
        targetSession: session,
        targetLoading: false,
        targetError: error
      });
    };

    const loaded = exactTargetMatch(get().sessions, target);
    if (loaded.ambiguous) {
      publish(null, 'More than one activity row claims this exact target identity.');
      return;
    }
    if (loaded.session) {
      publish(loaded.session, null);
      return;
    }

    if (fixtureMode) {
      const fixture = exactTargetMatch(fixtureSessionList().sessions, target);
      publish(
        fixture.session,
        fixture.ambiguous
          ? 'More than one fixture activity row claims this exact target identity.'
          : fixture.session
            ? null
            : 'This exact session is unavailable in the fixture transcript.'
      );
      return;
    }

    if (!bridge) {
      publish(null, 'Exact activity navigation requires the packaged daemon session index.');
      return;
    }

    try {
      const searched = exactTargetMatch((await bridge.sessionSearch(targetID)).sessions, target);
      if (searched.ambiguous) {
        publish(null, 'The daemon returned more than one exact activity target.');
        return;
      }
      if (searched.session) {
        publish(searched.session, null);
        return;
      }

      if (!bridge.sessionHistory) {
        publish(
          null,
          'The exact activity target was not found, and this packaged daemon cannot verify complete session history.'
        );
        return;
      }
      const history = await bridge.sessionHistory();
      const historical = exactTargetMatch(history.sessions, target);
      if (historical.ambiguous) {
        publish(null, 'Complete session history contains more than one exact target identity.');
        return;
      }
      if (historical.session) {
        publish(historical.session, null);
        return;
      }
      publish(
        null,
        history.complete && history.historyComplete && history.nextCursor === null
          ? 'This exact session or conversation is no longer present in the daemon index.'
          : 'The daemon could not prove complete history, so this exact target cannot be declared missing safely.'
      );
    } catch (error) {
      publish(
        null,
        error instanceof Error ? error.message : 'Exact activity target lookup failed.'
      );
    }
  },

  clearTarget() {
    activityTargetGeneration += 1;
    set({
      target: null,
      targetSession: null,
      targetLoading: false,
      targetError: null
    });
  },

  loadMore() {
    set((s) => ({ visibleCount: s.visibleCount + ACTIVITY_PAGE_SIZE }));
  }
}));
