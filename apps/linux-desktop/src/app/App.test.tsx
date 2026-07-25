// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from './App.js';
import { ROUTES } from '../routes.js';
import { fixtureUsageSummary } from '../daemonFixture.js';
import { DaemonDataSection } from '../surfaces/DaemonDataSection.js';
import { useOverviewStore } from '../state/overviewStore.js';
import { useShellStore } from '../state/shellStore.js';
import type { AccountStatus, LinuxShellBridge, ProviderCatalog } from '../tauriBridge.js';
import { defaultLinuxOnboardingSnapshot } from '../onboardingStore.js';
import { OnboardingSurface } from '../surfaces/OnboardingSurface.js';

function resetShell(): void {
  localStorage.clear();
  // Clear the route without queueing a hashchange event for the next test.
  // jsdom delivers location.hash assignments asynchronously; a stale reset
  // event can otherwise overwrite the route established by the following
  // test and make shortcut assertions order-dependent.
  window.history.replaceState(null, '', `${location.pathname}${location.search}`);
  useOverviewStore.setState({ summary: null, loading: false, error: null, cacheHitRatePct: null, lastRefreshedAt: null });
  useShellStore.setState({
    route: 'overview',
    health: null,
    healthError: null,
    healthBusy: false,
    trayDegraded: false,
    skin: 'editorial',
    bridge: null,
    bridgeReady: true,
    runtimeCapabilities: null,
    capabilityError: null,
    fixtureMode: false
  });
}

function cloudIdentitySnapshot() {
  const base = defaultLinuxOnboardingSnapshot();
  return {
    ...base,
    currentStepID: 'cloud_identity' as const,
    steps: base.steps.map((step) =>
      ['daemon', 'secret_store', 'provider_paths'].includes(step.id)
        ? { ...step, state: 'verified' as const, attemptCount: 1, detail: 'verified' }
        : step
    )
  };
}

function accountStatus(overrides: Partial<AccountStatus> = {}): AccountStatus {
  return {
    state: 'signed-out',
    signedIn: false,
    trustClass: 'linux-lower-trust',
    syncState: 'local-only',
    ...overrides
  };
}

