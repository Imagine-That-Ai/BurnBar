import { create } from 'zustand';
import { fixtureMercuryMediaStatus } from '../daemonFixture.js';
import type {
  MercuryFileOfferListResponse,
  MercuryFileTransfer,
  MercuryFileTransferActionResponse,
  MercuryCallPhase,
  MercuryMediaSessionState,
  MercuryMediaStatus,
  MercurySessionState
} from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

export type MercuryStage = MercurySessionState;
export type MediaLoadState = 'idle' | 'loading' | 'ready' | 'capability-absent' | 'empty' | 'error' | 'offline';
export type MercuryMediaControlState = 'idle' | 'available' | 'degraded' | 'error';

export type MercuryMediaControlSnapshot = {
  state: MercuryMediaControlState;
  supportsShellToDaemonControl: boolean | null;
  reason: string | null;
};

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
  /** Media socket direction; does not describe authenticated daemon RPCs. */
  mediaControlState: MercuryMediaControlState;
  mediaControlReason: string | null;
  /** Call/file RPC availability, kept separate from the one-way media socket. */
  mediaRpcControlState: MercuryMediaControlState;
  mediaRpcControlReason: string | null;
  error: string | null;
  callError: string | null;
  callState: MercuryCallState;
  stageEvents: MercuryStageEvent[];
  fileTransfers: MercuryFileTransfer[];
  fileCapabilityAvailable: boolean | null;
  fileDownloadDirectory: string | null;
  fileError: string | null;
  fileBusyTransferID: string | null;
  load(): Promise<void>;
  acceptCall(requestId?: string): Promise<void>;
  declineCall(requestId?: string): Promise<void>;
  endCall(): Promise<void>;
  refreshFileTransfers(): Promise<void>;
  acceptFileTransfer(transferID?: string, manifestID?: string): Promise<void>;
  declineFileTransfer(transferID?: string, manifestID?: string): Promise<void>;
  sendFileTransfer(path: string, peerID?: string): Promise<void>;
  scriptFixtureFileTransfer(): void;
  ingestFileOfferList(response: MercuryFileOfferListResponse): void;
  ingestFileAction(response: MercuryFileTransferActionResponse): void;
  ingestStage(event: Partial<MercuryStageEvent> & { state: string }): void;
  ingestSessionState(state: MercuryMediaSessionState, source?: MercuryCallState['source']): void;
  startLiveSessionObservers(): void;
  stopLiveSessionObservers(): void;
  reset(): void;
};

const STAGE_ORDER: MercuryStage[] = ['staged', 'connecting', 'active', 'ended'];
const FIXTURE_REQUEST_ID = 'fixture-call-001';
const FIXTURE_FILE_TRANSFER_ID = 'fixture-file-001';
const IDLE_CALL: MercuryCallState = { phase: 'idle', kind: 'call', source: 'live' };
const IDLE_MEDIA_CONTROL: MercuryMediaControlSnapshot = {
  state: 'idle',
  supportsShellToDaemonControl: null,
  reason: null
};

let mediaPollInterval: ReturnType<typeof setInterval> | null = null;
let eventListenersStarted = false;
let eventUnlisteners: Array<() => void> = [];
let mediaLoadGeneration = 0;

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

/**
 * Resolve the daemon's media control direction without guessing from the
 * capture capability. Linux deliberately ships a daemon-to-shell media
 * socket today, so a capture-capable daemon can still be unable to accept
 * shell-originated media control frames.
 */
