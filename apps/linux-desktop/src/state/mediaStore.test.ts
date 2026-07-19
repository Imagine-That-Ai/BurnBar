import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { bridgeStubDefaults } from '../testing/bridgeStubs.js';
import type { LinuxShellBridge, MercuryFileTransfer, MercuryMediaSessionState, MercuryMediaStatus } from '../tauriBridge.js';
import {
  mergeStageEvent,
  normalizeCallPhase,
  normalizeMercuryStage,
  resolveMercuryMediaControl,
  useMediaStore,
  type MercuryStageEvent
} from './mediaStore.js';
import { useShellStore } from './shellStore.js';

function resetStores(): void {
  useMediaStore.getState().reset();
  useShellStore.setState({
    fixtureMode: false,
    bridge: null,
    bridgeReady: true,
    health: null,
    healthError: null,
    healthBusy: false
  });
}

function bridgeWithSession(overrides: Partial<LinuxShellBridge>): LinuxShellBridge {
  return {
    ...bridgeStubDefaults,
    daemonHealth: vi.fn(),
    openDashboard: vi.fn(),
    quitApp: vi.fn(),
    trayDegraded: vi.fn(),
    measurePerfOperation: vi.fn(),
    usageSummary: vi.fn(),
    providerCatalog: vi.fn(),
    sessionList: vi.fn(),
    sessionSearch: vi.fn(),
    usageInsights: vi.fn(),
    missionList: vi.fn(),
    missionApprovalDecision: vi.fn(),
    configSnapshot: vi.fn(),
    dbStatus: vi.fn(),
    projectList: vi.fn(),
    memoryBoundaries: vi.fn(),
    accountStatus: vi.fn(),
    appVersionInfo: vi.fn(),
    exportDiagnostics: vi.fn(),
    sessionEnv: vi.fn(),
    mediaStatus: vi.fn().mockResolvedValue({
      capabilityAvailable: true,
      pairedDevices: [
        {
          id: 'peer-1',
          name: 'Peer One',
          platform: 'ios',
          isOnline: true,
          lastSeenAt: new Date().toISOString(),
          capabilities: ['call.receive']
        }
      ]
    }),
    ...overrides
  } as LinuxShellBridge;
}

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

function fileTransfer(overrides: Partial<MercuryFileTransfer> = {}): MercuryFileTransfer {
  const now = '2026-07-06T10:00:00.000Z';
  return {
    transferID: 'transfer-1',
    manifestID: 'manifest-1',
    direction: 'inbound',
    phase: 'pendingAccept',
    filename: 'report.pdf',
    mime: 'application/pdf',
    size: 100,
    peer: {
      id: 'peer-1',
      name: 'Live iPhone',
      isOnline: true,
      lastSeenAt: now,
      capabilities: ['file.send']
    },
    progress: { bytesTransferred: 0, bytesTotal: 100, fraction: 0 },
    createdAt: now,
    updatedAt: now,
    ...overrides
  };
}

describe('mediaStore stage reducer', () => {
  it('normalizes daemon phase words into the four Mercury stages', () => {
    expect(normalizeMercuryStage('starting')).toBe('connecting');
    expect(normalizeMercuryStage('streaming')).toBe('active');
    expect(normalizeMercuryStage('stopped')).toBe('ended');
    expect(normalizeMercuryStage('queued')).toBe('staged');
  });

  it('normalizes live call phases', () => {
    expect(normalizeCallPhase('incoming')).toBe('ringing');
    expect(normalizeCallPhase('viewer-active')).toBe('streaming');
    expect(normalizeCallPhase('declined')).toBe('cooldown');
    expect(normalizeCallPhase('unsupported')).toBe('capability-absent');
  });

  it('keeps stage events in rail order and replaces duplicate states', () => {
    const base: MercuryStageEvent[] = [
      { state: 'staged', at: '2026-07-05T00:00:00.000Z' },
      { state: 'active', at: '2026-07-05T00:02:00.000Z' }
    ];
    const merged = mergeStageEvent(base, {
      state: 'connecting',
      at: '2026-07-05T00:01:00.000Z',
      detail: 'control stream opening'
    });
    expect(merged.map((event) => event.state)).toEqual(['staged', 'connecting', 'active']);
    expect(merged[1].detail).toBe('control stream opening');

    const replaced = mergeStageEvent(merged, {
      state: 'streaming',
      at: '2026-07-05T00:03:00.000Z'
    });
    expect(replaced.map((event) => event.state)).toEqual(['staged', 'connecting', 'active']);
    expect(replaced[2].at).toBe('2026-07-05T00:03:00.000Z');
  });
});

