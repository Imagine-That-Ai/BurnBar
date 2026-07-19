// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from '../../app/App.js';
import { clearPerfSamples, recordPerfSample } from '../../perfMarks.js';
import { useMediaStore } from '../../state/mediaStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { useSupportStore } from '../../state/supportStore.js';
import { isSafeDiagnosticsPath, type LinuxShellBridge } from '../../tauriBridge.js';
import { UpdatesSurface } from '../updates/UpdatesSurface.js';
import { SupportSurface } from './SupportSurface.js';

function resetStores(): void {
  localStorage.clear();
  location.hash = '';
  clearPerfSamples();
  useShellStore.setState({
    route: 'support',
    health: null,
    healthError: 'probe failed: connection refused',
    healthBusy: false,
    trayDegraded: false,
    skin: 'editorial',
    bridge: null,
    bridgeReady: true,
    fixtureMode: false
  });
  useSupportStore.setState({
    versionInfo: null,
    versionLoading: false,
    versionError: null,
    updateStatus: null,
    updateLoading: false,
    updateError: null,
    exportState: 'idle',
    exportPath: null,
    exportPreview: null,
    exportError: null,
    copyState: 'idle',
    copyError: null
  });
  useMediaStore.setState({
    status: null,
    loadState: 'idle',
    error: null,
    stageEvents: []
  });
}

function mockBridge(overrides: Partial<LinuxShellBridge> = {}): LinuxShellBridge {
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
    appVersionInfo: vi.fn().mockResolvedValue({
      shellVersion: '1.0.0',
      daemonVersion: '1.0.0',
      packageChannel: 'deb',
      package: { channel: 'deb', manager: 'dpkg', evidence: 'test' },
      runtime: {
        os: 'linux',
        architecture: 'x86_64',
        kernel: '6.8.0',
        desktop: 'GNOME',
        displayServer: 'wayland'
      },
      updateCheck: 'unavailable-in-shell'
    }),
    updateStatus: vi.fn().mockResolvedValue({
      state: 'current',
      currentVersion: '1.0.0',
      latestVersion: '1.0.0',
      channel: 'stable',
      publishedAt: '2026-07-09T00:00:00Z'
    }),
    exportDiagnostics: vi.fn().mockResolvedValue({
      path: '/home/user/diagnostics-1720512345.json',
      preview: {
        schemaVersion: 1,
        byteCount: 512,
        fileMode: '0600',
        included: ['package channel and runtime facts'],
        excluded: ['provider API keys and credentials']
      }
    }),
    sessionEnv: vi.fn(),
    mediaStatus: vi.fn().mockResolvedValue({ capabilityAvailable: false, pairedDevices: [] }),
    ...overrides
  } as LinuxShellBridge;
}

