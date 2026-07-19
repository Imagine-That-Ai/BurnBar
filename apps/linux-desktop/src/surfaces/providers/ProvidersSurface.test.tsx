// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureProviderCatalog } from '../../daemonFixture.js';
import { useShellStore } from '../../state/shellStore.js';
import { useProvidersStore } from '../../state/providersStore.js';
import { ProvidersSurface } from '../ProvidersSurface.js';

const defaultProvidersLoad = useProvidersStore.getState().load;

function resetStores(): void {
  localStorage.clear();
  useShellStore.setState({
    route: 'providers',
    health: null,
    healthError: null,
    healthBusy: false,
    trayDegraded: false,
    skin: 'editorial',
    bridge: null,
    bridgeReady: true,
    fixtureMode: false
  });
  useProvidersStore.setState({
    catalog: null,
    loading: false,
    error: null,
    load: defaultProvidersLoad
  });
}

describe('ProvidersSurface (quota workspace)', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('renders subscription vault hero and quota cards in fixture mode', async () => {
    useShellStore.setState({ fixtureMode: true });
    const { container } = render(<ProvidersSurface />);
    await waitFor(() => {
      expect(screen.getByText('Data source: fixture transcript')).toBeTruthy();
    });
    expect(screen.getByText(/SUBSCRIPTION VAULT/i)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Refresh all' })).toBeTruthy();
    expect(container.querySelectorAll('.quota-card').length).toBe(10);
    expect(container.querySelector('.quota-reset-atlas')).not.toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Inactive plans' }));
    await waitFor(() => expect(container.querySelectorAll('.quota-card').length).toBe(11));
    expect(container.querySelector('.quota-card[data-provider="google"]')).not.toBeNull();
  });

  it('switches between cards and list view modes', async () => {
    useShellStore.setState({ fixtureMode: true });
    const { container } = render(<ProvidersSurface />);
    await waitFor(() => expect(container.querySelectorAll('.quota-card').length).toBeGreaterThan(0));
    fireEvent.click(screen.getByRole('button', { name: 'List' }));
    await waitFor(() => expect(container.querySelector('.quota-list')).not.toBeNull());
    fireEvent.click(screen.getByRole('button', { name: 'Cards' }));
    await waitFor(() => expect(container.querySelector('.quota-card-grid')).not.toBeNull());
  });

  it('sorts by urgency with highest pressure first', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<ProvidersSurface />);
    await waitFor(() => expect(screen.getAllByRole('heading', { level: 3 }).length).toBeGreaterThan(0));
    const titles = screen.getAllByRole('heading', { level: 3 }).map((h) => h.textContent);
    expect(titles[0]).toMatch(/OpenAI/);
  });

  it('toggles inactive plans strip', async () => {
    useShellStore.setState({ fixtureMode: true });
    const { container } = render(<ProvidersSurface />);
    await waitFor(() => expect(screen.getByRole('button', { name: 'Inactive plans' })).toBeTruthy());
    fireEvent.click(screen.getByRole('button', { name: 'Inactive plans' }));
    await waitFor(() =>
      expect(screen.getByText(/SHOWING UNCONFIGURED PROVIDERS/i)).toBeTruthy()
    );
    expect(container.querySelector('.quota-card[data-provider="google"]')).not.toBeNull();
  });

  it('focuses provider when constellation orb is tapped', async () => {
    useShellStore.setState({ fixtureMode: true });
    const { container } = render(<ProvidersSurface />);
    await waitFor(() => expect(screen.getByText(/SUBSCRIPTION VAULT/i)).toBeTruthy());
    const anthropicOrb = container.querySelector('button.quota-orb[data-provider="anthropic"]');
    expect(anthropicOrb).not.toBeNull();
    fireEvent.click(anthropicOrb!);
    await waitFor(() => expect(screen.getByText(/Focused on/i)).toBeTruthy());
    fireEvent.click(screen.getAllByRole('button', { name: 'Show all providers' })[0]);
    await waitFor(() => expect(screen.queryByText(/Focused on/i)).toBeNull());
  });

  it('opens provider settings from a quota card Manage action', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<ProvidersSurface />);
    await waitFor(() => expect(screen.getAllByRole('button', { name: 'Manage →' }).length).toBeGreaterThan(0));
    fireEvent.click(screen.getAllByRole('button', { name: 'Manage →' })[0]!);
    expect(useShellStore.getState().route).toBe('settings');
  });

  it('shows offline notice without bridge or fixture', async () => {
    const { container } = render(<ProvidersSurface />);
    await waitFor(() => {
      expect(container.querySelector('.offline-notice[role="status"]')).not.toBeNull();
    });
  });

  it('shows empty state when catalog has no providers', () => {
    useShellStore.setState({ fixtureMode: true });
    useProvidersStore.setState({
      catalog: [],
      loading: false,
      error: null,
      load: async () => {}
    });
    render(<ProvidersSurface />);
    expect(
      screen.getByText('No providers linked — connect from the daemon settings.')
    ).toBeTruthy();
  });

  it('shows error banner with retry when load fails with bridge', async () => {
    useShellStore.setState({
      bridge: {
        providerCatalog: async () => {
          throw new Error('catalog unavailable');
        }
      } as never
    });
    render(<ProvidersSurface />);
    await waitFor(() => {
      expect(screen.getByRole('alert')).toBeTruthy();
      expect(screen.getByText('catalog unavailable')).toBeTruthy();
    });
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
  });

  it('shows loading skeleton before first catalog arrives', () => {
    useProvidersStore.setState({
      loading: true,
      catalog: null,
      error: null,
      load: async () => {}
    });
    const { container } = render(<ProvidersSurface />);
    expect(container.querySelector('.quota-skeleton[aria-busy="true"]')).not.toBeNull();
  });

  it('keeps the last provider workspace visible while a catalog refresh recovers', async () => {
    const retry = vi.fn().mockResolvedValue(undefined);
    useShellStore.setState({ fixtureMode: true });
    useProvidersStore.setState({
      catalog: [fixtureProviderCatalog()[0]!],
      loading: false,
      error: null,
      load: retry
    });
    render(<ProvidersSurface />);
    expect(await screen.findByRole('heading', { name: 'Providers & models' })).toBeTruthy();
    retry.mockClear();

    act(() => {
      useProvidersStore.setState({ catalog: null, error: 'catalog temporarily unavailable', loading: false });
    });

    expect(screen.getByText('Live provider catalog is unavailable. Showing the last available catalog.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Retry catalog' }));
    expect(retry).toHaveBeenCalledTimes(1);
  });
});