describe('mediaStore media control capability', () => {
  it('represents a daemon-to-shell-only media socket as degraded without guessing writable control', () => {
    expect(
      resolveMercuryMediaControl({
        capability: {
          available: true,
          supportsShellToDaemonControl: false,
          detail: 'The shell media socket is daemon-to-shell only.'
        }
      })
    ).toMatchObject({
      state: 'degraded',
      supportsShellToDaemonControl: false
    });
  });

  it('fails closed when the daemon omits the control direction', () => {
    expect(resolveMercuryMediaControl({ available: true })).toMatchObject({
      state: 'degraded',
      supportsShellToDaemonControl: null
    });
  });
});

describe('mediaStore live call state machine', () => {
  beforeEach(resetStores);
  afterEach(resetStores);

  it('loads a live ringing session and accepts it into streaming', async () => {
    const ringing: MercuryMediaSessionState = {
      phase: 'ringing',
      requestId: 'req-1',
      peerName: 'Live iPhone',
      kind: 'call',
      capabilityAvailable: true
    };
    const streaming: MercuryMediaSessionState = {
      ...ringing,
      phase: 'streaming',
      startedAt: '2026-07-06T10:00:00.000Z'
    };
    const mediaAcceptCall = vi.fn().mockResolvedValue(streaming);
    useShellStore.setState({
      bridge: bridgeWithSession({
        mediaSessionState: vi.fn().mockResolvedValue(ringing),
        mediaAcceptCall
      })
    });

    await useMediaStore.getState().load();
    expect(useMediaStore.getState().callState.phase).toBe('ringing');
    await useMediaStore.getState().acceptCall();
    expect(mediaAcceptCall).toHaveBeenCalledWith('req-1');
    expect(useMediaStore.getState().callState.phase).toBe('streaming');
    expect(useMediaStore.getState().stageEvents.some((event) => event.state === 'active')).toBe(true);
  });

  it('keeps authenticated daemon call RPCs available when the media socket is receive-only', async () => {
    const status = {
      capabilityAvailable: true,
      supportsShellToDaemonControl: false,
      pairedDevices: [
        {
          id: 'peer-1',
          name: 'Live iPhone',
          platform: 'ios',
          isOnline: true,
          lastSeenAt: new Date().toISOString(),
          capabilities: ['call.receive']
        }
      ]
    } as unknown as MercuryMediaStatus;
    const ringing: MercuryMediaSessionState = {
      phase: 'ringing',
      requestId: 'req-receive-only',
      peerName: 'Live iPhone',
      kind: 'call',
      capabilityAvailable: true
    };
    const streaming: MercuryMediaSessionState = { ...ringing, phase: 'streaming' };
    const mediaAcceptCall = vi.fn().mockResolvedValue(streaming);
    useShellStore.setState({
      bridge: bridgeWithSession({
        mediaStatus: vi.fn().mockResolvedValue(status),
        mediaSessionState: vi.fn().mockResolvedValue(ringing),
        mediaAcceptCall
      })
    });

    await useMediaStore.getState().load();
    expect(useMediaStore.getState().mediaControlState).toBe('degraded');
    expect(useMediaStore.getState().mediaRpcControlState).toBe('available');
    await useMediaStore.getState().acceptCall();

    expect(mediaAcceptCall).toHaveBeenCalledWith('req-receive-only');
    expect(useMediaStore.getState().callState.phase).toBe('streaming');
  });

  it('declines a ringing fixture call into cooldown', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null });
    await useMediaStore.getState().load();
    expect(useMediaStore.getState().callState.phase).toBe('ringing');
    await useMediaStore.getState().declineCall();
    expect(useMediaStore.getState().callState.phase).toBe('cooldown');
  });

  it('ends a streaming live call into cooldown', async () => {
    const streaming: MercuryMediaSessionState = {
      phase: 'streaming',
      requestId: 'req-2',
      peerName: 'Live iPhone',
      kind: 'call',
      capabilityAvailable: true,
      startedAt: '2026-07-06T10:00:00.000Z'
    };
    const ended: MercuryMediaSessionState = {
      ...streaming,
      phase: 'cooldown',
      endedAt: '2026-07-06T10:05:00.000Z'
    };
    const mediaEndCall = vi.fn().mockResolvedValue(ended);
    useShellStore.setState({
      bridge: bridgeWithSession({
        mediaSessionState: vi.fn().mockResolvedValue(streaming),
        mediaEndCall
      })
    });

    await useMediaStore.getState().load();
    await useMediaStore.getState().endCall();
    expect(mediaEndCall).toHaveBeenCalled();
    expect(useMediaStore.getState().callState.phase).toBe('cooldown');
    expect(useMediaStore.getState().stageEvents.some((event) => event.state === 'ended')).toBe(true);
  });

  it('keeps capability-absent honest when live RPCs are unavailable', async () => {
    useShellStore.setState({
      bridge: bridgeWithSession({
        mediaStatus: vi.fn().mockResolvedValue({ capabilityAvailable: false, pairedDevices: [] })
      })
    });
    await useMediaStore.getState().load();
    expect(useMediaStore.getState().loadState).toBe('capability-absent');
    expect(useMediaStore.getState().callState.phase).toBe('capability-absent');
  });

  it('does not resurrect an in-flight response after reset invalidates the load', async () => {
    const pending = deferred<MercuryMediaStatus>();
    useShellStore.setState({
      bridge: bridgeWithSession({ mediaStatus: vi.fn().mockReturnValue(pending.promise) })
    });
    useMediaStore.setState({
      callState: { phase: 'streaming', kind: 'call', source: 'live' },
      fileTransfers: [fileTransfer()]
    });

    const load = useMediaStore.getState().load();
    expect(useMediaStore.getState()).toMatchObject({
      loadState: 'loading',
      callState: { phase: 'idle' },
      fileTransfers: []
    });

    useMediaStore.getState().reset();
    pending.resolve({ capabilityAvailable: true, pairedDevices: [] } as MercuryMediaStatus);
    await load;

    expect(useMediaStore.getState()).toMatchObject({
      status: null,
      loadState: 'idle',
      callState: { phase: 'idle' },
      fileTransfers: []
    });
  });

  it('keeps the newest bridge load when an older response resolves later', async () => {
    const oldStatus = deferred<MercuryMediaStatus>();
    const oldBridge = bridgeWithSession({ mediaStatus: vi.fn().mockReturnValue(oldStatus.promise) });
    const newBridge = bridgeWithSession({
      mediaStatus: vi.fn().mockResolvedValue({
        capabilityAvailable: true,
        pairedDevices: [{ id: 'new-peer', name: 'New peer', platform: 'linux', isOnline: true }]
      })
    });
    useShellStore.setState({ bridge: oldBridge });
    const oldLoad = useMediaStore.getState().load();
    useShellStore.setState({ bridge: newBridge });
    const newLoad = useMediaStore.getState().load();

    await newLoad;
    oldStatus.resolve({
      capabilityAvailable: true,
      pairedDevices: [{ id: 'old-peer', name: 'Old peer', platform: 'ios', isOnline: true }]
    } as MercuryMediaStatus);
    await oldLoad;

    expect(useMediaStore.getState().status?.pairedDevices[0]?.id).toBe('new-peer');
  });

  it('ingests event-shaped incoming calls without daemon polling', () => {
    useMediaStore.getState().ingestSessionState(
      {
        phase: 'ringing',
        requestId: 'event-1',
        peerName: 'Event Peer',
        kind: 'call',
        capabilityAvailable: true
      },
      'event'
    );
    expect(useMediaStore.getState().callState).toMatchObject({
      phase: 'ringing',
      requestId: 'event-1',
      peerName: 'Event Peer',
      source: 'event'
    });
  });
});