export function resolveMercuryMediaControl(value: unknown): MercuryMediaControlSnapshot {
  const objects: Record<string, unknown>[] = [];
  const visit = (candidate: unknown): void => {
    if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)) return;
    const object = candidate as Record<string, unknown>;
    objects.push(object);
    for (const key of ['capability', 'mediaCapability', 'media_capability']) {
      visit(object[key]);
    }
  };
  visit(value);

  const reason = objects
    .flatMap((object) => ['reason', 'detail', 'error'].map((key) => object[key]))
    .find((candidate): candidate is string => typeof candidate === 'string' && candidate.trim().length > 0)
    ?.trim() ?? null;
  const explicit = objects
    .flatMap((object) => ['supportsShellToDaemonControl', 'supports_shell_to_daemon_control'].map((key) => object[key]))
    .find((candidate): candidate is boolean => typeof candidate === 'boolean');
  const oneWayDetail = reason && /daemon(?:-|\s)to(?:-|\s)shell(?:-|\s)only|shell media socket is daemon-to-shell only|no control route/i.test(reason);
  const supportsShellToDaemonControl = explicit ?? (oneWayDetail ? false : null);

  if (supportsShellToDaemonControl === true) {
    return { state: 'available', supportsShellToDaemonControl, reason };
  }
  if (supportsShellToDaemonControl === false) {
    return {
      state: 'degraded',
      supportsShellToDaemonControl,
      reason: reason ?? 'The daemon exposes capture, but this Linux media route does not accept shell control.'
    };
  }
  return {
    state: 'degraded',
    supportsShellToDaemonControl: null,
    reason: reason ?? 'The daemon did not advertise the media socket control direction; shell-originated media frames remain disabled.'
  };
}