describe('P09 updates and support', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('accepts native diagnostics paths but rejects traversal and control input', () => {
    expect(isSafeDiagnosticsPath('/tmp/openburnbar-diagnostics-fixture.json')).toBe(true);
    expect(isSafeDiagnosticsPath('/home/user/diagnostics-1720512345.json')).toBe(true);
    expect(isSafeDiagnosticsPath('/tmp/../../secrets.json')).toBe(false);
    expect(isSafeDiagnosticsPath('/tmp/diagnostics-\n.json')).toBe(false);
  });

  it('shows offline notice on updates without bridge or fixture', async () => {
    const { container } = render(<UpdatesSurface />);
    await act(async () => {
      await useSupportStore.getState().loadVersion();
    });
    expect(container.querySelector('.offline-notice[role="status"]')).not.toBeNull();
  });

  it('shows populated updates with package-manager copy and failure rows', async () => {
    useShellStore.setState({ fixtureMode: true });
    const { container } = render(<UpdatesSurface />);
    await act(async () => {
      await useSupportStore.getState().loadVersion();
    });
    expect(screen.getByText(/Updates are delivered by your package manager/)).toBeTruthy();
    expect(container.querySelector('[data-failure-state="channel-unavailable"]')).not.toBeNull();
    expect(container.querySelector('[data-failure-state="restart-required"]')).not.toBeNull();
    expect(screen.getAllByText('0.1.0-fixture').length).toBeGreaterThanOrEqual(1);
    expect(screen.getByText('fixture-only')).toBeTruthy();
  });

  it('shows version-mismatch degraded banner on updates', async () => {
    const bridge = mockBridge({
      appVersionInfo: vi.fn().mockResolvedValue({
        shellVersion: '2.0.0',
        daemonVersion: '1.9.0',
        packageChannel: 'appimage',
        updateCheck: 'unavailable-in-shell'
      })
    });
    useShellStore.setState({ bridge, fixtureMode: false });
    const { container } = render(<UpdatesSurface />);
    await act(async () => {
      await useSupportStore.getState().loadVersion();
    });
    expect(container.querySelector('.banner.degraded[role="alert"]')).not.toBeNull();
    expect(screen.getByText(/Shell and daemon versions differ/)).toBeTruthy();
  });

  it('shows a native-verified update and opens only its validated artifact URL', async () => {
    const openUpdateUrl = vi.fn().mockResolvedValue(undefined);
    const bridge = mockBridge({
      openUpdateUrl,
      updateStatus: vi.fn().mockResolvedValue({
        state: 'available',
        currentVersion: '1.0.0',
        latestVersion: '1.1.0',
        channel: 'stable',
        publishedAt: '2026-07-09T00:00:00Z',
        signatureState: 'verified',
        feedFreshness: 'fresh',
        feedAgeSeconds: 120,
        compatibility: { state: 'aligned', shellVersion: '1.0.0', daemonVersion: '1.0.0' },
        channelInfo: {
          id: 'deb',
          label: 'Debian package (.deb)',
          owner: 'apt/dpkg',
          installMode: 'package-manager-guided',
          automaticInstall: false,
          rollbackMode: 'apt-version-selection',
          explanation: 'The distro package manager owns files and upgrades.'
        },
        notes: 'Security and reliability fixes.',
        artifact: {
          type: 'deb',
          architecture: 'aarch64',
          url: 'https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.1.0/OpenBurnBar_1.1.0_arm64.deb',
          sha256: 'a'.repeat(64),
          size: 100,
          signatureUrl: 'https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.1.0/OpenBurnBar_1.1.0_arm64.deb.sig'
        }
      })
    });
    useShellStore.setState({ bridge, fixtureMode: false });
    render(<UpdatesSurface />);
    await act(async () => {
      await useSupportStore.getState().loadVersion();
    });
    expect(screen.getByRole('heading', { name: /1.1.0 is available/ })).toBeTruthy();
    expect(screen.getByText('Ed25519 verified feed')).toBeTruthy();
    expect(screen.getByText('Security and reliability fixes.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Open signed download' }));
    expect(openUpdateUrl).toHaveBeenCalledWith(
      'https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.1.0/OpenBurnBar_1.1.0_arm64.deb'
    );
    expect(screen.getByText('apt/dpkg')).toBeTruthy();
  });

  it('renders package-native install and rollback actions without executing them', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText } });
    const bridge = mockBridge({
      updateStatus: vi.fn().mockResolvedValue({
        state: 'available',
        currentVersion: '1.0.0',
        latestVersion: '1.1.0',
        channel: 'stable',
        artifact: undefined,
        instructions: {
          packageManager: 'apt',
          install: {
            id: 'install',
            label: 'Update with apt',
            instruction: 'Use apt after reviewing the signed artifact.',
            command: 'sudo apt-get install --only-upgrade open-burn-bar',
            available: true,
            requiresConfirmation: true
          },
          rollback: {
            id: 'rollback',
            label: 'Roll back with apt',
            instruction: 'Choose a previously signed version first.',
            command: 'sudo apt-get install --allow-downgrades open-burn-bar=<previous-version>',
            available: true,
            requiresConfirmation: true
          },
          restart: {
            id: 'restart',
            label: 'Restart OpenBurnBar',
            instruction: 'Quit and relaunch after apt finishes.',
            command: 'systemctl --user restart openburnbar-daemon.service',
            available: true,
            requiresConfirmation: false
          }
        }
      })
    });
    useShellStore.setState({ bridge, fixtureMode: false });
    render(<UpdatesSurface />);
    await act(async () => {
      await useSupportStore.getState().loadVersion();
    });
    expect(screen.getByText('Linux-native apt actions')).toBeTruthy();
    expect(screen.getByText('sudo apt-get install --only-upgrade open-burn-bar')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Copy rollback command' }));
    expect(writeText).toHaveBeenCalledWith('sudo apt-get install --allow-downgrades open-burn-bar=<previous-version>');
    expect(bridge.updateStatus).toHaveBeenCalled();
  });

  it.each([
    ['stale feed', { feedFreshness: 'stale' as const, feedAgeSeconds: 8 * 24 * 60 * 60 }],
    ['daemon mismatch', {
      feedFreshness: 'fresh' as const,
      compatibility: {
        state: 'mismatch' as const,
        shellVersion: '1.1.0',
        daemonVersion: '1.0.0',
        reason: 'Shell 1.1.0 and daemon 1.0.0 differ; restart after the package manager finishes.'
      }
    }]
  ])('keeps install and download actions disabled for %s', async (_label, metadata) => {
    const openUpdateUrl = vi.fn().mockResolvedValue(undefined);
    const bridge = mockBridge({
      openUpdateUrl,
      updateStatus: vi.fn().mockResolvedValue({
        state: 'available',
        currentVersion: '1.0.0',
        latestVersion: '1.1.0',
        channel: 'stable',
        signatureState: 'verified',
        ...metadata,
        artifact: {
          type: 'deb',
          architecture: 'aarch64',
          url: 'https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.1.0/OpenBurnBar_1.1.0_arm64.deb',
          sha256: 'a'.repeat(64),
          size: 100,
          signatureUrl: 'https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.1.0/OpenBurnBar_1.1.0_arm64.deb.sig'
        },
        instructions: {
          packageManager: 'apt',
          install: {
            id: 'install', label: 'Update with apt', instruction: 'Use apt.',
            command: 'sudo apt-get install --only-upgrade open-burn-bar', available: true, requiresConfirmation: true
          },
          rollback: {
            id: 'rollback', label: 'Roll back with apt', instruction: 'Choose a prior version.',
            command: 'sudo apt-get install --allow-downgrades open-burn-bar=PREVIOUS_VERSION', available: true, requiresConfirmation: true
          },
          restart: {
            id: 'restart', label: 'Restart OpenBurnBar', instruction: 'Restart after replacement.',
            command: 'systemctl --user restart openburnbar-daemon.service', available: true, requiresConfirmation: false
          }
        }
      })
    });
    useShellStore.setState({ bridge, fixtureMode: false });
    render(<UpdatesSurface />);
    await act(async () => {
      await useSupportStore.getState().loadVersion();
    });
    expect((screen.getByRole('button', { name: 'Copy install command' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: 'Copy rollback command' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: 'Copy restart command' }) as HTMLButtonElement).disabled).toBe(false);
    expect((screen.getByRole('button', { name: 'Download unavailable' }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByText(/Install and rollback guidance is disabled/)).toBeTruthy();
    expect(openUpdateUrl).not.toHaveBeenCalled();
  });

  it('renders rejected update metadata as an alert with the native reason', async () => {
    const bridge = mockBridge({
      updateStatus: vi.fn().mockResolvedValue({
        state: 'invalid',
        currentVersion: '1.0.0',
        reason: 'Update feed detached Ed25519 signature verification failed.'
      })
    });
    useShellStore.setState({ bridge, fixtureMode: false });
    render(<UpdatesSurface />);
    await act(async () => {
      await useSupportStore.getState().loadVersion();
    });
    expect(screen.getByRole('alert').textContent).toContain('Update metadata rejected');
    expect(screen.getByRole('alert').textContent).toContain('Ed25519 signature verification failed');
    expect(screen.getByText('Signature or schema rejected')).toBeTruthy();
    expect(screen.queryByText('Ed25519 verified feed')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Open signed download' })).toBeNull();
  });

  it('exports diagnostics successfully via bridge', async () => {
    const bridge = mockBridge();
    useShellStore.setState({ bridge });
    render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().loadVersion();
    });
    fireEvent.click(screen.getByRole('button', { name: 'Export redacted diagnostics' }));
    await act(async () => {
      await useSupportStore.getState().exportDiagnostics();
    });
    expect(screen.getByText(/Export written:/)).toBeTruthy();
    expect(screen.getByText('/home/user/diagnostics-1720512345.json')).toBeTruthy();
    expect(screen.getByText('Native export metadata')).toBeTruthy();
    expect(bridge.exportDiagnostics).toHaveBeenCalled();
  });

  it('copies only the validated native export path', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText } });
    const bridge = mockBridge();
    useShellStore.setState({ bridge });
    render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().exportDiagnostics();
      await useSupportStore.getState().copyDiagnosticsPath();
    });
    expect(writeText).toHaveBeenCalledWith('/home/user/diagnostics-1720512345.json');
    expect(screen.getByText('Diagnostics path copied.')).toBeTruthy();
  });

  it('fails closed when a bridge returns a path outside the diagnostics contract', async () => {
    const bridge = mockBridge({
      exportDiagnostics: vi.fn().mockResolvedValue({ path: '/tmp/../../secrets.json' })
    });
    useShellStore.setState({ bridge });
    render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().exportDiagnostics();
    });
    expect(screen.getByText('Native diagnostics export returned an unsafe path.')).toBeTruthy();
  });

  it('fails closed when preview privacy metadata is malformed', async () => {
    const bridge = mockBridge({
      exportDiagnostics: vi.fn().mockResolvedValue({
        path: '/tmp/diagnostics-1720512345.json',
        preview: {
          schemaVersion: 1,
          byteCount: 512,
          fileMode: '0644',
          included: ['shell version'],
          excluded: ['provider API keys and credentials']
        }
      })
    });
    useShellStore.setState({ bridge });
    render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().exportDiagnostics();
    });
    expect(screen.getByText('Native diagnostics export returned unsafe preview metadata.')).toBeTruthy();
  });

  it('redacts export failures instead of echoing native error text', async () => {
    const bridge = mockBridge({
      exportDiagnostics: vi.fn().mockRejectedValue(new Error('dialog cancelled by user; apiKey=sk-live-should-not-render'))
    });
    useShellStore.setState({ bridge });
    render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().exportDiagnostics();
    });
    expect(screen.getByText('Export cancelled. No diagnostics file was written.')).toBeTruthy();
    expect(screen.queryByText(/sk-live-should-not-render/)).toBeNull();
  });

  it('fixture export succeeds without bridge', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().exportDiagnostics();
    });
    expect(screen.getByText('/tmp/openburnbar-diagnostics-fixture.json')).toBeTruthy();
  });

  it('keeps fixture toggle, perf table, structured diagnostic summary, and tray note', async () => {
    recordPerfSample('overview.route', 12.5, 'test');
    recordPerfSample('overview.route', 14.2, 'test');
    useShellStore.setState({
      fixtureMode: false,
      trayDegraded: true,
      health: { ok: false, protocolVersion: 1 },
      healthError: 'connection refused'
    });
    const { container } = render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().loadVersion();
    });
    expect(screen.getByText('Tray degraded: use window reopen from launcher.')).toBeTruthy();
    expect(container.querySelector('.p09-diagnostic-summary')).not.toBeNull();
    expect(container.querySelector('.diagnostic-detail')).toBeNull();
    expect(screen.getByText('Daemon diagnostics summary')).toBeTruthy();
    expect(screen.queryByText('connection refused')).toBeNull();
    const table = container.querySelector('.p09-perf-table tbody');
    expect(table).not.toBeNull();
    expect(within(table as HTMLElement).getByText('overview.route')).toBeTruthy();
    const fixtureToggle = screen.getByRole('button', { name: 'Enable fixture data (host smoke only)' });
    expect(fixtureToggle.getAttribute('aria-pressed')).toBe('false');
    fireEvent.click(fixtureToggle);
    expect(useShellStore.getState().fixtureMode).toBe(true);
    expect(screen.getByRole('button', { name: 'Disable fixture data' }).getAttribute('aria-pressed')).toBe('true');
    expect(localStorage.getItem('openburnbar.linux.daemonFixture')).toBe('1');
  });

  it('shows fixture provenance and disables copying metadata-only output', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText } });
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().exportDiagnostics();
    });
    expect(screen.getByText('Fixture preview')).toBeTruthy();
    expect(screen.getByText('Fixture output is metadata only; no file was written.')).toBeTruthy();
    const copy = screen.getByRole('button', { name: 'Copy diagnostics path unavailable for fixture preview' }) as HTMLButtonElement;
    expect(copy.disabled).toBe(true);
    fireEvent.click(copy);
    expect(writeText).not.toHaveBeenCalled();
  });

  it('exposes an accessible loading state and prevents duplicate exports', () => {
    useShellStore.setState({ bridge: mockBridge(), fixtureMode: false });
    useSupportStore.setState({ exportState: 'exporting' });
    render(<SupportSurface />);
    const exportButton = screen.getByRole('button', { name: 'Exporting…' }) as HTMLButtonElement;
    expect(exportButton.disabled).toBe(true);
    expect(screen.getByText('Export in progress…')).toBeTruthy();
    expect(document.querySelector('.p09-export-status[aria-live="polite"]')).not.toBeNull();
  });

  it('renders a redacted health summary without secret-bearing daemon diagnostics', () => {
    useShellStore.setState({
      bridge: mockBridge(),
      bridgeReady: true,
      health: { ok: false, protocolVersion: 1 },
      healthError: 'permission denied; authToken=sk-live-should-not-render'
    });
    const { container } = render(<SupportSurface />);
    const summary = container.querySelector('.p09-diagnostic-summary');
    expect(summary).not.toBeNull();
    expect(summary?.getAttribute('data-provenance')).toBe('packaged');
    expect(screen.getByText('Daemon unavailable')).toBeTruthy();
    expect(screen.getByText('Protocol')).toBeTruthy();
    expect(screen.queryByText(/sk-live-should-not-render/)).toBeNull();
    expect(container.querySelector('.diagnostic-detail')).toBeNull();
  });

  it('redacts arbitrary native preview labels while preserving privacy metadata facts', async () => {
    const bridge = mockBridge({
      exportDiagnostics: vi.fn().mockResolvedValue({
        path: '/home/user/diagnostics-1720512345.json',
        preview: {
          schemaVersion: 1,
          byteCount: 512,
          fileMode: '0600',
          included: ['apiKey=sk-live-should-not-render'],
          excluded: ['opaque-session-secret=never-render']
        }
      })
    });
    useShellStore.setState({ bridge, fixtureMode: false });
    render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().exportDiagnostics();
    });
    expect(screen.getByText('Diagnostic metadata (redacted)')).toBeTruthy();
    expect(screen.getByText('Sensitive fields (redacted)')).toBeTruthy();
    expect(screen.queryByText(/sk-live-should-not-render|never-render/)).toBeNull();
    expect(screen.getByText('Native export metadata')).toBeTruthy();
  });

  it('describes the packaged export destination without promising an unavailable save dialog', () => {
    useShellStore.setState({ bridge: mockBridge(), fixtureMode: false });
    render(<SupportSurface />);
    expect(screen.getByText(/app support directory/)).toBeTruthy();
    expect(screen.queryByText(/save dialog/i)).toBeNull();
  });

  it('mounts Mercury media below diagnostics without treating staged media as performance proof', async () => {
    recordPerfSample('route.navigation', 8.5, 'packaged-ui-route-after-paint:support');
    const bridge = mockBridge();
    useShellStore.setState({ bridge, fixtureMode: false });
    const { container } = render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().loadVersion();
      await useMediaStore.getState().load();
    });
    const diagnostics = container.querySelector('.p09-diagnostics-card');
    const media = container.querySelector('.p12-media-section');
    const perf = container.querySelector('.p09-perf-table');
    expect(diagnostics).not.toBeNull();
    expect(media).not.toBeNull();
    expect(perf).not.toBeNull();
    expect(diagnostics!.compareDocumentPosition(media!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(media!.compareDocumentPosition(perf!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.getByText('route.navigation')).toBeTruthy();
    expect(screen.queryByText('media.control.stage')).toBeNull();
  });

  it('lists diagnostics manifest items before export', () => {
    render(<SupportSurface />);
    expect(screen.getByText('Provider API tokens and refresh material')).toBeTruthy();
    expect(screen.getByText('Daemon health summary and protocol version')).toBeTruthy();
  });

  it('app shell still wires updates failure-state contract', async () => {
    const { container } = render(<App />);
    act(() => useShellStore.getState().setRoute('updates'));
    await act(async () => {
      await useSupportStore.getState().loadVersion();
    });
    expect(container.querySelector('[data-failure-state="restart-required"]')).not.toBeNull();
  });
});
