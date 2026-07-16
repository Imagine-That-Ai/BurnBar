// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { bridgeStubDefaults } from '../../testing/bridgeStubs.js';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureConfigSnapshot } from '../../daemonFixture.js';
import { useIntegrationsStore } from '../../state/integrationsStore.js';
import { useSettingsWiringStore } from '../../state/settingsWiringStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import type { LinuxPrivacyRetentionApplyResult, LinuxPrivacyRetentionStatus, LinuxShellBridge } from '../../tauriBridge.js';
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
    error: null,
    privacyMutation: { status: 'idle', message: null },
    privacyDeletion: { status: 'idle', inventory: null, preview: null, result: null, message: null },
    privacyExport: { status: 'idle', result: null, message: null },
    privacyRetention: { status: 'idle', data: null, result: null, message: null }
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
  it('writes fixture privacy choices and exposes honest lifecycle capability states', async () => {
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    expect(screen.getByText(/fixture transcript/i)).toBeTruthy();
    fireEvent.click(screen.getAllByRole('button', { name: /Data & Privacy/i })[0]!);
    const telemetry = screen.getByRole('checkbox', { name: 'Telemetry' }) as HTMLInputElement;
    expect(telemetry.disabled).toBe(false);
    fireEvent.click(telemetry);
    await waitFor(() => expect(screen.getByText('Privacy choices saved.')).toBeTruthy());
    expect(useSystemStore.getState().config?.telemetryEnabled).toBe(true);
    expect(screen.getAllByText('Unavailable').length).toBeGreaterThanOrEqual(4);
    expect(screen.getByText(/No destructive deletion RPC is exposed/i)).toBeTruthy();
  });

  it('requires the exact account-erasure phrase and exposes a retryable daemon result', async () => {
    const accountDeleteCloudData = vi.fn(async () => ({
      ok: true,
      cloudDataDeleted: true,
      retryRequired: false,
      deletedDocuments: 4,
      destroyedSecrets: 1,
      failedSecretDestroys: 0,
      deletedStoragePrefixes: 2,
      failedStorageDeletes: 0,
      deletedAuthUser: true,
      authUserAlreadyMissing: false
    }));
    useShellStore.setState({ bridge: bridge({ accountDeleteCloudData }), fixtureMode: false });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);

    fireEvent.click(screen.getAllByRole('button', { name: /Data & Privacy/i })[0]!);
    fireEvent.click(screen.getByRole('button', { name: 'Delete cloud account data' }));
    const confirmation = screen.getByRole('textbox', { name: 'Account erasure confirmation' });
    expect((screen.getByRole('button', { name: 'Confirm account erasure' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(confirmation, { target: { value: 'DELETE MY ACCOUNT' } });
    fireEvent.click(screen.getByRole('button', { name: 'Confirm account erasure' }));

    await waitFor(() => expect(accountDeleteCloudData).toHaveBeenCalledWith('DELETE MY ACCOUNT'));
    await waitFor(() => expect(screen.getByText(/Cloud account data was deleted/i)).toBeTruthy());
  });

  it('clears only the daemon-owned local proxy route log after explicit confirmation', async () => {
    let routeRows = [{
      id: 'route-1',
      occurredAt: '2026-07-13T12:00:00.000Z',
      endpoint: '/v1/chat/completions',
      clientModelSlug: 'burnbar-default',
      routingModelSlug: 'provider-model',
      providerName: 'Local provider',
      finalStatus: 'success',
      rewriteKind: 'none',
      exactModelInvariant: 'provider-model',
      streamed: false,
      httpStatus: 200
    }];
    const proxyRouteLogRecent = vi.fn(async () => routeRows);
    const proxyRouteLogClear = vi.fn(async () => {
      routeRows = [];
      return true;
    });
    useShellStore.setState({
      bridge: bridge({ proxyRouteLogRecent, proxyRouteLogClear }),
      fixtureMode: false
    });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getAllByRole('button', { name: /Data & Privacy/i })[0]!);
    await waitFor(() => expect(screen.getByText('1 retained')).toBeTruthy());
    const clearButton = screen.getByRole('button', { name: 'Clear local route log' });
    fireEvent.click(clearButton);
    expect(screen.getByRole('button', { name: 'Confirm clear route log' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Confirm clear route log' }));
    await waitFor(() => expect(proxyRouteLogClear).toHaveBeenCalledOnce());
    await waitFor(() => expect(screen.getByText('0 retained')).toBeTruthy());
    expect(proxyRouteLogRecent).toHaveBeenCalled();
  });

  it('previews and confirms daemon-owned local privacy deletion', async () => {
    const linuxPrivacyInventory = vi.fn(async () => ({
      stores: [
        { store: 'proxy_route_log' as const, state: 'ready' as const, bytes: 24, reason: 'ready' },
        { store: 'text_expansion_store' as const, state: 'absent' as const, bytes: 0, reason: 'missing' }
      ],
      generatedAt: '2026-07-14T00:00:00Z'
    }));
    const linuxPrivacyDeletionPreview = vi.fn(async () => ({
      token: 'preview-token',
      stores: ['proxy_route_log' as const, 'text_expansion_store' as const],
      entries: [
        { store: 'proxy_route_log' as const, state: 'ready' as const, bytes: 24, reason: 'ready' },
        { store: 'text_expansion_store' as const, state: 'absent' as const, bytes: 0, reason: 'missing' }
      ],
      expiresAt: '2026-07-14T00:05:00Z',
      confirmationPhrase: 'DELETE LOCAL DATA'
    }));
    const linuxPrivacyDeletionExecute = vi.fn(async () => ({
      stores: ['proxy_route_log' as const, 'text_expansion_store' as const],
      deleted: ['proxy_route_log' as const],
      alreadyAbsent: ['text_expansion_store' as const],
      bytesRemoved: 24,
      idempotent: false
    }));
    useShellStore.setState({
      bridge: bridge({ linuxPrivacyInventory, linuxPrivacyDeletionPreview, linuxPrivacyDeletionExecute }),
      fixtureMode: false
    });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getAllByRole('button', { name: /Data & Privacy/i })[0]!);
    await waitFor(() => expect(screen.getByText(/Proxy route log \(ready, 24 bytes\)/i)).toBeTruthy());
    fireEvent.click(screen.getByRole('button', { name: 'Preview deletion' }));
    await waitFor(() => expect(screen.getByText(/Preview expires/i)).toBeTruthy());
    const confirmation = screen.getByRole('textbox', { name: 'Privacy deletion confirmation' });
    fireEvent.change(confirmation, { target: { value: 'DELETE LOCAL DATA' } });
    fireEvent.click(screen.getByRole('button', { name: 'Confirm deletion' }));
    await waitFor(() => expect(linuxPrivacyDeletionExecute).toHaveBeenCalledWith({
      token: 'preview-token',
      stores: ['proxy_route_log', 'text_expansion_store'],
      confirmation: 'DELETE LOCAL DATA'
    }));
    expect(await screen.findByText('Selected local stores deleted.')).toBeTruthy();
  });

  it('exports selected local privacy stores through the daemon with an ephemeral passphrase', async () => {
    const linuxPrivacyExport = vi.fn(async () => ({
      stores: ['proxy_route_log' as const],
      destinationPath: '/tmp/privacy-export.obb',
      byteCount: 192,
      formatVersion: 1
    }));
    useShellStore.setState({
      bridge: bridge({ linuxPrivacyExport }),
      fixtureMode: false
    });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getAllByRole('button', { name: /Data & Privacy/i })[0]!);
    const destination = screen.getByRole('textbox', { name: 'Privacy export destination path' });
    const passphrase = screen.getByLabelText('Privacy export passphrase');
    fireEvent.change(destination, { target: { value: '/tmp/privacy-export.obb' } });
    fireEvent.change(passphrase, { target: { value: 'correct horse battery' } });
    fireEvent.click(screen.getByRole('button', { name: 'Export selected data' }));
    await waitFor(() => expect(linuxPrivacyExport).toHaveBeenCalledWith({
      stores: ['proxy_route_log', 'text_expansion_store'],
      destinationPath: '/tmp/privacy-export.obb',
      passphrase: 'correct horse battery'
    }));
    expect(await screen.findByText('Encrypted local privacy export written.')).toBeTruthy();
    expect((passphrase as HTMLInputElement).value).toBe('');
  });

  it('loads and applies bounded daemon-owned retention rules with exact confirmation', async () => {
    const status: LinuxPrivacyRetentionStatus = {
      policyState: 'defaults',
      rules: [
        { store: 'proxy_route_log', maxAgeSeconds: 2_592_000, maxBytes: 8_388_608 },
        { store: 'text_expansion_store', maxAgeSeconds: 31_536_000, maxBytes: 4_194_304 }
      ],
      stores: [
        { store: 'proxy_route_log', state: 'ready', bytes: 24, ageSeconds: 10, maxAgeSeconds: 2_592_000, maxBytes: 8_388_608, wouldPurge: false, reason: 'within_policy' },
        { store: 'text_expansion_store', state: 'absent', bytes: 0, maxAgeSeconds: 31_536_000, maxBytes: 4_194_304, wouldPurge: false, reason: 'missing' }
      ],
      evaluatedAt: '2026-07-14T00:00:00Z'
    };
    const applied: LinuxPrivacyRetentionApplyResult = {
      status: { ...status, policyState: 'configured' },
      removedBytes: 24,
      removedEntries: 1
    };
    const linuxPrivacyRetentionStatus = vi.fn(async () => status);
    const linuxPrivacyRetentionApply = vi.fn(async () => applied);
    useShellStore.setState({
      bridge: bridge({ linuxPrivacyRetentionStatus, linuxPrivacyRetentionApply }),
      fixtureMode: false
    });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getAllByRole('button', { name: /Data & Privacy/i })[0]!);
    await waitFor(() => expect(linuxPrivacyRetentionStatus).toHaveBeenCalled());
    expect(screen.getByText(/24 bytes within limit/i)).toBeTruthy();
    fireEvent.change(screen.getByRole('textbox', { name: 'Retention policy confirmation' }), {
      target: { value: 'APPLY RETENTION POLICY' }
    });
    fireEvent.click(screen.getByRole('button', { name: 'Apply retention policy' }));
    await waitFor(() => expect(linuxPrivacyRetentionApply).toHaveBeenCalledWith({
      rules: [
        { store: 'proxy_route_log', maxAgeSeconds: 2_592_000, maxBytes: 8_388_608 },
        { store: 'text_expansion_store', maxAgeSeconds: 31_536_000, maxBytes: 4_194_304 }
      ],
      confirmation: 'APPLY RETENTION POLICY'
    }));
    expect(await screen.findByText(/Retention policy applied/i)).toBeTruthy();
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

  it('labels parser, API-backed, and unavailable usage sources in the daemon pane', () => {
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Engine Room/i }));
    expect(screen.getByText(/27 local parsers, 4 API-backed sources, 2 unavailable local sources/)).toBeTruthy();
    expect(screen.getAllByText('API-backed; no local parser').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Local usage unavailable').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Local parser registered').length).toBeGreaterThan(0);
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

  it('switches a provider credential slot and explicitly clears back to daemon auto routing', async () => {
    const config = fixtureConfigSnapshot();
    config.providers![0] = {
      ...config.providers![0],
      preferredCredentialSlotID: 'anthropic-team',
      credentialSlots: [
        ...config.providers![0].credentialSlots,
        {
          slotID: 'anthropic-backup',
          label: 'Backup workspace',
          isEnabled: true,
          status: 'ready'
        }
      ]
    };
    const configUpdate = vi.fn(async (snapshot) => snapshot);
    useShellStore.setState({
      bridge: bridge({ configSnapshot: async () => config, configUpdate }),
      fixtureMode: false
    });
    useSystemStore.setState({ config, loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^Agents/i }));

    const preferredSlot = await screen.findByLabelText('Preferred credential slot');
    expect((preferredSlot as HTMLSelectElement).value).toBe('anthropic-team');
    fireEvent.change(preferredSlot, { target: { value: 'anthropic-backup' } });
    await waitFor(() => expect(configUpdate).toHaveBeenCalledTimes(1));
    expect(configUpdate.mock.calls[0]![0].providers?.[0]?.preferredCredentialSlotID).toBe('anthropic-backup');

    fireEvent.click(screen.getByRole('button', { name: 'Use auto routing' }));
    await waitFor(() => expect(configUpdate).toHaveBeenCalledTimes(2));
    expect('preferredCredentialSlotID' in configUpdate.mock.calls[1]![0].providers![0]).toBe(false);
  });

  it('fails closed for preferred account switching without a live config.update bridge', async () => {
    const config = fixtureConfigSnapshot();
    const configUpdate = vi.fn(async (snapshot) => snapshot);
    useShellStore.setState({
      bridge: bridge({ configSnapshot: async () => config, configUpdate: undefined }),
      fixtureMode: false
    });
    useSystemStore.setState({ config, loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^Agents/i }));

    const preferredSlot = await screen.findByLabelText('Preferred credential slot') as HTMLSelectElement;
    expect(preferredSlot.disabled).toBe(true);
    expect(screen.getByText(/config\.update is unavailable/i)).toBeTruthy();
    fireEvent.change(preferredSlot, { target: { value: '' } });
    expect(configUpdate).not.toHaveBeenCalled();
  });

  it('supports fixture account switching without rendering credential material', async () => {
    const config = fixtureConfigSnapshot();
    config.providers![0] = {
      ...config.providers![0],
      preferredCredentialSlotID: 'anthropic-team',
      credentialSlots: [
        ...config.providers![0].credentialSlots,
        {
          slotID: 'anthropic-backup',
          label: 'Backup workspace',
          isEnabled: true,
          status: 'ready'
        }
      ]
    };
    useShellStore.setState({ bridge: null, fixtureMode: true });
    useSystemStore.setState({ config, loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^Agents/i }));

    const preferredSlot = await screen.findByLabelText('Preferred credential slot');
    fireEvent.change(preferredSlot, { target: { value: 'anthropic-backup' } });
    await waitFor(() => expect(useSystemStore.getState().config?.providers?.[0]?.preferredCredentialSlotID).toBe('anthropic-backup'));
    expect(screen.queryByText(/sk-/i)).toBeNull();
  });

  it('fails closed when a packaged bridge cannot update privacy config', async () => {
    useShellStore.setState({ bridge: null, fixtureMode: false });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    await useSettingsWiringStore.getState().updatePrivacySettings({ telemetryEnabled: true });
    expect(useSystemStore.getState().config?.telemetryEnabled).toBe(false);
    expect(useSettingsWiringStore.getState().privacyMutation).toEqual({
      status: 'error',
      message: 'Packaged shell required to save privacy choices.'
    });
  });

  it('sends only the consent change while preserving daemon config fields', async () => {
    const config = fixtureConfigSnapshot();
    const configUpdate = vi.fn(async (snapshot) => ({
      ...snapshot,
      paths: config.paths,
      secretServiceStatus: config.secretServiceStatus
    }));
    useShellStore.setState({ bridge: bridge({ configUpdate }), fixtureMode: false });
    useSystemStore.setState({ config, loading: false, error: null });
    await useSettingsWiringStore.getState().updatePrivacySettings({ privacyOptIn: true });
    expect(configUpdate).toHaveBeenCalledTimes(1);
    const payload = configUpdate.mock.calls[0][0];
    expect(payload.privacyOptIn).toBe(true);
    expect(payload.telemetryEnabled).toBe(config.telemetryEnabled);
    expect(payload.providers).toEqual(config.providers);
    expect(useSystemStore.getState().config?.privacyOptIn).toBe(true);
    expect(useSettingsWiringStore.getState().privacyMutation.status).toBe('success');
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
    expect(screen.getByText(/daemon exposes no Linux mutation contract/i)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /^Media & Sharing/i }));
    expect(screen.getByText(/No daemon settings RPC exists here/i)).toBeTruthy();
  });

  it('surfaces daemon-owned account posture while keeping unsupported device mutations explicit', async () => {
    const accountSignOut = vi.fn(async () => ({
      state: 'signed-out' as const,
      signedIn: false,
      trustClass: 'linux-lower-trust' as const,
      syncState: 'local-only' as const,
      deviceApprovalRequired: false
    }));
    useShellStore.setState({ fixtureMode: true, bridge: bridge({ accountSignOut }) });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^Devices & Sync/i }));
    expect(await screen.findByText(/Account and enrollment posture comes from the daemon/i)).toBeTruthy();
    expect(await screen.findByText(/Signed in as alberto@burnbar.dev/i)).toBeTruthy();
    expect(screen.getByText(/Trusted-device approval and revoke remain unavailable/i)).toBeTruthy();
    const signOut = screen.getByRole('button', { name: 'Sign out' }) as HTMLButtonElement;
    expect(signOut.disabled).toBe(true);
    fireEvent.click(signOut);
    expect(accountSignOut).not.toHaveBeenCalled();
  });

});