function controlError(state: MercuryMediaControlState, reason: string | null): string {
  if (state === 'idle') return reason ?? 'Mercury controls are still loading.';
  if (state === 'error') return reason ?? 'Mercury control capability could not be verified.';
  return reason ?? 'Mercury controls are unavailable on this Linux session.';
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

function fixtureFileOffer(): MercuryFileTransfer {
  const now = new Date().toISOString();
  return {
    transferID: FIXTURE_FILE_TRANSFER_ID,
    manifestID: 'fixture-manifest-001',
    direction: 'inbound',
    phase: 'pendingAccept',
    filename: 'mercury-fixture.pdf',
    mime: 'application/pdf',
    size: 1_572_864,
    peer: {
      id: 'fixture-phone',
      name: 'Fixture iPhone',
      isOnline: true,
      lastSeenAt: now,
      capabilities: ['file.send', 'file.receive']
    },
    progress: { bytesTransferred: 0, bytesTotal: 1_572_864, fraction: 0 },
    createdAt: now,
    updatedAt: now
  };
}

function transferKey(transfer: Pick<MercuryFileTransfer, 'transferID' | 'manifestID'>): string {
  return transfer.transferID || transfer.manifestID;
}

function matchesTransfer(transfer: MercuryFileTransfer, transferID?: string, manifestID?: string): boolean {
  return Boolean((transferID && transfer.transferID === transferID) || (manifestID && transfer.manifestID === manifestID));
}

function upsertTransfer(transfers: MercuryFileTransfer[], next: MercuryFileTransfer): MercuryFileTransfer[] {
  const key = transferKey(next);
  const filtered = transfers.filter((transfer) => transferKey(transfer) !== key);
  return [...filtered, next].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
}

function filenameFromPath(path: string): string {
  const parts = path.split(/[\\/]/).filter(Boolean);
  return parts.length > 0 ? parts[parts.length - 1] : 'openburnbar-transfer.bin';
}

export const useMediaStore = create<MediaStoreState>()((set, get) => ({
  status: null,
  loadState: 'idle',
  mediaControlState: IDLE_MEDIA_CONTROL.state,
  mediaControlReason: IDLE_MEDIA_CONTROL.reason,
  mediaRpcControlState: IDLE_MEDIA_CONTROL.state,
  mediaRpcControlReason: IDLE_MEDIA_CONTROL.reason,
  error: null,
  callError: null,
  callState: IDLE_CALL,
  stageEvents: [],
  fileTransfers: [],
  fileCapabilityAvailable: null,
  fileDownloadDirectory: null,
  fileError: null,
  fileBusyTransferID: null,

  async load() {
    const requestGeneration = ++mediaLoadGeneration;
    const isCurrentRequest = () => requestGeneration === mediaLoadGeneration;
    const { fixtureMode, bridge } = useShellStore.getState();
    get().stopLiveSessionObservers();
    if (fixtureMode) {
      // Rich fixture is opt-in for UX demos; default is capability-absent (live parity).
      const rich = (() => {
        try {
          return localStorage.getItem('openburnbar.linux.mediaFixtureRich') === '1';
        } catch {
          return false;
        }
      })();
      const status = fixtureMercuryMediaStatus({ rich });
      const loadState: MediaLoadState = !status.capabilityAvailable
        ? 'capability-absent'
        : status.pairedDevices.length === 0 && !status.activeSession
          ? 'empty'
          : 'ready';
      set({
        status,
        loadState,
        mediaControlState: 'available',
        mediaControlReason: null,
        mediaRpcControlState: status.capabilityAvailable ? 'available' : 'degraded',
        mediaRpcControlReason: status.capabilityAvailable
          ? null
          : status.reason ?? 'Mercury daemon RPC capability is unavailable on this session.',
        error: null,
        callError: null,
        callState: fixtureRingingState(),
        stageEvents: initialStageEvents(status),
        fileTransfers: [fixtureFileOffer()],
        fileCapabilityAvailable: true,
        fileDownloadDirectory: '~/Downloads',
        fileError: null,
        fileBusyTransferID: null
      });
      return;
    }
    if (!bridge) {
      set({
        status: null,
        loadState: 'offline',
        mediaControlState: 'idle',
        mediaControlReason: 'Connect the packaged shell before using Mercury controls.',
        mediaRpcControlState: 'idle',
        mediaRpcControlReason: 'Connect the packaged shell before using Mercury controls.',
        error: null,
        callError: null,
        callState: IDLE_CALL,
        stageEvents: [],
        fileTransfers: [],
        fileCapabilityAvailable: null,
        fileDownloadDirectory: null,
        fileError: null,
        fileBusyTransferID: null
      });
      return;
    }
    set({
      status: null,
      loadState: 'loading',
      mediaControlState: 'idle',
      mediaControlReason: null,
      mediaRpcControlState: 'idle',
      mediaRpcControlReason: null,
      error: null,
      callError: null,
      callState: IDLE_CALL,
      stageEvents: [],
      fileTransfers: [],
      fileCapabilityAvailable: null,
      fileDownloadDirectory: null,
      fileError: null,
      fileBusyTransferID: null
    });
    try {
      const status = await bridge.mediaStatus();
      let fileList: MercuryFileOfferListResponse | null = null;
      let fileError: string | null = null;
      try {
        fileList = await bridge.mediaFileOfferList();
      } catch (e) {
        fileError = e instanceof Error ? e.message : 'File transfer offer list failed';
      }
      if (!isCurrentRequest()) return;
      const fileTransfers = fileList?.transfers ?? [];
      const fileCapabilityAvailable = fileList?.capabilityAvailable ?? null;
      const hasFileRows = fileCapabilityAvailable === true && fileTransfers.length > 0;
      const loadState: MediaLoadState = !status.capabilityAvailable && fileCapabilityAvailable !== true
        ? 'capability-absent'
        : status.pairedDevices.length === 0 && !status.activeSession && !hasFileRows
          ? 'empty'
          : 'ready';
      let mediaControl = resolveMercuryMediaControl(status);
      // Older bridge payloads may omit the nested capability detail. Ask the
      // dedicated probe before failing closed, while preserving the status
      // result as the source of truth when it already declares a direction.
      if (mediaControl.supportsShellToDaemonControl === null) {
        try {
          mediaControl = resolveMercuryMediaControl(await bridge.mediaCapabilityGet());
        } catch (e) {
          mediaControl = {
            state: 'error',
            supportsShellToDaemonControl: null,
            reason: e instanceof Error ? e.message : 'Mercury control capability request failed'
          };
        }
      }
      if (!isCurrentRequest()) return;
      set({
        status,
        loadState,
        mediaControlState: mediaControl.state,
        mediaControlReason: mediaControl.reason,
        mediaRpcControlState: status.capabilityAvailable ? 'available' : 'degraded',
        mediaRpcControlReason: status.capabilityAvailable
          ? null
          : status.reason ?? 'Mercury daemon RPC capability is unavailable on this session.',
        error: null,
        stageEvents: initialStageEvents(status),
        fileTransfers,
        fileCapabilityAvailable,
        fileDownloadDirectory: fileList?.downloadDirectory ?? null,
        fileError: fileError ?? fileList?.detail ?? null,
        fileBusyTransferID: null
      });
      if (status.capabilityAvailable || fileCapabilityAvailable === true) {
        try {
          const sessionState = await bridge.mediaSessionState();
          if (!isCurrentRequest()) return;
          get().ingestSessionState(sessionState, 'live');
          if (!isCurrentRequest()) return;
          get().startLiveSessionObservers();
        } catch (e) {
          if (!isCurrentRequest()) return;
          const reason = e instanceof Error ? e.message : 'Media session state request failed';
          set({
            callError: reason,
            mediaControlState: 'error',
            mediaControlReason: reason,
            mediaRpcControlState: 'error',
            mediaRpcControlReason: reason
          });
        }
      } else {
        set({ callState: { phase: 'capability-absent', kind: 'call', source: 'absent' } });
      }
    } catch (e) {
      if (!isCurrentRequest()) return;
      const reason = e instanceof Error ? e.message : 'Media status request failed';
      set({
        status: null,
        loadState: 'error',
        mediaControlState: 'error',
        mediaControlReason: reason,
        mediaRpcControlState: 'error',
        mediaRpcControlReason: reason,
        error: reason,
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
    if (get().mediaRpcControlState !== 'available') {
      set({ callError: controlError(get().mediaRpcControlState, get().mediaRpcControlReason) });
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
    if (get().mediaRpcControlState !== 'available') {
      set({ callError: controlError(get().mediaRpcControlState, get().mediaRpcControlReason) });
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
    if (get().mediaRpcControlState !== 'available') {
      set({ callError: controlError(get().mediaRpcControlState, get().mediaRpcControlReason) });
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

  async refreshFileTransfers() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      if (get().fileTransfers.length === 0) {
        set({
          fileTransfers: [fixtureFileOffer()],
          fileCapabilityAvailable: true,
          fileDownloadDirectory: '~/Downloads',
          fileError: null
        });
      }
      return;
    }
    if (!bridge) {
      set({ fileTransfers: [], fileCapabilityAvailable: null, fileDownloadDirectory: null, fileError: null });
      return;
    }
    try {
      get().ingestFileOfferList(await bridge.mediaFileOfferList());
    } catch (e) {
      set({ fileError: e instanceof Error ? e.message : 'File transfer offer list failed' });
    }
  },

  async acceptFileTransfer(transferID, manifestID) {
    const { fixtureMode, bridge } = useShellStore.getState();
    const transfer = get().fileTransfers.find((candidate) => matchesTransfer(candidate, transferID, manifestID));
    if (fixtureMode) {
      const current = transfer ?? get().fileTransfers.find((candidate) => candidate.phase === 'pendingAccept');
      if (!current) return;
      const now = new Date().toISOString();
      const half = Math.max(1, Math.floor(current.size / 2));
      const downloading: MercuryFileTransfer = {
        ...current,
        phase: 'downloading',
        progress: { bytesTransferred: half, bytesTotal: current.size, fraction: current.size > 0 ? half / current.size : 0 },
        updatedAt: now
      };
      set({ fileTransfers: upsertTransfer(get().fileTransfers, downloading), fileError: null });
      await Promise.resolve();
      const completedAt = new Date().toISOString();
      const completed: MercuryFileTransfer = {
        ...downloading,
        phase: 'completed',
        progress: { bytesTransferred: current.size, bytesTotal: current.size, fraction: current.size > 0 ? 1 : 0 },
        localPath: `${get().fileDownloadDirectory ?? '~/Downloads'}/${current.filename}`,
        updatedAt: completedAt,
        completedAt
      };
      set({ fileTransfers: upsertTransfer(get().fileTransfers, completed), fileError: null });
      return;
    }
    if (get().fileCapabilityAvailable === false) {
      set({ fileError: 'File transfer capability is unavailable on this daemon.' });
      return;
    }
    if (!bridge) return;
    const busyID = transferID ?? manifestID ?? transfer?.transferID ?? null;
    set({ fileBusyTransferID: busyID, fileError: null });
    try {
      const response = await bridge.mediaFileAccept({ transferID, manifestID });
      get().ingestFileAction(response);
      if (response.accepted) {
        await get().refreshFileTransfers();
      }
    } catch (e) {
      set({ fileError: e instanceof Error ? e.message : 'Accept file transfer failed' });
    } finally {
      set({ fileBusyTransferID: null });
    }
  },

  async declineFileTransfer(transferID, manifestID) {
    const { fixtureMode, bridge } = useShellStore.getState();
    const transfer = get().fileTransfers.find((candidate) => matchesTransfer(candidate, transferID, manifestID));
    if (fixtureMode) {
      const current = transfer ?? get().fileTransfers.find((candidate) => candidate.phase === 'pendingAccept');
      if (!current) return;
      const now = new Date().toISOString();
      set({
        fileTransfers: upsertTransfer(get().fileTransfers, {
          ...current,
          phase: 'declined',
          updatedAt: now,
          completedAt: now
        }),
        fileError: null
      });
      return;
    }
    if (get().fileCapabilityAvailable === false) {
      set({ fileError: 'File transfer capability is unavailable on this daemon.' });
      return;
    }
    if (!bridge) return;
    const busyID = transferID ?? manifestID ?? transfer?.transferID ?? null;
    set({ fileBusyTransferID: busyID, fileError: null });
    try {
      get().ingestFileAction(await bridge.mediaFileDecline({ transferID, manifestID, reason: 'declined-from-linux-shell' }));
      await get().refreshFileTransfers();
    } catch (e) {
      set({ fileError: e instanceof Error ? e.message : 'Decline file transfer failed' });
    } finally {
      set({ fileBusyTransferID: null });
    }
  },

  async sendFileTransfer(path, peerID) {
    const trimmedPath = path.trim();
    if (!trimmedPath) {
      set({ fileError: 'Choose a file path to send.' });
      return;
    }
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      const now = new Date().toISOString();
      const size = 2_097_152;
      const sending: MercuryFileTransfer = {
        transferID: `fixture-send-${Date.now()}`,
        manifestID: `fixture-send-manifest-${Date.now()}`,
        direction: 'outbound',
        phase: 'sending',
        filename: filenameFromPath(trimmedPath),
        mime: 'application/octet-stream',
        size,
        peer: {
          id: peerID ?? 'fixture-phone',
          name: 'Fixture iPhone',
          isOnline: true,
          lastSeenAt: now,
          capabilities: ['file.send', 'file.receive']
        },
        progress: { bytesTransferred: Math.floor(size / 2), bytesTotal: size, fraction: 0.5 },
        localPath: trimmedPath,
        createdAt: now,
        updatedAt: now
      };
      set({ fileTransfers: upsertTransfer(get().fileTransfers, sending), fileError: null });
      await Promise.resolve();
      const completedAt = new Date().toISOString();
      set({
        fileTransfers: upsertTransfer(get().fileTransfers, {
          ...sending,
          phase: 'completed',
          progress: { bytesTransferred: size, bytesTotal: size, fraction: 1 },
          updatedAt: completedAt,
          completedAt
        }),
        fileError: null
      });
      return;
    }
    if (get().fileCapabilityAvailable === false) {
      set({ fileError: 'File transfer capability is unavailable on this daemon.' });
      return;
    }
    if (!bridge) return;
    set({ fileBusyTransferID: 'send', fileError: null });
    try {
      const response = await bridge.mediaFileSend({ path: trimmedPath, peerID });
      get().ingestFileAction(response);
      if (response.accepted) {
        await get().refreshFileTransfers();
      }
    } catch (e) {
      set({ fileError: e instanceof Error ? e.message : 'Send file transfer failed' });
    } finally {
      set({ fileBusyTransferID: null });
    }
  },

  scriptFixtureFileTransfer() {
    const { fixtureMode } = useShellStore.getState();
    if (!fixtureMode) return;
    set({
      fileTransfers: upsertTransfer(get().fileTransfers, fixtureFileOffer()),
      fileCapabilityAvailable: true,
      fileDownloadDirectory: '~/Downloads',
      fileError: null
    });
  },

  ingestFileOfferList(response) {
    set({
      fileTransfers: response.transfers,
      fileCapabilityAvailable: response.capabilityAvailable,
      fileDownloadDirectory: response.downloadDirectory ?? null,
      fileError: response.capabilityAvailable ? null : (response.detail ?? null)
    });
  },

  ingestFileAction(response) {
    if (response.transfer) {
      set({ fileTransfers: upsertTransfer(get().fileTransfers, response.transfer) });
    }
    set({
      fileError: response.accepted ? null : (response.detail ?? response.errorCode ?? 'File transfer action failed')
    });
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
    const observerGeneration = mediaLoadGeneration;
    if (mediaPollInterval === null) {
      mediaPollInterval = setInterval(() => {
        void bridge
          .mediaSessionState()
          .then((state) => {
            if (observerGeneration !== mediaLoadGeneration) return;
            get().ingestSessionState(state, 'live');
          })
          .catch((e) => {
            if (observerGeneration !== mediaLoadGeneration) return;
            const reason = e instanceof Error ? e.message : 'Media session poll failed';
            set({
              callError: reason,
              mediaControlState: 'error',
              mediaControlReason: reason,
              mediaRpcControlState: 'error',
              mediaRpcControlReason: reason
            });
          });
        void bridge
          .mediaFileOfferList()
          .then((response) => {
            if (observerGeneration !== mediaLoadGeneration) return;
            get().ingestFileOfferList(response);
          })
          .catch((e) => {
            if (observerGeneration !== mediaLoadGeneration) return;
            set({ fileError: e instanceof Error ? e.message : 'File transfer poll failed' });
          });
      }, 500);
    }
    if (!eventListenersStarted && typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window) {
      eventListenersStarted = true;
      void import('@tauri-apps/api/event')
        .then(async ({ listen }) => {
          const incoming = await listen('media-incoming-call', (event) => {
            if (observerGeneration !== mediaLoadGeneration) return;
            get().ingestSessionState(sessionFromEventPayload(event.payload), 'event');
          });
          const changed = await listen('media-call-state-changed', (event) => {
            if (observerGeneration !== mediaLoadGeneration) return;
            get().ingestSessionState(sessionFromEventPayload(event.payload), 'event');
          });
          if (observerGeneration !== mediaLoadGeneration) {
            incoming();
            changed();
            return;
          }
          eventUnlisteners = [incoming, changed];
        })
        .catch((e) => {
          if (observerGeneration !== mediaLoadGeneration) return;
          set({ callError: e instanceof Error ? e.message : 'Media event listener failed' });
        });
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
    mediaLoadGeneration += 1;
    get().stopLiveSessionObservers();
    set({
      status: null,
      loadState: 'idle',
      mediaControlState: IDLE_MEDIA_CONTROL.state,
      mediaControlReason: IDLE_MEDIA_CONTROL.reason,
      mediaRpcControlState: IDLE_MEDIA_CONTROL.state,
      mediaRpcControlReason: IDLE_MEDIA_CONTROL.reason,
      error: null,
      callError: null,
      callState: IDLE_CALL,
      stageEvents: [],
      fileTransfers: [],
      fileCapabilityAvailable: null,
      fileDownloadDirectory: null,
      fileError: null,
      fileBusyTransferID: null
    });
  }
}));
