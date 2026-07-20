import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureProviderCatalog } from '../daemonFixture.js';
import type { ConfigSnapshot, ProviderCatalog } from '../tauriBridge.js';
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

  it('changes the preferred credential slot through the existing config contract', async () => {
    const config: ConfigSnapshot = {
      paths: { supportDir: '', socketPath: '', configDir: '', providerLogPaths: [] },
      secretServiceStatus: 'ready',
      telemetryEnabled: false,
      privacyOptIn: false,
      providers: [{
        providerID: 'anthropic',
        isEnabled: true,
        baseURL: '',
        preferredModelIDs: [],
        disabledAdvertisedModelIDs: [],
        credentialSlots: [
          { slotID: 'team', label: 'Team', isEnabled: true, status: 'ready' },
          { slotID: 'backup', label: 'Backup', isEnabled: true, status: 'ready' }
        ],
        modelVariants: [],
        modelAliases: [],
        modelDisplayOverrides: [],
        customModels: []
      }]
    };
    const refreshedCatalog: ProviderCatalog = [{
      ...fixtureProviderCatalog()[0]!,
      credentialSlots: config.providers![0]!.credentialSlots,
      preferredCredentialSlotID: 'backup'
    }];
    const configSnapshot = vi.fn(async () => config);
    const configUpdate = vi.fn(async (next: ConfigSnapshot) => next);
    const providerCatalog = vi.fn(async () => refreshedCatalog);
    useShellStore.setState({
      fixtureMode: false,
      bridge: { configSnapshot, configUpdate, providerCatalog } as never
    });
    useProvidersStore.setState({
      catalog: [{ ...refreshedCatalog[0]!, preferredCredentialSlotID: 'team' }]
    });

    await useProvidersStore.getState().setPreferredCredentialSlot('anthropic', 'backup');

    expect(configSnapshot).toHaveBeenCalledOnce();
    expect(configUpdate).toHaveBeenCalledWith(expect.objectContaining({
      providers: [expect.objectContaining({ preferredCredentialSlotID: 'backup' })]
    }));
    expect(providerCatalog).toHaveBeenCalledOnce();
    expect(useProvidersStore.getState().catalog?.[0]?.preferredCredentialSlotID).toBe('backup');
    expect(useProvidersStore.getState().mutationError).toBeNull();
  });

  it('fails closed when preferred-account routing is read-only', async () => {
    useShellStore.setState({
      fixtureMode: false,
      bridge: { configSnapshot: vi.fn(async () => fixtureProviderCatalog()) } as never
    });
    useProvidersStore.setState({
      catalog: [{
        ...fixtureProviderCatalog()[0]!,
        credentialSlots: [{ slotID: 'team', label: 'Team', isEnabled: true, status: 'ready' }]
      }]
    });

    await useProvidersStore.getState().setPreferredCredentialSlot('anthropic', 'team');

    expect(useProvidersStore.getState().mutationError).toBe(
      'Provider routing is read-only because the config mutation RPC is unavailable.'
    );
  });

  it('fails closed when a packaged shell does not expose the mutation RPC', async () => {
    useShellStore.setState({ bridge: { providerCatalog: async () => [] } as never });
    await useProvidersStore.getState().addCustomModel('openai', { modelID: 'openai/experimental', displayName: '' });

    expect(useProvidersStore.getState().mutationBusy).toBeNull();
    expect(useProvidersStore.getState().mutationError).toBe('Provider custom-model RPC bridge is unavailable.');
  });

  it('ignores an older catalog response after a newer refresh invalidates it', async () => {
    let resolveOld: ((catalog: ReturnType<typeof fixtureProviderCatalog>) => void) | undefined;
    let resolveNew: ((catalog: ReturnType<typeof fixtureProviderCatalog>) => void) | undefined;
    const providerCatalog = vi.fn()
      .mockImplementationOnce(() => new Promise((resolve) => { resolveOld = resolve; }))
      .mockImplementationOnce(() => new Promise((resolve) => { resolveNew = resolve; }));
    useShellStore.setState({ fixtureMode: false, bridge: { providerCatalog } as never });

    const oldLoad = useProvidersStore.getState().load();
    await vi.waitFor(() => expect(providerCatalog).toHaveBeenCalledTimes(1));
    useProvidersStore.getState().invalidate();
    const newLoad = useProvidersStore.getState().load();
    await vi.waitFor(() => expect(providerCatalog).toHaveBeenCalledTimes(2));

    const freshCatalog = fixtureProviderCatalog().slice(0, 1);
    resolveNew?.(freshCatalog);
    await newLoad;
    expect(useProvidersStore.getState().catalog).toEqual(freshCatalog);

    const staleCatalog = fixtureProviderCatalog().slice(1, 2);
    resolveOld?.(staleCatalog);
    await oldLoad;
    expect(useProvidersStore.getState().catalog).toEqual(freshCatalog);
  });
});
