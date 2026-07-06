import { create } from 'zustand';
import { fixtureMercuryMediaStatus } from '../daemonFixture.js';
import type {
  MercuryCallPhase,
  MercuryMediaSessionState,
  MercuryMediaStatus,
  MercurySessionState
} from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

export type MercuryStage = MercurySessionState;
export type MediaLoadState = 'idle' | 'loading' | 'ready' | 'capability-absent' | 'empty' | 'error' | 'offline';

export type MercuryStageEvent = {
  state: MercuryStage;
  at: string;
  detail?: string;
};

export type MercuryCallState = {
  phase: MercuryCallPhase;
  requestId?: string;
  peerName?: string;
  peerId?: string;
  startedAt?: string;
  endedAt?: string;
  kind: 'call' | 'screen-share' | 'file';
  source: 'fixture' | 'live' | 'event' | 'absent';
};

export type MediaStoreState = {
  status: MercuryMediaStatus | null;
  loadState: MediaLoadState;
  error: string | null;
  callError: string | null;
  callState: MercuryCallState;
  stageEvents: MercuryStageEvent[];
  load(): Promise<void>;
  acceptCall(requestId?: string): Promise<void>;
  declineCall(requestId?: string): Promise<void>;
  endCall(): Promise<void>;
  ingestStage(event: Partial<MercuryStageEvent> & { state: string }): void;
  ingestSessionState(state: MercuryMediaSessionState, source?: MercuryCallState['source']): void;
  startLiveSessionObservers(): void;
  stopLiveSessionObservers(): void;
  reset(): void;
};

const STAGE_ORDER: MercuryStage[] = ['staged', 'connecting', 'active', 'ended'];
const FIXTURE_REQUEST_ID = 'fixture-call-001';
const IDLE_CALL: MercuryCallState = { phase: 'idle', kind: 'call', source: 'live' };

let mediaPollInterval: ReturnType<typeof setInterval> | null = null;
let eventListenersStarted = false;
let eventUnlisteners: Array<() => void> = [];

export function normalizeMercuryStage(state: string): MercuryStage {
  const lower = state.toLowerCase();
  if (lower.includes('connect') || lower.includes('start')) return 'connecting';
  if (lower.includes('active') || lower.includes('stream')) return 'active';
  if (lower.includes('end') || lower.includes('stop') || lower.includes('done')) return 'ended';
  return 'staged';
}

