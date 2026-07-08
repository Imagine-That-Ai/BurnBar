// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { App } from './App.js';
import { ROUTES } from '../routes.js';
import { fixtureUsageSummary } from '../daemonFixture.js';
import { DaemonDataSection } from '../surfaces/DaemonDataSection.js';
import { useOverviewStore } from '../state/overviewStore.js';
import { useShellStore } from '../state/shellStore.js';

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

  it('exposes exactly one aria-current=page rail item for every route', () => {
    const { container } = render(<App />);
    for (const { id } of ROUTES) {
      act(() => useShellStore.getState().setRoute(id));
      const active = container.querySelectorAll('button.nav-link[aria-current="page"]');
      expect(active).toHaveLength(1);
      expect(location.hash).toBe(`#/${id}`);
    }
  });

  it('switches routes from the side rail', () => {
    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: /Providers & models/i }));
    expect(useShellStore.getState().route).toBe('providers');
    fireEvent.click(screen.getByRole('button', { name: /Activity & logs/i }));
    expect(useShellStore.getState().route).toBe('activity');
  });

  it('navigates to the dashboard when the brand logo is clicked', () => {
    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: /Missions/i }));
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

  it('walks the onboarding wizard with skip and completion persistence', () => {
    const { container } = render(<App />);
    act(() => useShellStore.getState().setRoute('onboarding'));
    expect(screen.getByText('Step 1 of 8')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Skip step' }));
    expect(screen.getByText('Step 2 of 8')).toBeTruthy();
    const stored = JSON.parse(localStorage.getItem('openburnbar.linux.onboarding.v1') ?? '{}');
    expect(stored.skippedSteps).toEqual([0]);
    for (let i = 0; i < 6; i += 1) {
      fireEvent.click(screen.getByRole('button', { name: 'Continue' }));
    }
    fireEvent.click(screen.getByRole('button', { name: 'Finish setup' }));
    expect(container.querySelector('.setup-complete')).not.toBeNull();
    const done = JSON.parse(localStorage.getItem('openburnbar.linux.onboarding.v1') ?? '{}');
    expect(done.completed).toBe(true);
  });

  it('gates text expansion behind consent and supports snippet CRUD', () => {
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
    expect(within(container.querySelector('.snippet-list') as HTMLElement).getByText(';;sig')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Delete' }));
    expect(container.querySelectorAll('.snippet-list li')).toHaveLength(0);
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
});
