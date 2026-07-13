// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { bridgeStubDefaults } from '../../testing/bridgeStubs.js';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureConfigSnapshot } from '../../daemonFixture.js';
import { useIntegrationsStore } from '../../state/integrationsStore.js';
import { useSettingsWiringStore } from '../../state/settingsWiringStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import type { LinuxShellBridge } from '../../tauriBridge.js';
import { SettingsSurface } from './SettingsSurface.js';

function resetStores(): void {
  localStorage.clear();
  useShellStore.setState({
    bridge: null,
    fixtureMode: false,
    health: null,
    healthError: null,
    healthBusy: false,
    route: 'settings'
  });
  useSystemStore.setState({
    config: null,
    db: null,
    projects: null,
    memory: null,
    loading: false,
    error: null
  });
  useIntegrationsStore.setState({
    status: null,
    loading: false,
    error: null
  });
  useSettingsWiringStore.setState({
    routeLog: [],
    notificationConfig: null,
    notificationHealth: null,
    notificationCommandResult: null,
    loadingRouteLog: false,
    loadingNotifications: false,
    busy: null,
    error: null
  });
}

function bridge(overrides: Partial<LinuxShellBridge> = {}): LinuxShellBridge {
  const config = fixtureConfigSnapshot();
  return {
    ...bridgeStubDefaults,
    daemonHealth: async () => ({
      ok: true,
      protocolVersion: 1,
      daemonVersion: 'test-daemon',
      socketPath: config.paths.socketPath,
      gatewayEnabled: true,
      gatewayHost: '127.0.0.1',
      gatewayPort: 8317
    }),
    openDashboard: async () => {},
    quitApp: async () => {},
    trayDegraded: async () => false,
    measurePerfOperation: async (name) => ({ name, ms: 1, source: 'test', ok: true }),
    usageSummary: async () => ({ todayTokens: 0, todayCostUsd: 0, sevenDay: [], recentEvents: [] }),
    providerCatalog: async () => [],
    sessionList: async () => ({ sessions: [], nextCursor: null }),
    sessionSearch: async () => ({ sessions: [], nextCursor: null }),
    usageInsights: async () => ({ weekly: [], providerMix: [], modelMix: [], cacheHitRatePct: 0 }),
    missionList: async () => ({ missions: [], pendingApprovals: [] }),
    missionApprovalDecision: async () => {},
    configSnapshot: async () => config,
    dbStatus: async () => ({ sqlcipherOk: true, migrationVersion: 1, sizeBytes: 1, walMode: true }),
    projectList: async () => [],
    memoryBoundaries: async () => [],
    accountStatus: async () => ({ signedIn: false, trustClass: 'linux-lower-trust', syncState: 'local-only' }),
    appVersionInfo: async () => ({ shellVersion: 'test', daemonVersion: 'test', packageChannel: 'deb', updateCheck: 'test' }),
    exportDiagnostics: async () => ({ path: '/tmp/openburnbar-test.json' }),
    configUpdate: async (snapshot) => snapshot,
    providerCredentialSlotUpsert: async () => config,
    providerCredentialSlotRemove: async () => config,
    providerModelVariantUpsert: async () => config,
    providerModelVariantRemove: async () => config,
    providerModelAliasUpsert: async () => config,
    providerModelAliasRemove: async () => config,
    providerCustomModelUpsert: async () => config,
    providerCustomModelRemove: async () => config,
    providerModelDisplayNameSet: async () => config,
    providerModelDisplayNameClear: async () => config,
    proxyRouteLogRecent: async () => [],
    proxyRouteLogClear: async () => true,
    notificationConfigGet: async () => ({
      defaultSnoozeMinutes: 30,
      nudgeHoursLocal: [9],
      local: { isEnabled: true, quietHoursStart: null, quietHoursEnd: null },
      telegram: { isEnabled: false, botTokenConfigured: false, botToken: null, botTokenHint: null, chatID: null, supportedCommands: ['status'] },
      calendar: { isEnabled: false, defaultDurationMinutes: 30, defaultCalendarName: null }
    }),
    notificationConfigUpdate: async (config) => config,
    notificationHealth: async () => ({
      checkedAt: new Date().toISOString(),
      channels: [{ channel: 'local', status: 'healthy', detail: null, checkedAt: new Date().toISOString() }]
    }),
    notificationCommand: async (command) => ({ command, ok: true, message: `${command} ok` }),
    sessionEnv: async () => ({}),
    ...overrides,
    accountBeginSignIn: overrides.accountBeginSignIn ?? bridgeStubDefaults.accountBeginSignIn,
    accountCancelSignIn: overrides.accountCancelSignIn ?? bridgeStubDefaults.accountCancelSignIn,
    accountRotateIdentity: overrides.accountRotateIdentity ?? bridgeStubDefaults.accountRotateIdentity,
    accountSignOut: overrides.accountSignOut ?? bridgeStubDefaults.accountSignOut,
    onboardingSnapshot: overrides.onboardingSnapshot ?? bridgeStubDefaults.onboardingSnapshot,
    onboardingAction: overrides.onboardingAction ?? bridgeStubDefaults.onboardingAction,
    onboardingReset: overrides.onboardingReset ?? bridgeStubDefaults.onboardingReset
  };
}

