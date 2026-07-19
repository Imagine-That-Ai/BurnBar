import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureConfigSnapshot } from '../daemonFixture.js';
import type { ConfigSnapshot, LinuxShellBridge, ProviderCatalog } from '../tauriBridge.js';
import { useProvidersStore } from './providersStore.js';
import { useSettingsWiringStore } from './settingsWiringStore.js';
import { useShellStore } from './shellStore.js';
import { useSystemStore } from './systemStore.js';

function resetStores(): void {
  useShellStore.setState({ bridge: null, fixtureMode: false });
  useSystemStore.setState({ config: null, loading: false, error: null });
  useProvidersStore.getState().invalidate();
  useProvidersStore.setState({ mutationBusy: null, mutationError: null });
  useSettingsWiringStore.setState({ busy: null, error: null });
}

function providerCatalog(accountLabel: string, preferredCredentialSlotID: string): ProviderCatalog {
  return [{
    id: 'anthropic',
    label: 'Anthropic',
    accountLabel,
    preferredCredentialSlotID,
    credentialSlots: [
      { slotID: 'team', label: 'Team workspace', isEnabled: true, status: 'ready' },
      { slotID: 'backup', label: 'Backup workspace', isEnabled: true, status: 'ready' }
    ],
    quotaBuckets: []
  }];
}

function configWithPreferredSlot(slotID: string): ConfigSnapshot {
  const config = fixtureConfigSnapshot();
  config.providers![0] = {
    ...config.providers![0],
    preferredCredentialSlotID: slotID,
    credentialSlots: [
      ...config.providers![0].credentialSlots,
      { slotID: 'backup', label: 'Backup workspace', isEnabled: true, status: 'ready' }
    ]
  };
  return config;
}

function liveBridge(overrides: Record<string, unknown> = {}): LinuxShellBridge {
  const config = fixtureConfigSnapshot();
  return {
    configSnapshot: vi.fn(async () => config),
    configUpdate: vi.fn(async (snapshot: ConfigSnapshot) => snapshot),
    providerCatalog: vi.fn(async () => providerCatalog('Backup workspace', 'backup')),
    providerCredentialSlotUpsert: vi.fn(async () => config),
    providerCredentialSlotRemove: vi.fn(async () => config),
    ...overrides
  } as unknown as LinuxShellBridge;
}

describe('settingsWiringStore provider catalog refresh', () => {
  beforeEach(resetStores);
  afterEach(resetStores);

  it('invalidates the old quota route while a preferred-slot refresh is in flight', async () => {
    const oldCatalog = providerCatalog('Team workspace', 'team');
    let resolveCatalog: ((value: ProviderCatalog) => void) | undefined;
    const bridge = liveBridge({
      providerCatalog: vi.fn(() => new Promise<ProviderCatalog>((resolve) => {
        resolveCatalog = resolve;
      }))
    });
    useShellStore.setState({ bridge, fixtureMode: false });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    useProvidersStore.setState({ catalog: oldCatalog, loading: false, error: null });

    const nextConfig = configWithPreferredSlot('backup');
    const refresh = useSettingsWiringStore.getState().replaceSnapshot(nextConfig);
    await vi.waitFor(() => expect(bridge.providerCatalog).toHaveBeenCalledOnce());

    expect(useProvidersStore.getState().catalog).toBeNull();
    expect(useProvidersStore.getState().loading).toBe(true);

    resolveCatalog?.(providerCatalog('Backup workspace', 'backup'));
    await refresh;

    expect(useProvidersStore.getState().catalog?.[0]).toMatchObject({
      accountLabel: 'Backup workspace',
      preferredCredentialSlotID: 'backup'
    });
  });

  it.each([
    ['upserts', 'upsertCredentialSlot'],
    ['removes', 'removeCredentialSlot']
  ] as const)('refreshes the quota route after it %s a credential slot', async (_label, operation) => {
    const bridge = liveBridge({
      [operation === 'upsertCredentialSlot' ? 'providerCredentialSlotUpsert' : 'providerCredentialSlotRemove']:
        vi.fn(async () => configWithPreferredSlot('backup'))
    });
    useShellStore.setState({ bridge, fixtureMode: false });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    useProvidersStore.setState({ catalog: providerCatalog('Team workspace', 'team'), loading: false, error: null });

    if (operation === 'upsertCredentialSlot') {
      await useSettingsWiringStore.getState().upsertCredentialSlot({
        providerID: 'anthropic',
        slotID: 'backup',
        label: 'Backup workspace',
        apiKey: 'secret-is-not-rendered',
        isEnabled: true
      });
    } else {
      await useSettingsWiringStore.getState().removeCredentialSlot('anthropic', 'team');
    }

    expect(bridge.providerCatalog).toHaveBeenCalledOnce();
    expect(useProvidersStore.getState().catalog?.[0]).toMatchObject({
      accountLabel: 'Backup workspace',
      preferredCredentialSlotID: 'backup'
    });
  });

  it('keeps the last known route when the mutation itself fails', async () => {
    const oldCatalog = providerCatalog('Team workspace', 'team');
    const bridge = liveBridge({
      configUpdate: vi.fn(async () => {
        throw new Error('daemon rejected preferred account');
      })
    });
    useShellStore.setState({ bridge, fixtureMode: false });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    useProvidersStore.setState({ catalog: oldCatalog, loading: false, error: null });

    await useSettingsWiringStore.getState().replaceSnapshot(configWithPreferredSlot('backup'));

    expect(bridge.providerCatalog).not.toHaveBeenCalled();
    expect(useProvidersStore.getState().catalog).toBe(oldCatalog);
    expect(useSettingsWiringStore.getState().error).toBe('daemon rejected preferred account');
  });

  it('clears stale quota state when the successful mutation cannot refresh the catalog', async () => {
    const bridge = liveBridge({
      providerCatalog: vi.fn(async () => {
        throw new Error('catalog unavailable');
      })
    });
    useShellStore.setState({ bridge, fixtureMode: false });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    useProvidersStore.setState({ catalog: providerCatalog('Team workspace', 'team'), loading: false, error: null });

    await useSettingsWiringStore.getState().replaceSnapshot(configWithPreferredSlot('backup'));

    expect(useProvidersStore.getState().catalog).toBeNull();
    expect(useProvidersStore.getState().error).toBe('catalog unavailable');
  });
});
