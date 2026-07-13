import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureProviderCatalog } from '../daemonFixture.js';
import type { ConfigSnapshot } from '../tauriBridge.js';
import { useProvidersStore } from './providersStore.js';
import { useShellStore } from './shellStore.js';

function resetStores(): void {
  useShellStore.setState({ bridge: null, fixtureMode: false });
  useProvidersStore.setState({
    catalog: null,
    loading: false,
    error: null,
    mutationBusy: null,
    mutationError: null
  });
}

describe('providersStore custom model lifecycle', () => {
  beforeEach(resetStores);
  afterEach(resetStores);

  it('adds and removes a custom model in fixture mode without claiming daemon persistence', async () => {
    useShellStore.setState({ fixtureMode: true });
    useProvidersStore.setState({ catalog: fixtureProviderCatalog() });

    await useProvidersStore.getState().addCustomModel('openai', {
      modelID: 'openai/experimental',
      displayName: 'Experimental'
    });
    let provider = useProvidersStore.getState().catalog?.find((entry) => entry.id === 'openai');
    expect(provider?.models).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: 'openai/experimental', label: 'Experimental', provenance: 'custom-model' })
    ]));
    expect(useProvidersStore.getState().mutationError).toBeNull();

    await useProvidersStore.getState().removeCustomModel('openai', 'openai/experimental');
    provider = useProvidersStore.getState().catalog?.find((entry) => entry.id === 'openai');
    expect(provider?.models).not.toEqual(expect.arrayContaining([
      expect.objectContaining({ id: 'openai/experimental' })
    ]));
  });

  it('uses the daemon mutation RPC and refreshes the verified catalog', async () => {
    const catalog = fixtureProviderCatalog().map((provider) =>
      provider.id === 'openai'
        ? { ...provider, catalogAvailable: true, catalogError: undefined }
        : provider
    );
    const providerCatalog = vi.fn(async () => catalog);
    const providerCustomModelUpsert = vi.fn(async () => ({ } as ConfigSnapshot));
    useShellStore.setState({
      fixtureMode: false,
      bridge: { providerCatalog, providerCustomModelUpsert } as never
    });
    useProvidersStore.setState({ catalog });

    await useProvidersStore.getState().addCustomModel('openai', {
      modelID: 'openai/experimental',
      displayName: 'Experimental'
    });

    expect(providerCustomModelUpsert).toHaveBeenCalledWith('openai', {
      modelID: 'openai/experimental',
      displayName: 'Experimental'
    });
    expect(providerCatalog).toHaveBeenCalledOnce();
    expect(useProvidersStore.getState().loading).toBe(false);
    expect(useProvidersStore.getState().mutationError).toBeNull();
  });

  it('fails closed when a packaged shell does not expose the mutation RPC', async () => {
    useShellStore.setState({ bridge: { providerCatalog: async () => [] } as never });
    await useProvidersStore.getState().addCustomModel('openai', { modelID: 'openai/experimental', displayName: '' });

    expect(useProvidersStore.getState().mutationBusy).toBeNull();
    expect(useProvidersStore.getState().mutationError).toBe('Provider custom-model RPC bridge is unavailable.');
  });
});
