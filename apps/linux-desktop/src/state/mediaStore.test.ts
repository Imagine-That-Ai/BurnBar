import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { bridgeStubDefaults } from '../testing/bridgeStubs.js';
import type { LinuxShellBridge, MercuryMediaSessionState } from '../tauriBridge.js';
import {
  mergeStageEvent,
  normalizeCallPhase,
  normalizeMercuryStage,
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