describe('mediaStore file transfer state machine', () => {
  beforeEach(resetStores);
  afterEach(resetStores);

  it('loads an offer, accepts it, and refreshes to completed-with-path', async () => {
    const pending = fileTransfer();
    const downloading = fileTransfer({
      phase: 'downloading',
      progress: { bytesTransferred: 40, bytesTotal: 100, fraction: 0.4 },
      updatedAt: '2026-07-06T10:00:01.000Z'
    });
    const completed = fileTransfer({
      phase: 'completed',
      progress: { bytesTransferred: 100, bytesTotal: 100, fraction: 1 },
      localPath: '/home/alberto/Downloads/report.pdf',
      updatedAt: '2026-07-06T10:00:02.000Z',
      completedAt: '2026-07-06T10:00:02.000Z'
    });
    const mediaFileOfferList = vi
      .fn()
      .mockResolvedValueOnce({ capabilityAvailable: true, downloadDirectory: '/home/alberto/Downloads', transfers: [pending] })
      .mockResolvedValueOnce({ capabilityAvailable: true, downloadDirectory: '/home/alberto/Downloads', transfers: [completed] });
    const mediaFileAccept = vi.fn().mockResolvedValue({ accepted: true, transfer: downloading });
    useShellStore.setState({
      bridge: bridgeWithSession({
        mediaSessionState: vi.fn().mockResolvedValue({ phase: 'idle', kind: 'call', capabilityAvailable: true }),
        mediaFileOfferList,
        mediaFileAccept
      })
    });

    await useMediaStore.getState().load();
    expect(useMediaStore.getState().fileTransfers[0]).toMatchObject({ phase: 'pendingAccept', filename: 'report.pdf' });
    await useMediaStore.getState().acceptFileTransfer('transfer-1');

    expect(mediaFileAccept).toHaveBeenCalledWith({ transferID: 'transfer-1', manifestID: undefined });
    expect(useMediaStore.getState().fileTransfers[0]).toMatchObject({
      phase: 'completed',
      localPath: '/home/alberto/Downloads/report.pdf'
    });
    expect(useMediaStore.getState().fileError).toBeNull();
  });

  it('declines an incoming offer and keeps the declined row visible', async () => {
    const pending = fileTransfer();
    const declined = fileTransfer({
      phase: 'declined',
      updatedAt: '2026-07-06T10:00:03.000Z',
      completedAt: '2026-07-06T10:00:03.000Z'
    });
    const mediaFileOfferList = vi
      .fn()
      .mockResolvedValueOnce({ capabilityAvailable: true, transfers: [pending] })
      .mockResolvedValueOnce({ capabilityAvailable: true, transfers: [declined] });
    const mediaFileDecline = vi.fn().mockResolvedValue({ accepted: true, transfer: declined });
    useShellStore.setState({
      bridge: bridgeWithSession({
        mediaSessionState: vi.fn().mockResolvedValue({ phase: 'idle', kind: 'call', capabilityAvailable: true }),
        mediaFileOfferList,
        mediaFileDecline
      })
    });

    await useMediaStore.getState().load();
    await useMediaStore.getState().declineFileTransfer('transfer-1');

    expect(mediaFileDecline).toHaveBeenCalledWith({
      transferID: 'transfer-1',
      manifestID: undefined,
      reason: 'declined-from-linux-shell'
    });
    expect(useMediaStore.getState().fileTransfers[0].phase).toBe('declined');
  });

  it('scripts a fixture offer through progress to completion', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null });
    await useMediaStore.getState().load();
    expect(useMediaStore.getState().fileTransfers[0].phase).toBe('pendingAccept');

    await useMediaStore.getState().acceptFileTransfer('fixture-file-001');

    const completed = useMediaStore.getState().fileTransfers[0];
    expect(completed.phase).toBe('completed');
    expect(completed.progress.fraction).toBe(1);
    expect(completed.localPath).toContain('mercury-fixture.pdf');
  });

  it('surfaces send failures with daemon error taxonomy', async () => {
    const mediaFileSend = vi.fn().mockResolvedValue({
      accepted: false,
      errorCode: 'localFileMissing',
      detail: 'Local file is unavailable.'
    });
    useShellStore.setState({
      bridge: bridgeWithSession({
        mediaFileOfferList: vi.fn().mockResolvedValue({ capabilityAvailable: true, transfers: [] }),
        mediaFileSend
      })
    });

    await useMediaStore.getState().sendFileTransfer('/tmp/missing.pdf');

    expect(mediaFileSend).toHaveBeenCalledWith({ path: '/tmp/missing.pdf', peerID: undefined });
    expect(useMediaStore.getState().fileError).toBe('Local file is unavailable.');
  });
});
