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

  it('mounts Mercury media below diagnostics and preserves media.control.stage perf sample', async () => {
    recordPerfSample('media.control.stage', 8.5, 'test');
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
    expect(screen.getByText('media.control.stage')).toBeTruthy();
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
