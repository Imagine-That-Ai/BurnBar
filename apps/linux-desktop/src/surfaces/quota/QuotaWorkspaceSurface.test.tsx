// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureProviderCatalog } from '../../daemonFixture.js';
import { useProvidersStore } from '../../state/providersStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { QuotaWorkspaceSurface } from './QuotaWorkspaceSurface.js';

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

describe('QuotaWorkspaceSurface', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('keeps the last quota snapshot visible while a refresh recovers', async () => {
    const retry = vi.fn().mockResolvedValue(undefined);
    const provider = fixtureProviderCatalog()[0]!;
    useShellStore.setState({ fixtureMode: false, bridge: {} as never });
    useProvidersStore.setState({
      catalog: [provider],
      loading: false,
      error: null,
      load: retry
    });

    const { container } = render(<QuotaWorkspaceSurface />);
    await waitFor(() => expect(container.querySelector('.quota-card')).not.toBeNull());
    retry.mockClear();

    act(() => {
      useProvidersStore.setState({ catalog: null, loading: true, error: null });
    });
    expect(container.querySelector('.quota-card')).not.toBeNull();
    expect(container.querySelector('.quota-skeleton')).toBeNull();

    act(() => {
      useProvidersStore.setState({ catalog: null, loading: false, error: 'catalog temporarily unavailable' });
    });

    expect(screen.getByText('Live quota catalog is unavailable. Showing the last available quota snapshot.')).toBeTruthy();
    expect(screen.getByText('catalog temporarily unavailable')).toBeTruthy();
    expect(screen.getByText('Data source: last available daemon provider catalog')).toBeTruthy();
    expect(container.querySelector('.quota-card')).not.toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Retry quota catalog' }));
    expect(retry).toHaveBeenCalledTimes(1);
  });

  it('clears a retained snapshot when the daemon reports an explicit empty catalog', async () => {
    const provider = fixtureProviderCatalog()[0]!;
    useShellStore.setState({ fixtureMode: true });
    useProvidersStore.setState({
      catalog: [provider],
      loading: false,
      error: null,
      load: vi.fn().mockResolvedValue(undefined)
    });

    const { container } = render(<QuotaWorkspaceSurface />);
    await waitFor(() => expect(container.querySelector('.quota-card')).not.toBeNull());

    act(() => {
      useProvidersStore.setState({ catalog: [], loading: false, error: null });
    });

    expect(screen.getByText('No providers linked — connect from the daemon settings.')).toBeTruthy();
    expect(screen.queryByText(/last available quota snapshot/i)).toBeNull();
    expect(container.querySelector('.quota-card')).toBeNull();
  });
});