describe('App shell', () => {
  beforeEach(resetShell);
  afterEach(cleanup);

  it('renders the pinned a11y landmark contract', () => {
    const { container } = render(<App />);
    expect(container.querySelector('a.skip-link[href="#main"]')).not.toBeNull();
    expect(container.querySelector('nav[aria-label="Primary"]')).not.toBeNull();
    expect(container.querySelector('main#main')).not.toBeNull();
    expect(container.querySelector('#route-title')).not.toBeNull();
    expect(container.querySelector('.status-pill[role="status"]')).not.toBeNull();
    expect(container.querySelector('.adaptive-backdrop-scrim[aria-hidden="true"]')).not.toBeNull();
    expect(document.documentElement.dataset.backdropForeground).toMatch(/light|dark/);
    expect(document.documentElement.dataset.backdropReadabilitySource).toBe('css-fallback');
    expect(container.querySelector('[aria-hidden="true"][tabindex]')).toBeNull();
  });

  it('exposes exactly one aria-current=page tab for primary sections', () => {
    const { container } = render(<App />);
    const primary = ['chat', 'providers', 'database', 'projects', 'missions', 'activity', 'memory'] as const;
    for (const id of primary) {
      act(() => useShellStore.getState().setRoute(id));
      const active = container.querySelectorAll('button.nav-link[aria-current="page"]');
      expect(active).toHaveLength(1);
      expect(location.hash).toBe(`#/${id}`);
    }
    act(() => useShellStore.getState().setRoute('overview'));
    expect(container.querySelectorAll('button.nav-link[aria-current="page"]')).toHaveLength(0);
  });

  it('switches routes from the top tabbar', () => {
    render(<App />);
    fireEvent.click(screen.getByRole('tab', { name: /Quota/i }));
    expect(useShellStore.getState().route).toBe('providers');
    fireEvent.click(screen.getByRole('tab', { name: /Session Logs/i }));
    expect(useShellStore.getState().route).toBe('activity');
  });

  it('navigates to the dashboard when the brand logo is clicked', () => {
    render(<App />);
    fireEvent.click(screen.getByRole('tab', { name: /Missions/i }));
    expect(useShellStore.getState().route).toBe('missions');
    fireEvent.click(screen.getByRole('button', { name: /Go to dashboard overview/i }));
    expect(useShellStore.getState().route).toBe('overview');
  });

  it('renders BURN telemetry in the toolbar', async () => {
    act(() => {
      useShellStore.setState({ fixtureMode: true, bridgeReady: true });
      useOverviewStore.setState({ summary: fixtureUsageSummary(), loading: false, error: null });
    });
    render(<App />);
    expect(await screen.findByLabelText(/BURN .+ Open range and unit controls/i)).toBeTruthy();
  });

  it('renders every route surface without crashing and titles the route card', () => {
    const { container } = render(<App />);
    for (const route of ROUTES) {
      act(() => useShellStore.getState().setRoute(route.id));
      expect(container.querySelector('#route-title')?.textContent).toBe(route.label);
    }
  });
  it('shows honest offline notice on daemon-backed routes without a bridge', () => {
    const { container } = render(<DaemonDataSection route="database" label="Database" />);
    const notice = container.querySelector('.offline-notice[role="status"]');
    expect(notice).not.toBeNull();
    expect(notice?.textContent).toContain('needs the local daemon');
  });

  it('renders fixture rows with fixture provenance when fixture mode is on', () => {
    useShellStore.setState({
      fixtureMode: true,
      health: {
        ok: true,
        daemonVersion: 'fixture-0.1.0',
        protocolVersion: 1
      }
    });
    const { container } = render(<DaemonDataSection route="database" label="Database" />);
    expect(container.querySelector('.fixture-table')).not.toBeNull();
    expect(screen.getByText('Data source: fixture transcript')).toBeTruthy();
  });

  it('renders live daemon health rows with live provenance', () => {
    useShellStore.setState({
      health: {
        ok: true,
        daemonVersion: '1.2.3',
        protocolVersion: 1,
        socketPath: '/tmp/openburnbar.sock',
        gatewayEnabled: false
      }
    });
    const { container } = render(<DaemonDataSection route="database" label="Database" />);
    expect(screen.getByText('Data source: live daemon health for Database')).toBeTruthy();
    expect(within(container.querySelector('tbody') as HTMLElement).getByText('1.2.3')).toBeTruthy();
  });

  it('renders quota constellation orbs on providers route', async () => {
    useShellStore.setState({ fixtureMode: true });
    const { container } = render(<App />);
    act(() => useShellStore.getState().setRoute('providers'));
    await screen.findByText(/SUBSCRIPTION VAULT/i);
    const orbs = container.querySelectorAll('.quota-orb');
    expect(orbs.length).toBeGreaterThanOrEqual(4);
    expect(container.querySelector('.quota-hero')).not.toBeNull();
  });

  it('toggles skin from deck overflow and persists the choice', () => {
    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));
    fireEvent.click(screen.getByRole('menuitemradio', { name: 'Aurora' }));
    expect(document.documentElement.dataset.skin).toBe('aurora');
    expect(localStorage.getItem('openburnbar.linux.skin.v1')).toBe('aurora');
    expect(screen.getByRole('menuitemradio', { name: 'Aurora' }).getAttribute('aria-checked')).toBe('true');
  });

  it('requires daemon verification and never offers skip for a required onboarding step', async () => {
    const initial = defaultLinuxOnboardingSnapshot();
    const afterDaemon = {
      ...initial,
      revision: 1,
      currentStepID: 'secret_store' as const,
      updatedAt: '2026-07-10T00:00:00Z',
      steps: initial.steps.map((step) =>
        step.id === 'daemon'
          ? { ...step, state: 'verified' as const, attemptCount: 1, detail: 'daemon verified' }
          : step
      )
    };
    const onboardingSnapshot = vi.fn().mockResolvedValue(initial);
    const onboardingAction = vi.fn().mockResolvedValue(afterDaemon);
    useShellStore.setState({
      bridge: {
        onboardingSnapshot,
        onboardingAction,
        onboardingReset: vi.fn()
      } as unknown as LinuxShellBridge,
      bridgeReady: true
    });

    render(<OnboardingSurface />);
    expect(await screen.findByText('Step 1 of 8')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Skip/i })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Verify and continue' }));

    await waitFor(() => {
      expect(onboardingAction).toHaveBeenCalledWith({ stepID: 'daemon', action: 'verify' });
    });
    expect(await screen.findByText('Step 2 of 8')).toBeTruthy();
  });

  it('keeps the last valid onboarding state when an action returns a forged snapshot', async () => {
    const initial = defaultLinuxOnboardingSnapshot();
    const onboardingSnapshot = vi.fn().mockResolvedValue(initial);
    const onboardingAction = vi.fn().mockResolvedValue({ ...initial, completed: true });
    useShellStore.setState({
      bridge: { onboardingSnapshot, onboardingAction, onboardingReset: vi.fn() } as unknown as LinuxShellBridge,
      bridgeReady: true
    });

    render(<OnboardingSurface />);
    expect(await screen.findByText('Step 1 of 8')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Verify and continue' }));

    await waitFor(() => {
      expect(onboardingAction).toHaveBeenCalledWith({ stepID: 'daemon', action: 'verify' });
      expect(screen.getByRole('alert').textContent).toContain('onboarding_completion_invariant_mismatch');
    });
    expect(screen.getByText('Step 1 of 8')).toBeTruthy();
    expect(document.querySelector('.onboarding-wizard')?.getAttribute('aria-busy')).toBe('false');
    expect(localStorage.getItem('openburnbar.linux.onboarding.cache.v2') ?? '').not.toContain('"completed":true');
  });

  it('routes optional integration checks through the daemon and keeps skip explicit', async () => {
    const base = defaultLinuxOnboardingSnapshot();
    const initial = {
      ...base,
      currentStepID: 'cloud_identity' as const,
      steps: base.steps.map((step) =>
        ['daemon', 'secret_store', 'provider_paths'].includes(step.id)
          ? { ...step, state: 'verified' as const, attemptCount: 1, detail: 'verified' }
          : step
      )
    };
    const afterCheck = {
      ...initial,
      revision: 4,
      steps: initial.steps.map((step) =>
        step.id === 'cloud_identity'
          ? {
              ...step,
              state: 'blocked' as const,
              attemptCount: 1,
              detail: 'native cloud sign-in is required',
              repairAction: 'sign_in' as const
            }
          : step
      )
    };
    const onboardingSnapshot = vi.fn().mockResolvedValue(initial);
    const onboardingAction = vi.fn().mockResolvedValue(afterCheck);
    useShellStore.setState({
      bridge: {
        onboardingSnapshot,
        onboardingAction,
        onboardingReset: vi.fn()
      } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });

    render(<OnboardingSurface />);
    expect(await screen.findByRole('heading', { name: 'Cloud identity & sync trust' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Check integration' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Skip for now' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Check integration' }));

    await waitFor(() => {
      expect(onboardingAction).toHaveBeenCalledWith({ stepID: 'cloud_identity', action: 'verify' });
    });
    expect(await screen.findByText(/native cloud sign-in is required/i)).toBeTruthy();
    expect(screen.getByText(/Open the native account flow/i)).toBeTruthy();
  });

  it('starts and cancels native cloud sign-in without changing onboarding state', async () => {
    const initial = cloudIdentitySnapshot();
    const onboardingSnapshot = vi.fn().mockResolvedValue(initial);
    const accountBeginSignIn = vi.fn().mockResolvedValue({
      operationID: 'cloud-op-1',
      expiresAt: '2099-07-10T00:00:00Z'
    });
    const accountCancelSignIn = vi.fn().mockResolvedValue(accountStatus({ detail: 'authorization_cancelled' }));
    const accountStatusRead = vi.fn().mockResolvedValue(accountStatus());
    useShellStore.setState({
      bridge: {
        onboardingSnapshot,
        accountStatus: accountStatusRead,
        accountBeginSignIn,
        accountCancelSignIn,
        onboardingAction: vi.fn()
      } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });

    render(<OnboardingSurface />);
    expect(await screen.findByRole('button', { name: 'Start cloud sign-in' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Start cloud sign-in' }));

    expect(await screen.findByRole('button', { name: 'Cancel sign-in' })).toBeTruthy();
    expect(screen.getByText(/Browser authorization started/i)).toBeTruthy();
    expect(accountBeginSignIn).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole('button', { name: 'Cancel sign-in' }));

    await waitFor(() => expect(accountCancelSignIn).toHaveBeenCalledWith('cloud-op-1'));
    expect(await screen.findByText(/sign-in cancelled/i)).toBeTruthy();
    expect(screen.getByText('Step 4 of 8')).toBeTruthy();
    expect(screen.queryByText('Setup verified')).toBeNull();
  });

  it('shows denied cloud auth as retryable and never marks the step verified', async () => {
    const initial = cloudIdentitySnapshot();
    const accountStatusRead = vi.fn()
      .mockResolvedValueOnce(accountStatus({ state: 'unavailable', detail: 'authorization_denied' }))
      .mockResolvedValueOnce(accountStatus());
    useShellStore.setState({
      bridge: {
        onboardingSnapshot: vi.fn().mockResolvedValue(initial),
        accountStatus: accountStatusRead,
        onboardingAction: vi.fn()
      } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });

    render(<OnboardingSurface />);
    expect(await screen.findByText(/denied or failed/i)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Retry cloud sign-in' }));
    expect(await screen.findByRole('button', { name: 'Start cloud sign-in' })).toBeTruthy();
    expect(screen.getByText(/local-first mode/i)).toBeTruthy();
  });

  it('fails closed on an expired or malformed cloud operation and allows a fresh sign-in', async () => {
    const initial = cloudIdentitySnapshot();
    const accountStatusRead = vi.fn().mockResolvedValue(accountStatus({
      state: 'authorizing',
      signedIn: false,
      authorizationOperationID: 'stale-operation',
      authorizationExpiresAt: 'not-a-timestamp'
    }));
    const accountBeginSignIn = vi.fn().mockResolvedValue({
      operationID: 'fresh-operation',
      expiresAt: '2099-07-10T00:00:00Z'
    });
    useShellStore.setState({
      bridge: {
        onboardingSnapshot: vi.fn().mockResolvedValue(initial),
        accountStatus: accountStatusRead,
        accountBeginSignIn,
        onboardingAction: vi.fn()
      } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });

    render(<OnboardingSurface />);
    expect(await screen.findByText(/expired or invalid cloud sign-in operation/i)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Check sign-in' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Start cloud sign-in' }));
    await waitFor(() => expect(accountBeginSignIn).toHaveBeenCalledTimes(1));
    expect(await screen.findByText(/Browser authorization started/i)).toBeTruthy();
  });

  it('waits for device approval, rechecks daemon state, then requires explicit onboarding verification', async () => {
    const initial = cloudIdentitySnapshot();
    const verified = {
      ...initial,
      currentStepID: 'portal_input' as const,
      revision: 5,
      steps: initial.steps.map((step) => step.id === 'cloud_identity'
        ? { ...step, state: 'verified' as const, attemptCount: 1, detail: 'cloud identity verified' }
        : step)
    };
    const accountStatusRead = vi.fn()
      .mockResolvedValueOnce(accountStatus({
        state: 'awaiting-device-approval',
        authorizationOperationID: 'cloud-op-2',
        authorizationExpiresAt: '2099-07-10T00:00:00Z',
        deviceApprovalRequired: true
      }))
      .mockResolvedValueOnce(accountStatus({ state: 'active', signedIn: true, identityLabel: 'Primary identity' }));
    const onboardingAction = vi.fn().mockResolvedValue(verified);
    useShellStore.setState({
      bridge: {
        onboardingSnapshot: vi.fn().mockResolvedValue(initial),
        accountStatus: accountStatusRead,
        onboardingAction
      } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });

    render(<OnboardingSurface />);
    expect(await screen.findByRole('button', { name: 'Check approval' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Check approval' }));
    expect(await screen.findByRole('button', { name: 'Verify cloud identity' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Verify cloud identity' }));

    await waitFor(() => expect(onboardingAction).toHaveBeenCalledWith({ stepID: 'cloud_identity', action: 'verify' }));
    expect(await screen.findByText('Step 5 of 8')).toBeTruthy();
  });

  it('does not carry an in-flight cloud operation across an onboarding restart', async () => {
    const initial = cloudIdentitySnapshot();
    const accountBeginSignIn = vi.fn().mockResolvedValue({
      operationID: 'cloud-op-restart',
      expiresAt: '2099-07-10T00:00:00Z'
    });
    const bridge: Partial<LinuxShellBridge> = {
      onboardingSnapshot: vi.fn().mockResolvedValue(initial),
      accountStatus: vi.fn().mockResolvedValue(accountStatus()),
      accountBeginSignIn
    };
    useShellStore.setState({ bridge: bridge as LinuxShellBridge, bridgeReady: true, fixtureMode: false });

    const first = render(<OnboardingSurface />);
    fireEvent.click(await screen.findByRole('button', { name: 'Start cloud sign-in' }));
    expect(await screen.findByRole('button', { name: 'Cancel sign-in' })).toBeTruthy();
    first.unmount();

    render(<OnboardingSurface />);
    expect(await screen.findByRole('button', { name: 'Start cloud sign-in' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Cancel sign-in' })).toBeNull();
  });

  it('ignores a cloud sign-in response from a replaced daemon bridge', async () => {
    const initial = cloudIdentitySnapshot();
    let resolveOldOperation: ((operation: { operationID: string; expiresAt: string }) => void) | undefined;
    const oldOperation = new Promise<{ operationID: string; expiresAt: string }>((resolve) => {
      resolveOldOperation = resolve;
    });
    const oldBridge: Partial<LinuxShellBridge> = {
      onboardingSnapshot: vi.fn().mockResolvedValue(initial),
      accountStatus: vi.fn().mockResolvedValue(accountStatus()),
      accountBeginSignIn: vi.fn(() => oldOperation)
    };
    const newBridge: Partial<LinuxShellBridge> = {
      onboardingSnapshot: vi.fn().mockResolvedValue(initial),
      accountStatus: vi.fn().mockResolvedValue(accountStatus()),
      accountBeginSignIn: vi.fn()
    };
    useShellStore.setState({ bridge: oldBridge as LinuxShellBridge, bridgeReady: true, fixtureMode: false });

    render(<OnboardingSurface />);
    fireEvent.click(await screen.findByRole('button', { name: 'Start cloud sign-in' }));
    await waitFor(() => expect(oldBridge.accountBeginSignIn).toHaveBeenCalledOnce());

    act(() => useShellStore.setState({ bridge: newBridge as LinuxShellBridge }));
    await waitFor(() => expect(newBridge.accountStatus).toHaveBeenCalled());
    resolveOldOperation?.({ operationID: 'old-bridge-operation', expiresAt: '2099-07-10T00:00:00Z' });
    await act(async () => { await Promise.resolve(); });
    await waitFor(() => {
      expect((screen.getByRole('button', { name: 'Start cloud sign-in' }) as HTMLButtonElement).disabled).toBe(false);
    });

    expect(screen.queryByRole('button', { name: 'Cancel sign-in' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Start cloud sign-in' })).toBeTruthy();
  });

  it('stores an onboarding provider credential through the daemon without caching the secret', async () => {
    const initial = {
      ...defaultLinuxOnboardingSnapshot(),
      currentStepID: 'provider_paths' as const,
      privacyChoices: { telemetryEnabled: false, cloudSyncEnabled: false },
      steps: defaultLinuxOnboardingSnapshot().steps.map((step) =>
        step.id === 'provider_paths' ? { ...step, state: 'pending' as const } : { ...step, state: 'verified' as const }
      )
    };
    const onboardingSnapshot = vi.fn().mockResolvedValue(initial);
    const providerCatalog = vi.fn()
      .mockResolvedValueOnce([
        { id: 'codex', label: 'Codex', accountLabel: 'No connected account', quotaBuckets: [] }
      ])
      .mockResolvedValueOnce([
        {
          id: 'codex',
          label: 'Codex',
          accountLabel: 'Primary',
          quotaBuckets: [],
          health: 'healthy',
          failover: { mode: 'provider_family_failover', eligible: true, detail: 'verified' }
        }
      ]);
    const providerCredentialSlotUpsert = vi.fn().mockResolvedValue({
      providers: [{
        providerID: 'codex',
        credentialSlots: [{ slotID: 'primary', label: 'Primary', isEnabled: true, status: 'stored' }]
      }]
    });
    useShellStore.setState({
      bridge: { onboardingSnapshot, providerCatalog, providerCredentialSlotUpsert } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });

    render(<OnboardingSurface />);
    expect(await screen.findByRole('heading', { name: 'Connect a provider' })).toBeTruthy();
    fireEvent.change(screen.getByLabelText('API key'), { target: { value: 'sk-test-secret' } });
    fireEvent.click(screen.getByRole('button', { name: 'Store credential securely' }));

    await waitFor(() => expect(providerCredentialSlotUpsert).toHaveBeenCalledWith(expect.objectContaining({
      providerID: 'codex',
      label: 'Primary',
      apiKey: 'sk-test-secret',
      isEnabled: true
    })));
    expect(await screen.findByText(/Credential stored and provider route verified by the daemon/i)).toBeTruthy();
    expect(providerCatalog).toHaveBeenCalledTimes(2);
    expect(localStorage.getItem('openburnbar.linux.onboarding.cache.v2') ?? '').not.toContain('sk-test-secret');
  });

  it('keeps provider auth unverified when route refresh fails, then recovers on retry', async () => {
    const initial = {
      ...defaultLinuxOnboardingSnapshot(),
      currentStepID: 'provider_paths' as const,
      privacyChoices: { telemetryEnabled: false, cloudSyncEnabled: false },
      steps: defaultLinuxOnboardingSnapshot().steps.map((step) =>
        step.id === 'provider_paths' ? { ...step, state: 'pending' as const } : { ...step, state: 'verified' as const }
      )
    };
    const onboardingSnapshot = vi.fn().mockResolvedValue(initial);
    const providerCatalog = vi.fn()
      .mockResolvedValueOnce([
        { id: 'codex', label: 'Codex', accountLabel: 'No connected account', quotaBuckets: [] }
      ])
      .mockRejectedValueOnce(new Error('provider health unavailable'))
      .mockResolvedValueOnce([
        {
          id: 'codex',
          label: 'Codex',
          accountLabel: 'Primary',
          quotaBuckets: [],
          health: 'healthy',
          failover: { mode: 'provider_family_failover', eligible: true, detail: 'verified' }
        }
      ]);
    const providerCredentialSlotUpsert = vi.fn().mockResolvedValue({
      providers: [{
        providerID: 'codex',
        credentialSlots: [{ slotID: 'primary', label: 'Primary', isEnabled: true, status: 'stored' }]
      }]
    });
    useShellStore.setState({
      bridge: { onboardingSnapshot, providerCatalog, providerCredentialSlotUpsert } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });

    render(<OnboardingSurface />);
    expect(await screen.findByRole('heading', { name: 'Connect a provider' })).toBeTruthy();
    fireEvent.change(screen.getByLabelText('API key'), { target: { value: 'sk-test-secret' } });
    fireEvent.click(screen.getByRole('button', { name: 'Store credential securely' }));

    expect(await screen.findByText(/provider route verification is unavailable/i)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Verify provider route' }));
    expect(await screen.findByText(/Provider route verified by the daemon/i)).toBeTruthy();
    expect(providerCatalog).toHaveBeenCalledTimes(3);
  });

  it('does not treat a stale or unrelated credential slot as a successful provider write', async () => {
    const initial = {
      ...defaultLinuxOnboardingSnapshot(),
      currentStepID: 'provider_paths' as const,
      privacyChoices: { telemetryEnabled: false, cloudSyncEnabled: false },
      steps: defaultLinuxOnboardingSnapshot().steps.map((step) =>
        step.id === 'provider_paths' ? { ...step, state: 'pending' as const } : { ...step, state: 'verified' as const }
      )
    };
    const providerCatalog = vi.fn().mockResolvedValue([
      { id: 'codex', label: 'Codex', accountLabel: 'No connected account', quotaBuckets: [] }
    ]);
    const providerCredentialSlotUpsert = vi.fn().mockResolvedValue({
      providers: [{
        providerID: 'codex',
        credentialSlots: [{ slotID: 'old', label: 'Legacy', isEnabled: true, status: 'stored' }]
      }]
    });
    useShellStore.setState({
      bridge: { onboardingSnapshot: vi.fn().mockResolvedValue(initial), providerCatalog, providerCredentialSlotUpsert } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });

    render(<OnboardingSurface />);
    expect(await screen.findByRole('heading', { name: 'Connect a provider' })).toBeTruthy();
    fireEvent.change(screen.getByLabelText('API key'), { target: { value: 'sk-test-secret' } });
    fireEvent.click(screen.getByRole('button', { name: 'Store credential securely' }));

    expect(await screen.findByText(/did not return the requested enabled credential slot/i)).toBeTruthy();
    expect(providerCatalog).toHaveBeenCalledTimes(1);
    expect(localStorage.getItem('openburnbar.linux.onboarding.cache.v2') ?? '').not.toContain('sk-test-secret');
  });

  it('ignores stale provider catalog responses after a newer onboarding retry', async () => {
    const initial = {
      ...defaultLinuxOnboardingSnapshot(),
      currentStepID: 'provider_paths' as const,
      privacyChoices: { telemetryEnabled: false, cloudSyncEnabled: false },
      steps: defaultLinuxOnboardingSnapshot().steps.map((step) =>
        step.id === 'provider_paths' ? { ...step, state: 'pending' as const } : { ...step, state: 'verified' as const }
      )
    };
    let resolveFirst: ((catalog: ProviderCatalog) => void) | undefined;
    let resolveSecond: ((catalog: ProviderCatalog) => void) | undefined;
    const providerCatalog = vi.fn()
      .mockImplementationOnce(() => new Promise((resolve) => { resolveFirst = resolve; }))
      .mockImplementationOnce(() => new Promise((resolve) => { resolveSecond = resolve; }));
    useShellStore.setState({
      bridge: {
        onboardingSnapshot: vi.fn().mockResolvedValue(initial),
        providerCatalog
      } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });

    render(<OnboardingSurface />);
    expect(await screen.findByRole('heading', { name: 'Provider connection' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Retry provider catalog' }));
    await waitFor(() => expect(providerCatalog).toHaveBeenCalledTimes(2));

    resolveSecond?.([{ id: 'codex', label: 'Codex', accountLabel: 'Fresh daemon state', quotaBuckets: [] }]);
    expect(await screen.findByText('Fresh daemon state')).toBeTruthy();
    resolveFirst?.([{ id: 'codex', label: 'Codex', accountLabel: 'Stale daemon state', quotaBuckets: [] }]);
    await act(async () => { await Promise.resolve(); });
    expect(screen.getByText('Fresh daemon state')).toBeTruthy();
    expect(screen.queryByText('Stale daemon state')).toBeNull();
  });

  it('exposes retry and provider-settings recovery when onboarding cannot read the catalog', async () => {
    const initial = {
      ...defaultLinuxOnboardingSnapshot(),
      currentStepID: 'provider_paths' as const,
      privacyChoices: { telemetryEnabled: false, cloudSyncEnabled: false },
      steps: defaultLinuxOnboardingSnapshot().steps.map((step) =>
        step.id === 'provider_paths' ? { ...step, state: 'pending' as const } : { ...step, state: 'verified' as const }
      )
    };
    const providerCatalog = vi.fn()
      .mockRejectedValueOnce(new Error('catalog temporarily unavailable'))
      .mockResolvedValueOnce([
        { id: 'codex', label: 'Codex', accountLabel: 'Recovered daemon state', quotaBuckets: [] }
      ]);
    useShellStore.setState({
      bridge: {
        onboardingSnapshot: vi.fn().mockResolvedValue(initial),
        providerCatalog
      } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });

    render(<OnboardingSurface />);
    const alert = await screen.findByRole('alert');
    expect(alert.textContent ?? '').toMatch(/provider catalog could not be read/i);
    expect(screen.getByRole('button', { name: 'Retry provider catalog' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Open provider settings' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Retry provider catalog' }));
    expect(await screen.findByText('Recovered daemon state')).toBeTruthy();
  });

  it('does not dispatch provider credential mutations from fixture mode', async () => {
    const initial = {
      ...defaultLinuxOnboardingSnapshot(),
      currentStepID: 'provider_paths' as const,
      privacyChoices: { telemetryEnabled: false, cloudSyncEnabled: false },
      steps: defaultLinuxOnboardingSnapshot().steps.map((step) =>
        step.id === 'provider_paths' ? { ...step, state: 'pending' as const } : { ...step, state: 'verified' as const }
      )
    };
    const providerCredentialSlotUpsert = vi.fn();
    useShellStore.setState({
      fixtureMode: true,
      bridge: {
        onboardingSnapshot: vi.fn().mockResolvedValue(initial),
        providerCatalog: vi.fn().mockResolvedValue([{ id: 'codex', label: 'Codex', accountLabel: 'Fixture', quotaBuckets: [] }]),
        providerCredentialSlotUpsert
      } as unknown as LinuxShellBridge,
      bridgeReady: true
    });

    render(<OnboardingSurface />);
    expect(await screen.findByRole('heading', { name: 'Connect a provider' })).toBeTruthy();
    fireEvent.change(screen.getByLabelText('API key'), { target: { value: 'fixture-secret' } });
    fireEvent.click(screen.getByRole('button', { name: 'Store credential securely' }));
    expect(providerCredentialSlotUpsert).not.toHaveBeenCalled();
    expect(await screen.findByText(/unavailable in fixture mode/i)).toBeTruthy();
  });

  it('gates text expansion behind consent and supports snippet CRUD', async () => {
    // CRUD is intentionally exercised in the explicit fixture mode. A
    // non-fixture shell without a daemon must keep the surface fail-closed.
    useShellStore.setState({ fixtureMode: true, bridgeReady: true });
    const { container } = render(<App />);
    act(() => useShellStore.getState().setRoute('text-expansion'));
    expect(screen.getByText('Acknowledge in-app-only expansion before saving snippets.')).toBeTruthy();
    fireEvent.click(container.querySelector('.consent-row input') as HTMLInputElement);
    expect(container.querySelector('.snippet-form')).not.toBeNull();

    fireEvent.change(container.querySelector('input[name="title"]') as HTMLInputElement, {
      target: { value: 'Signature' }
    });
    fireEvent.change(container.querySelector('input[name="trigger"]') as HTMLInputElement, {
      target: { value: ';;sig' }
    });
    fireEvent.change(container.querySelector('textarea[name="body"]') as HTMLTextAreaElement, {
      target: { value: '-- OpenBurnBar' }
    });
    fireEvent.submit(container.querySelector('.snippet-form') as HTMLFormElement);
    await waitFor(() => {
      expect(within(container.querySelector('.snippet-list') as HTMLElement).getByText(';;sig')).toBeTruthy();
    });

    fireEvent.click(screen.getByRole('button', { name: 'Delete' }));
    await waitFor(() => expect(container.querySelectorAll('.snippet-list li')).toHaveLength(0));
  });

  it('keeps failure-state hooks on system routes', () => {
    const { container } = render(<App />);
    act(() => useShellStore.getState().setRoute('settings'));
    expect(container.querySelector('[data-failure-state="secret-store"]')).not.toBeNull();
    act(() => useShellStore.getState().setRoute('account'));
    expect(container.querySelector('[data-failure-state="quota-exhausted"]')).not.toBeNull();
    act(() => useShellStore.getState().setRoute('updates'));
    expect(container.querySelector('[data-failure-state="restart-required"]')).not.toBeNull();
  });

  it('follows external hash navigation', () => {
    render(<App />);
    act(() => {
      location.hash = '#/memory';
      window.dispatchEvent(new HashChangeEvent('hashchange'));
    });
    expect(useShellStore.getState().route).toBe('memory');
  });
  it('fires daemon-wide Computer Use panic from the emergency hotkey', async () => {
    const computerUsePanicHalt = vi.fn().mockResolvedValue({
      sessionId: '*',
      endedAt: new Date(0).toISOString(),
      auditHeadHashHex: '',
      source: 'hotkey'
    });
    useShellStore.setState({
      bridge: { computerUsePanicHalt } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });
    render(<App />);

    fireEvent.keyDown(window, {
      key: '.',
      code: 'Period',
      ctrlKey: true,
      altKey: true,
      metaKey: true
    });

    await waitFor(() => {
      expect(computerUsePanicHalt).toHaveBeenCalledWith({ sessionId: '*', source: 'hotkey' });
    });
  });

  it('keeps dashboard and pet shortcuts usable in the focused window when native grabs are unavailable', async () => {
    useShellStore.setState({ route: 'chat', bridge: null, bridgeReady: true });
    render(<App />);

    fireEvent.keyDown(window, {
      key: 'o',
      code: 'KeyO',
      ctrlKey: true,
      altKey: true,
      metaKey: true
    });
    expect(useShellStore.getState().route).toBe('overview');

    fireEvent.keyDown(window, {
      key: 'p',
      code: 'KeyP',
      ctrlKey: true,
      altKey: true,
      metaKey: true
    });
    await waitFor(() => expect(useShellStore.getState().route).toBe('pet'));
  });

  it('does not double-handle a binding that the native shell registered', async () => {
    const nativeShortcutStatus = vi.fn().mockResolvedValue({
      available: true,
      registered: true,
      backend: 'x11',
      shortcuts: ['Ctrl+Alt+Super+O', 'Ctrl+Alt+Super+P'],
      bindings: [
        { id: 'open-dashboard', shortcut: 'Ctrl+Alt+Super+O', state: 'registered' },
        { id: 'summon-pet', shortcut: 'Ctrl+Alt+Super+P', state: 'registered' }
      ]
    });
    useShellStore.setState({
      route: 'chat',
      bridge: { nativeShortcutStatus } as unknown as LinuxShellBridge,
      bridgeReady: true
    });
    render(<App />);

    await waitFor(() => expect(nativeShortcutStatus).toHaveBeenCalled());
    await act(async () => {
      await nativeShortcutStatus.mock.results[0]?.value;
    });
    fireEvent.keyDown(window, {
      key: 'o',
      code: 'KeyO',
      ctrlKey: true,
      altKey: true,
      metaKey: true
    });
    expect(useShellStore.getState().route).toBe('chat');
  });

  it('falls back for a missing binding even when another native binding is healthy', async () => {
    const nativeShortcutStatus = vi.fn().mockResolvedValue({
      available: true,
      registered: true,
      backend: 'x11',
      shortcuts: ['Ctrl+Alt+Super+O'],
      bindings: [
        { id: 'open-dashboard', shortcut: 'Ctrl+Alt+Super+O', state: 'registered' }
      ]
    });
    useShellStore.setState({
      route: 'chat',
      bridge: { nativeShortcutStatus } as unknown as LinuxShellBridge,
      bridgeReady: true
    });
    render(<App />);

    await waitFor(() => expect(nativeShortcutStatus).toHaveBeenCalled());
    await act(async () => {
      await nativeShortcutStatus.mock.results[0]?.value;
    });
    fireEvent.keyDown(window, {
      key: 'p',
      code: 'KeyP',
      ctrlKey: true,
      altKey: true,
      metaKey: true
    });
    await waitFor(() => expect(useShellStore.getState().route).toBe('pet'));
  });
});
