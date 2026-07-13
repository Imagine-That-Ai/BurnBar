// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { bridgeStubDefaults } from '../../testing/bridgeStubs.js';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useMediaStore } from '../../state/mediaStore.js';
import { useShellStore } from '../../state/shellStore.js';
import type { LinuxShellBridge, MercuryFileTransfer, MercuryMediaStatus } from '../../tauriBridge.js';
import { MediaSection } from './MediaSection.js';

function resetStores(): void {
  useMediaStore.getState().reset();
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
    callError: null,
    callState: { phase: 'idle', kind: 'call', source: 'live' },
    stageEvents: [],
    fileTransfers: [],
    fileCapabilityAvailable: null,
    fileDownloadDirectory: null,
    fileError: null,
    fileBusyTransferID: null
  });
}

function bridgeWithMedia(result: Promise<MercuryMediaStatus>, overrides: Partial<LinuxShellBridge> = {}): LinuxShellBridge {
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
    mediaStatus: vi.fn().mockReturnValue(result),
    ...overrides
  } as LinuxShellBridge;
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
    peer: { id: 'phone', name: 'Live iPhone', isOnline: true, lastSeenAt: now, capabilities: ['file.send'] },
    progress: { bytesTransferred: 0, bytesTotal: 100, fraction: 0 },
    createdAt: now,
    updatedAt: now,
    ...overrides
  };
}

describe('P12 Mercury media section', () => {
  beforeEach(resetStores);
  afterEach(() => {
    cleanup();
    useMediaStore.getState().reset();
  });

  it('renders the primary capability-absent state when the daemon media runtime is unavailable', async () => {
    useShellStore.setState({
      bridge: bridgeWithMedia(Promise.resolve({ capabilityAvailable: false, pairedDevices: [] }))
    });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });
    expect(screen.getByText('Capability absent')).toBeTruthy();
    expect(screen.getByText('daemon capability')).toBeTruthy();
    expect(screen.getByText(/Mercury capability contract/)).toBeTruthy();
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

  it('renders fixture peers, incoming call controls, and scripted accept transition', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null });
    localStorage.setItem('openburnbar.linux.mediaFixtureRich', '1');
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });
    expect(screen.getAllByText('Alberto MacBook Pro').length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText('fixture transcript')).toBeTruthy();
    expect(screen.getByText('Studio Mac')).toBeTruthy();
    expect(screen.getByText('Phase: Active')).toBeTruthy();
    expect(screen.getByText('Incoming call')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Accept' }));
    expect(screen.getByText('Viewer streaming')).toBeTruthy();
    expect(screen.getByText('Staged')).toBeTruthy();
    expect(screen.getByText('Connecting')).toBeTruthy();
    expect(screen.getByText('Active')).toBeTruthy();
    expect(screen.getByText('Ended')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'End' })).toBeTruthy();
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

  it('renders incoming file offer actions and completed path rows', async () => {
    const completed = fileTransfer({
      phase: 'completed',
      progress: { bytesTransferred: 100, bytesTotal: 100, fraction: 1 },
      localPath: '/home/alberto/Downloads/report.pdf',
      completedAt: '2026-07-06T10:01:00.000Z'
    });
    const mediaFileAccept = vi.fn().mockResolvedValue({
      accepted: true,
      transfer: fileTransfer({ phase: 'downloading', progress: { bytesTransferred: 50, bytesTotal: 100, fraction: 0.5 } })
    });
    const mediaFileOfferList = vi
      .fn()
      .mockResolvedValueOnce({
        capabilityAvailable: true,
        downloadDirectory: '/home/alberto/Downloads',
        transfers: [fileTransfer()]
      })
      .mockResolvedValueOnce({
        capabilityAvailable: true,
        downloadDirectory: '/home/alberto/Downloads',
        transfers: [fileTransfer()]
      })
      .mockResolvedValueOnce({
        capabilityAvailable: true,
        downloadDirectory: '/home/alberto/Downloads',
        transfers: [completed]
      });
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
              capabilities: ['file.send', 'file.receive']
            }
          ]
        }),
        {
          mediaSessionState: vi.fn().mockResolvedValue({ phase: 'idle', kind: 'call', capabilityAvailable: true }),
          mediaFileOfferList,
          mediaFileAccept
        }
      )
    });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });

    expect(screen.getByLabelText('Incoming file offer')).toBeTruthy();
    expect(screen.getByText('report.pdf')).toBeTruthy();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Accept file' }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(mediaFileAccept).toHaveBeenCalledWith({ transferID: 'transfer-1', manifestID: 'manifest-1' });
    expect(screen.getByText('/home/alberto/Downloads/report.pdf')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Send file' })).toBeTruthy();
  });
});