describe('SettingsSurface', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('keeps evidence-pinned failure-state ids from SystemStatusSection', () => {
    const { container } = render(<SettingsSurface />);
    expect(container.querySelector('[data-failure-state="secret-store"]')).not.toBeNull();
    expect(container.querySelector('[data-failure-state="permission-denied"]')).not.toBeNull();
  });

  it('does not assertively announce each healthy subscription cadence update', () => {
    useShellStore.setState({
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8317 },
      subscriptionState: 'pull',
      lastDaemonEventAt: '2026-07-10T12:00:00.000Z'
    });
    const { container } = render(<SettingsSurface />);
    expect(container.querySelector('.banner.ok')?.getAttribute('role')).toBeNull();
  });

  it('renders home landing with hero and sidebar sections', () => {
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    expect(screen.getByText('OpenBurnBar Settings')).toBeTruthy();
    expect(screen.getByText('Agents & Models')).toBeTruthy();
    expect(screen.getByText('Look & Feel')).toBeTruthy();
    expect(screen.getByText('Account & Sync')).toBeTruthy();
  });

  it('exposes model proxy, Computer Use, and Pets as searchable settings destinations', () => {
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);

    fireEvent.click(screen.getByRole('button', { name: /Model Proxy/i }));
    expect(screen.getByRole('heading', { name: 'Model Proxy' })).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: /^Computer Use$/i }));
    expect(screen.getAllByRole('heading', { name: 'Computer Use' }).length).toBeGreaterThanOrEqual(1);
    expect(screen.getByText(/Approval-gated automation/i)).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: /^Pets$/i }));
    expect(screen.getByRole('heading', { name: 'Pets' })).toBeTruthy();
  });
  it('renders populated fixture config with read-only toggles on Data & Privacy', () => {
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    expect(screen.getByText(/fixture transcript/i)).toBeTruthy();
    fireEvent.click(screen.getAllByRole('button', { name: /Data & Privacy/i })[0]!);
    const toggles = screen.getAllByRole('checkbox');
    for (const input of toggles) {
      expect(input.getAttribute('aria-disabled')).toBe('true');
      expect((input as HTMLInputElement).disabled).toBe(true);
    }
  });

  it('shows loading skeleton without fixture', () => {
    vi.spyOn(useSystemStore.getState(), 'loadConfig').mockImplementation(async () => {});
    useSystemStore.setState({ loading: true, config: null, error: null });
    const { container } = render(<SettingsSurface />);
    expect(container.querySelector('.settings-split--loading')).toBeTruthy();
  });

  it('shows offline notice on daemon detail without bridge', () => {
    vi.spyOn(useSystemStore.getState(), 'loadConfig').mockImplementation(async () => {});
    useShellStore.setState({ bridge: null, fixtureMode: false });
    useSystemStore.setState({ config: null, loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Engine Room/i }));
    expect(screen.getByText(/Settings need the local daemon/i)).toBeTruthy();
  });

  it('shows error with retry on detail pane', () => {
    const spy = vi.spyOn(useSystemStore.getState(), 'loadConfig').mockImplementation(async () => {});
    useShellStore.setState({ bridge: {} as never, fixtureMode: false });
    useSystemStore.setState({ config: null, loading: false, error: 'Config RPC failed' });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Engine Room/i }));
    expect(screen.getByText('Config RPC failed')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    expect(spy).toHaveBeenCalled();
  });

  it('announces Copied after copy path on daemon pane', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.assign(navigator, { clipboard: { writeText } });
    vi.spyOn(useSystemStore.getState(), 'loadConfig').mockImplementation(async () => {});
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Engine Room/i }));
    const copyBtn = screen.getAllByRole('button', { name: /^Copy path$/i })[0]!;
    fireEvent.click(copyBtn);
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(fixtureConfigSnapshot().paths.supportDir));
    await waitFor(() => expect(screen.getByText('Copied')).toBeTruthy());
  });

  it('Done returns to overview route', () => {
    useShellStore.setState({ fixtureMode: true, route: 'settings' });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: 'Done' }));
    expect(useShellStore.getState().route).toBe('overview');
  });

  it('General pane exposes appearance controls and daemon-owned onboarding wizard', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: bridge(), bridgeReady: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^General/i }));
    expect(screen.getByRole('radiogroup', { name: 'Color scheme' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Refresh' })).toBeTruthy();
    expect(await screen.findByText(/Step 1 of/i)).toBeTruthy();
  });

  it('sidebar search filters sections', () => {
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.change(screen.getByLabelText('Search settings'), { target: { value: 'text expansion' } });
    expect(screen.queryByRole('button', { name: /^General$/i })).toBeNull();
    expect(screen.getAllByRole('button', { name: /Text Expansion/i }).length).toBeGreaterThanOrEqual(1);
  });


  it('wires Agents provider config writes through daemon config.update', async () => {
    const configUpdate = vi.fn(async (snapshot) => snapshot);
    useShellStore.setState({
      bridge: bridge({ configUpdate }),
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8317 }
    });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^Agents/i }));
    expect(screen.getByText('127.0.0.1:8317')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Disable' }));
    await waitFor(() => expect(configUpdate).toHaveBeenCalled());
    expect(configUpdate.mock.calls[0][0].providers[0].isEnabled).toBe(false);
  });

  it('wires Agents credential and model mutation RPCs without rendering secrets', async () => {
    const providerCredentialSlotUpsert = vi.fn(async () => fixtureConfigSnapshot());
    const providerCustomModelUpsert = vi.fn(async () => fixtureConfigSnapshot());
    useShellStore.setState({ bridge: bridge({ providerCredentialSlotUpsert, providerCustomModelUpsert }) });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^Agents/i }));
    fireEvent.change(screen.getByLabelText('Credential slot label'), { target: { value: 'Linux route key' } });
    fireEvent.change(screen.getByLabelText('Credential API key'), { target: { value: 'sk-super-secret' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add slot' }));
    await waitFor(() => expect(providerCredentialSlotUpsert).toHaveBeenCalledWith(expect.objectContaining({ apiKey: 'sk-super-secret' })));
    expect(screen.queryByText('sk-super-secret')).toBeNull();

    fireEvent.change(screen.getByLabelText('Custom model ID'), { target: { value: 'linux-test-model' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add model' }));
    await waitFor(() => expect(providerCustomModelUpsert).toHaveBeenCalled());
  });

  it('wires notification config update and command RPCs', async () => {
    const notificationConfigUpdate = vi.fn(async (config) => config);
    const notificationCommand = vi.fn(async (command) => ({ command, ok: true, message: 'status ok' }));
    useShellStore.setState({ bridge: bridge({ notificationConfigUpdate, notificationCommand }) });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^Notifications/i }));
    await screen.findByLabelText('Default snooze minutes');
    fireEvent.change(screen.getByLabelText('Default snooze minutes'), { target: { value: '45' } });
    await waitFor(() => expect(notificationConfigUpdate).toHaveBeenCalledWith(expect.objectContaining({ defaultSnoozeMinutes: 45 })));
    fireEvent.click(screen.getByRole('button', { name: 'status' }));
    await waitFor(() => expect(notificationCommand).toHaveBeenCalledWith('status', []));
  });

  it('keeps Devices & Sync and Media honest when no mutation RPC exists', () => {
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^Devices & Sync/i }));
    expect(screen.getByText(/No trusted-device mutation RPC is available/i)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /^Media & Sharing/i }));
    expect(screen.getByText(/No daemon settings RPC exists here/i)).toBeTruthy();
  });
});
