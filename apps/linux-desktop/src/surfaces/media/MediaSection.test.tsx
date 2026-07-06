// @vitest-environment jsdom
import { act, cleanup, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useMediaStore } from '../../state/mediaStore.js';
import { useShellStore } from '../../state/shellStore.js';
import type { LinuxShellBridge, MercuryMediaStatus } from '../../tauriBridge.js';
import { MediaSection } from './MediaSection.js';

function resetStores(): void {
  useShellStore.setState({
    fixtureMode: false,
    bridge: null,
    bridgeReady: true,
    health: null,
    healthError: 'connection refused',
    healthBusy: false
  });
  useMediaStore.setState({
    status: null,
    loadState: 'idle',
    error: null,
    stageEvents: []
  });
}

function bridgeWithMedia(result: Promise<MercuryMediaStatus>): LinuxShellBridge {
  return {
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
    mediaStatus: vi.fn().mockReturnValue(result)
  } as LinuxShellBridge;
}

describe('P12 Mercury media section', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('renders the primary capability-absent state for current Linux daemons', async () => {
    useShellStore.setState({
      bridge: bridgeWithMedia(Promise.resolve({ capabilityAvailable: false, pairedDevices: [] }))
    });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });
    expect(screen.getByText('Capability absent')).toBeTruthy();
    expect(screen.getByText('daemon capability')).toBeTruthy();
    expect(screen.getByText(/daemon.media.status/)).toBeTruthy();
  });

  it('renders loading while the daemon request is unresolved', () => {
    useShellStore.setState({
      bridge: bridgeWithMedia(new Promise(() => {}))
    });
    render(<MediaSection />);
    expect(screen.getByText('Loading Mercury media status…')).toBeTruthy();
  });

  it('renders offline when no packaged bridge is available', async () => {
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });
    expect(screen.getByText(/Connect the packaged shell/)).toBeTruthy();
  });

  it('renders empty paired-device state', async () => {
    useShellStore.setState({
      bridge: bridgeWithMedia(Promise.resolve({ capabilityAvailable: true, pairedDevices: [] }))
    });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });
    expect(screen.getByText('No paired devices — pair from the mobile app.')).toBeTruthy();
  });

  it('renders error state for transport failures', async () => {
    useShellStore.setState({
      bridge: bridgeWithMedia(Promise.reject(new Error('socket closed')))
    });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });
    expect(screen.getByText('socket closed')).toBeTruthy();
  });

  it('renders fixture peers and session timeline without action controls', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });
    expect(screen.getAllByText('Alberto MacBook Pro').length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText('fixture transcript')).toBeTruthy();
    expect(screen.getByText('Studio Mac')).toBeTruthy();
    expect(screen.getByText('Phase: Active')).toBeTruthy();
    expect(screen.getByText('Staged')).toBeTruthy();
    expect(screen.getByText('Connecting')).toBeTruthy();
    expect(screen.getByText('Active')).toBeTruthy();
    expect(screen.getByText('Ended')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /call|send file|end|forget/i })).toBeNull();
  });

  it('renders live daemon peers with provenance when media_status is available', async () => {
    useShellStore.setState({
      bridge: bridgeWithMedia(
        Promise.resolve({
          capabilityAvailable: true,
          pairedDevices: [
            {
              id: 'live-iphone',
              name: 'Live iPhone',
              platform: 'ios',
              isOnline: true,
              lastSeenAt: new Date().toISOString(),
              capabilities: ['mirror.viewer']
            }
          ],
          activeSession: {
            kind: 'file',
            state: 'connecting',
            peer: 'Live iPhone'
          }
        })
      )
    });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });
    expect(screen.getByText('live daemon')).toBeTruthy();
    expect(screen.getAllByText('Live iPhone').length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText('Phase: Connecting')).toBeTruthy();
  });
});
