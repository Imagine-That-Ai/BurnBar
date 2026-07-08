import { create } from 'zustand';
import { fixtureMercuryMediaStatus } from '../daemonFixture.js';
import type { MercuryMediaStatus, MercurySessionState } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

export type MercuryStage = MercurySessionState;
export type MediaLoadState = 'idle' | 'loading' | 'ready' | 'capability-absent' | 'empty' | 'error' | 'offline';

export type MercuryStageEvent = {
  state: MercuryStage;
  at: string;
  detail?: string;
};

export type MediaStoreState = {
  status: MercuryMediaStatus | null;
  loadState: MediaLoadState;
  error: string | null;
  stageEvents: MercuryStageEvent[];
  load(): Promise<void>;
  ingestStage(event: Partial<MercuryStageEvent> & { state: string }): void;
  reset(): void;
};

const STAGE_ORDER: MercuryStage[] = ['staged', 'connecting', 'active', 'ended'];

export function normalizeMercuryStage(state: string): MercuryStage {
  const lower = state.toLowerCase();
  if (lower.includes('connect') || lower.includes('start')) return 'connecting';
  if (lower.includes('active') || lower.includes('stream')) return 'active';
  if (lower.includes('end') || lower.includes('stop') || lower.includes('done')) return 'ended';
  return 'staged';
}

export function mergeStageEvent(
  events: MercuryStageEvent[],
  incoming: { state: string; at: string; detail?: string }
): MercuryStageEvent[] {
  const normalized = { ...incoming, state: normalizeMercuryStage(incoming.state) };
  const withoutSame = events.filter((event) => event.state !== normalized.state);
  return [...withoutSame, normalized].sort(
    (a, b) => STAGE_ORDER.indexOf(a.state) - STAGE_ORDER.indexOf(b.state)
  );
}

function initialStageEvents(status: MercuryMediaStatus | null): MercuryStageEvent[] {
  const state = status?.activeSession?.state;
  if (!state) return [];
  const now = new Date().toISOString();
  const index = STAGE_ORDER.indexOf(state);
  return STAGE_ORDER.slice(0, Math.max(index + 1, 1)).map((stage) => ({
    state: stage,
    at: now,
    detail: stage === state ? 'Current media-control stage' : 'Observed earlier in this session'
  }));
}

export const useMediaStore = create<MediaStoreState>()((set, get) => ({
  status: null,
  loadState: 'idle',
  error: null,
  stageEvents: [],

  async load() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      const status = fixtureMercuryMediaStatus();
      set({
        status,
        loadState: 'ready',
        error: null,
        stageEvents: initialStageEvents(status)
      });
      return;
    }
    if (!bridge) {
      set({ status: null, loadState: 'offline', error: null, stageEvents: [] });
      return;
    }
    set({ loadState: 'loading', error: null });
    try {
      const status = await bridge.mediaStatus();
      const loadState: MediaLoadState = !status.capabilityAvailable
        ? 'capability-absent'
        : status.pairedDevices.length === 0 && !status.activeSession
          ? 'empty'
          : 'ready';
      set({
        status,
        loadState,
        error: null,
        stageEvents: initialStageEvents(status)
      });
    } catch (e) {
      set({
        status: null,
        loadState: 'error',
        error: e instanceof Error ? e.message : 'Media status request failed',
        stageEvents: []
      });
    }
  },

  ingestStage(event) {
    const normalized: MercuryStageEvent = {
      state: normalizeMercuryStage(event.state),
      at: event.at ?? new Date().toISOString(),
      detail: event.detail
    };
    set({ stageEvents: mergeStageEvent(get().stageEvents, normalized) });
  },

  reset() {
    set({ status: null, loadState: 'idle', error: null, stageEvents: [] });
  }
}));
