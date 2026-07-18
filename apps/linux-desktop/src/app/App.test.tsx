// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from './App.js';
import { ROUTES } from '../routes.js';
import { fixtureUsageSummary } from '../daemonFixture.js';
import { DaemonDataSection } from '../surfaces/DaemonDataSection.js';
import { useOverviewStore } from '../state/overviewStore.js';
import { useShellStore } from '../state/shellStore.js';
import type { LinuxShellBridge } from '../tauriBridge.js';
import { defaultLinuxOnboardingSnapshot } from '../onboardingStore.js';
import { OnboardingSurface } from '../surfaces/OnboardingSurface.js';

function resetShell(): void {
  localStorage.clear();
  location.hash = '';
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
    const providerCatalog = vi.fn().mockResolvedValue([
      { id: 'codex', label: 'Codex', accountLabel: 'No connected account', quotaBuckets: [] }
    ]);
    const providerCredentialSlotUpsert = vi.fn().mockResolvedValue({
      providers: [{ providerID: 'codex', credentialSlots: [{ slotID: 'primary' }] }]
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
    expect(await screen.findByText(/Credential stored by the daemon/i)).toBeTruthy();
    expect(localStorage.getItem('openburnbar.linux.onboarding.cache.v2') ?? '').not.toContain('sk-test-secret');
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
    fireEvent.keyDown(window, {
      key: 'o',
      code: 'KeyO',
      ctrlKey: true,
      altKey: true,
      metaKey: true
    });
    expect(useShellStore.getState().route).toBe('chat');
  });
});