export function normalizeCallPhase(state: string): MercuryCallPhase {
  const lower = state.toLowerCase();
  if (lower.includes('absent') || lower.includes('unsupported')) return 'capability-absent';
  if (lower.includes('ring') || lower.includes('incoming')) return 'ringing';
  if (lower.includes('stream') || lower.includes('active') || lower.includes('accepted') || lower.includes('viewer')) return 'streaming';
  if (lower.includes('cool') || lower.includes('declin') || lower.includes('end') || lower.includes('stop')) return 'cooldown';
  return 'idle';
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

function callStateFromSession(
  state: MercuryMediaSessionState,
  source: MercuryCallState['source']
): MercuryCallState {
  return {
    phase: state.phase,
    requestId: state.requestId,
    peerName: state.peerName,
    peerId: state.peerId,
    startedAt: state.startedAt,
    endedAt: state.endedAt,
    kind: state.kind,
    source: state.phase === 'capability-absent' ? 'absent' : source
  };
}

function sessionFromEventPayload(payload: unknown): MercuryMediaSessionState {
  const value = payload && typeof payload === 'object' ? (payload as Record<string, unknown>) : {};
  const incoming =
    value.incomingCall && typeof value.incomingCall === 'object'
      ? (value.incomingCall as Record<string, unknown>)
      : value.incoming_call && typeof value.incoming_call === 'object'
        ? (value.incoming_call as Record<string, unknown>)
        : {};
  const session =
    value.activeSession && typeof value.activeSession === 'object'
      ? (value.activeSession as Record<string, unknown>)
      : value.session && typeof value.session === 'object'
        ? (value.session as Record<string, unknown>)
        : {};
  const source = Object.keys(incoming).length > 0 ? incoming : Object.keys(session).length > 0 ? session : value;
  const read = (...keys: string[]) => {
    for (const key of keys) {
      const current = source[key] ?? value[key];
      if (typeof current === 'string' && current.length > 0) return current;
    }
    return undefined;
  };
  const phase = normalizeCallPhase(read('phase', 'state', 'status') ?? 'idle');
  return {
    phase,
    requestId: read('requestId', 'request_id'),
    peerName: read('peerName', 'peer_name', 'peer', 'deviceName'),
    peerId: read('peerId', 'peer_id', 'deviceId'),
    kind: read('kind', 'type') === 'screen-share' || read('kind', 'type') === 'file' ? (read('kind', 'type') as 'screen-share' | 'file') : 'call',
    startedAt: read('startedAt', 'started_at'),
    endedAt: read('endedAt', 'ended_at'),
    capabilityAvailable: phase !== 'capability-absent',
    raw: payload
  };
}

function fixtureRingingState(): MercuryCallState {
  return {
    phase: 'ringing',
    requestId: FIXTURE_REQUEST_ID,
    peerName: 'Alberto MacBook Pro',
    peerId: 'macbook-pro-relay',
    kind: 'call',
    source: 'fixture'
  };
}

export const useMediaStore = create<MediaStoreState>()((set, get) => ({
  status: null,
  loadState: 'idle',
  error: null,
  callError: null,
  callState: IDLE_CALL,
  stageEvents: [],

  async load() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      const status = fixtureMercuryMediaStatus();
      set({
        status,
        loadState: 'ready',
        error: null,
        callError: null,
        callState: fixtureRingingState(),
        stageEvents: initialStageEvents(status)
      });
      return;
    }
    if (!bridge) {
      set({ status: null, loadState: 'offline', error: null, callError: null, callState: IDLE_CALL, stageEvents: [] });
      return;
    }
    set({ loadState: 'loading', error: null, callError: null });
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
      if (status.capabilityAvailable) {
        try {
          get().ingestSessionState(await bridge.mediaSessionState(), 'live');
          get().startLiveSessionObservers();
        } catch (e) {
          set({ callError: e instanceof Error ? e.message : 'Media session state request failed' });
        }
      } else {
        set({ callState: { phase: 'capability-absent', kind: 'call', source: 'absent' } });
      }
    } catch (e) {
      set({
        status: null,
        loadState: 'error',
        error: e instanceof Error ? e.message : 'Media status request failed',
        stageEvents: []
      });
    }
  },

  async acceptCall(requestId) {
    const { fixtureMode, bridge } = useShellStore.getState();
    const id = requestId ?? get().callState.requestId;
    if (!id) return;
    if (fixtureMode) {
      get().ingestSessionState(
        {
          phase: 'streaming',
          requestId: id,
          peerName: get().callState.peerName,
          peerId: get().callState.peerId,
          kind: 'call',
          startedAt: new Date().toISOString(),
          capabilityAvailable: true
        },
        'fixture'
      );
      return;
    }
    if (!bridge) return;
    try {
      get().ingestSessionState(await bridge.mediaAcceptCall(id), 'live');
      set({ callError: null });
    } catch (e) {
      set({ callError: e instanceof Error ? e.message : 'Accept call failed' });
    }
  },

  async declineCall(requestId) {
    const { fixtureMode, bridge } = useShellStore.getState();
    const id = requestId ?? get().callState.requestId;
    if (!id) return;
    if (fixtureMode) {
      set({
        callState: {
          phase: 'cooldown',
          requestId: id,
          peerName: get().callState.peerName,
          peerId: get().callState.peerId,
          kind: 'call',
          endedAt: new Date().toISOString(),
          source: 'fixture'
        },
        callError: null
      });
      return;
    }
    if (!bridge) return;
    try {
      get().ingestSessionState(await bridge.mediaDeclineCall(id), 'live');
      set({ callError: null });
    } catch (e) {
      set({ callError: e instanceof Error ? e.message : 'Decline call failed' });
    }
  },

  async endCall() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({
        callState: {
          ...get().callState,
          phase: 'cooldown',
          endedAt: new Date().toISOString(),
          source: 'fixture'
        },
        callError: null
      });
      return;
    }
    if (!bridge) return;
    try {
      get().ingestSessionState(await bridge.mediaEndCall(), 'live');
      set({ callError: null });
    } catch (e) {
      set({ callError: e instanceof Error ? e.message : 'End call failed' });
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

  ingestSessionState(state, source = 'live') {
    const next = callStateFromSession(state, source);
    set({
      callState: next,
      callError: null,
      loadState:
        state.phase === 'capability-absent' && ['idle', 'loading'].includes(get().loadState)
          ? 'capability-absent'
          : get().loadState
    });
    if (next.phase === 'streaming') {
      get().ingestStage({ state: 'active', at: next.startedAt ?? new Date().toISOString(), detail: 'Call viewer streaming' });
    }
    if (next.phase === 'cooldown') {
      get().ingestStage({ state: 'ended', at: next.endedAt ?? new Date().toISOString(), detail: 'Call ended' });
    }
  },

  startLiveSessionObservers() {
    const { bridge, fixtureMode } = useShellStore.getState();
    if (fixtureMode || !bridge) return;
    if (mediaPollInterval === null) {
      mediaPollInterval = setInterval(() => {
        void bridge
          .mediaSessionState()
          .then((state) => get().ingestSessionState(state, 'live'))
          .catch((e) => set({ callError: e instanceof Error ? e.message : 'Media session poll failed' }));
      }, 500);
    }
    if (!eventListenersStarted && typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window) {
      eventListenersStarted = true;
      void import('@tauri-apps/api/event')
        .then(async ({ listen }) => {
          const incoming = await listen('media-incoming-call', (event) => {
            get().ingestSessionState(sessionFromEventPayload(event.payload), 'event');
          });
          const changed = await listen('media-call-state-changed', (event) => {
            get().ingestSessionState(sessionFromEventPayload(event.payload), 'event');
          });
          eventUnlisteners = [incoming, changed];
        })
        .catch((e) => set({ callError: e instanceof Error ? e.message : 'Media event listener failed' }));
    }
  },

  stopLiveSessionObservers() {
    if (mediaPollInterval !== null) {
      clearInterval(mediaPollInterval);
      mediaPollInterval = null;
    }
    for (const unlisten of eventUnlisteners) unlisten();
    eventUnlisteners = [];
    eventListenersStarted = false;
  },

  reset() {
    get().stopLiveSessionObservers();
    set({ status: null, loadState: 'idle', error: null, callError: null, callState: IDLE_CALL, stageEvents: [] });
  }
}));
