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
    pickMediaFile: vi.fn().mockResolvedValue(null),
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

  it('keeps daemon call actions visible when the media socket advertises receive-only transport', async () => {
    const mediaAcceptCall = vi.fn().mockResolvedValue({
      phase: 'streaming',
      requestId: 'incoming-receive-only',
      peerName: 'Live iPhone',
      kind: 'call',
      capabilityAvailable: true
    });
    const status = {
      capabilityAvailable: true,
      supportsShellToDaemonControl: false,
      pairedDevices: [
        {
          id: 'live-iphone',
          name: 'Live iPhone',
          platform: 'ios',
          isOnline: true,
          lastSeenAt: new Date().toISOString(),
          capabilities: ['call.receive']
        }
      ]
    } as unknown as MercuryMediaStatus;
    useShellStore.setState({
      bridge: bridgeWithMedia(Promise.resolve(status), {
        mediaSessionState: vi.fn().mockResolvedValue({
          phase: 'ringing',
          requestId: 'incoming-receive-only',
          peerName: 'Live iPhone',
          kind: 'call',
          capabilityAvailable: true
        }),
        mediaAcceptCall
      })
    });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });

    expect(screen.getByText('Media stream receive-only')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Accept' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Decline' })).toBeTruthy();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Accept' }));
      await Promise.resolve();
    });
    expect(mediaAcceptCall).toHaveBeenCalledWith('incoming-receive-only');
  });

  it('disables stale file-offer actions when the daemon withdraws file capability', async () => {
    useShellStore.setState({
      bridge: bridgeWithMedia(Promise.resolve({ capabilityAvailable: true, pairedDevices: [] }), {
        mediaSessionState: vi.fn().mockResolvedValue({ phase: 'idle', kind: 'call', capabilityAvailable: true }),
        mediaFileOfferList: vi.fn().mockResolvedValue({
          capabilityAvailable: false,
          transfers: [fileTransfer()],
          detail: 'File transfer capability was withdrawn.'
        })
      })
    });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });

    expect((screen.getByRole('button', { name: 'Accept file' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: 'Decline file' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: 'Send file' }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('hides dead call controls when the shell viewer lacks a decoder while preserving file transfer', async () => {
    const status: MercuryMediaStatus = {
      capabilityAvailable: true,
      pairedDevices: [],
      viewerCapability: {
        available: false,
        renderer: 'media-gst',
        featureEnabled: true,
        canDecodeVp9: false,
        hasVideoSink: true,
        status: 'gstreamer_vp9_decoder_missing',
        reason: 'gstreamer_vp9_decoder_missing',
        installHint: 'Install a VP9 decoder plugin, then restart OpenBurnBar.'
      }
    };
    const mediaStatus = vi.fn().mockResolvedValue(status);
    useShellStore.setState({
      bridge: bridgeWithMedia(
        Promise.resolve(status),
        {
          mediaStatus,
          mediaSessionState: vi.fn().mockResolvedValue({
            phase: 'ringing',
            requestId: 'incoming-1',
            peerName: 'Live iPhone',
            kind: 'call',
            capabilityAvailable: true
          }),
          mediaFileOfferList: vi.fn().mockResolvedValue({
            capabilityAvailable: true,
            downloadDirectory: '/home/alberto/Downloads',
            transfers: []
          })
        }
      )
    });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });
    expect(screen.getByText('Calls and screen sharing are paused on this Linux session')).toBeTruthy();
    expect(screen.getByText('The GStreamer runtime is present, but its VP9 decoder is missing.')).toBeTruthy();
    expect(screen.getByText('Install a VP9 decoder plugin, then restart OpenBurnBar.')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Accept' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Decline' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'End' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Send file' })).toBeTruthy();

    const callsBeforeRetry = mediaStatus.mock.calls.length;
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Check again' }));
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(mediaStatus.mock.calls.length).toBeGreaterThan(callsBeforeRetry);
    expect(screen.getByRole('button', { name: 'Check again' })).toBeTruthy();
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

  it('chooses an outgoing file through the native picker before sending', async () => {
    const pickMediaFile = vi.fn().mockResolvedValue('/home/alberto/Downloads/report.pdf');
    const mediaFileSend = vi.fn().mockResolvedValue({ accepted: false, detail: 'queued' });
    useShellStore.setState({
      bridge: bridgeWithMedia(
        Promise.resolve({ capabilityAvailable: true, pairedDevices: [] }),
        {
          mediaFileOfferList: vi.fn().mockResolvedValue({ capabilityAvailable: true, transfers: [] }),
          pickMediaFile,
          mediaFileSend
        }
      )
    });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });

    expect(screen.queryByLabelText('File path')).toBeNull();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Choose file' }));
      await Promise.resolve();
    });
    expect(pickMediaFile).toHaveBeenCalledTimes(1);
    expect(screen.getByText('/home/alberto/Downloads/report.pdf')).toBeTruthy();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Send file' }));
      await Promise.resolve();
    });
    expect(mediaFileSend).toHaveBeenCalledWith({
      path: '/home/alberto/Downloads/report.pdf',
      peerID: undefined
    });
  });

  it('fails closed when an older shell has no native media picker', async () => {
    useShellStore.setState({
      bridge: bridgeWithMedia(Promise.resolve({ capabilityAvailable: true, pairedDevices: [] }), {
        mediaFileOfferList: vi.fn().mockResolvedValue({ capabilityAvailable: true, transfers: [] }),
        pickMediaFile: undefined
      })
    });
    render(<MediaSection />);
    await act(async () => {
      await useMediaStore.getState().load();
    });

    expect(screen.queryByLabelText('File path')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Choose file' })).toBeNull();
    expect(screen.getByText(/Native file picker is unavailable/)).toBeTruthy();
  });
});
