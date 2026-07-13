// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from '../../app/App.js';
import { clearPerfSamples, recordPerfSample } from '../../perfMarks.js';
import { useMediaStore } from '../../state/mediaStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { useSupportStore } from '../../state/supportStore.js';
import type { LinuxShellBridge } from '../../tauriBridge.js';
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
    exportError: null
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
      updateCheck: 'unavailable-in-shell'
    }),
    updateStatus: vi.fn().mockResolvedValue({
      state: 'current',
      currentVersion: '1.0.0',
      latestVersion: '1.0.0',
      channel: 'stable',
      publishedAt: '2026-07-09T00:00:00Z'
    }),
    exportDiagnostics: vi.fn().mockResolvedValue({ path: '/home/user/diagnostics.json' }),
    sessionEnv: vi.fn(),
    mediaStatus: vi.fn().mockResolvedValue({ capabilityAvailable: false, pairedDevices: [] }),
    ...overrides
  } as LinuxShellBridge;
}

describe('P09 updates and support', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

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
    expect(screen.getByText('/home/user/diagnostics.json')).toBeTruthy();
    expect(bridge.exportDiagnostics).toHaveBeenCalled();
  });

  it('shows export failure with raw error from bridge', async () => {
    const bridge = mockBridge({
      exportDiagnostics: vi.fn().mockRejectedValue(new Error('dialog cancelled by user'))
    });
    useShellStore.setState({ bridge });
    render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().exportDiagnostics();
    });
    expect(screen.getByText('dialog cancelled by user')).toBeTruthy();
  });

  it('fixture export succeeds without bridge', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<SupportSurface />);
    await act(async () => {
      await useSupportStore.getState().exportDiagnostics();
    });
    expect(screen.getByText('/tmp/openburnbar-diagnostics-fixture.json')).toBeTruthy();
  });

  it('keeps fixture toggle, perf table, raw diagnostic, and tray note', async () => {
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
    expect(container.querySelector('.diagnostic-detail')).not.toBeNull();
    const table = container.querySelector('.p09-perf-table tbody');
    expect(table).not.toBeNull();
    expect(within(table as HTMLElement).getByText('overview.route')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Enable daemon fixture (host smoke)' }));
    expect(useShellStore.getState().fixtureMode).toBe(true);
    expect(localStorage.getItem('openburnbar.linux.daemonFixture')).toBe('1');
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
