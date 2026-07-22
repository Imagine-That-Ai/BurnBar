// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from 'vitest';
import { fixtureProviderCatalog } from '../daemonFixture.js';
import { useShellStore } from './shellStore.js';
import { useProvidersStore } from './providersStore.js';

const defaultLoad = useProvidersStore.getState().load;
const defaultSelect = useProvidersStore.getState().selectCredentialSlot;

describe('providersStore account selection', () => {
  beforeEach(() => {
    localStorage.clear();
    useShellStore.setState({ fixtureMode: true, bridge: null });
    useProvidersStore.setState({
      catalog: fixtureProviderCatalog(),
      loading: false,
      error: null,
      load: defaultLoad,
      selectCredentialSlot: defaultSelect
    });
  });

  it('pins an enabled fixture credential slot without exposing secret material', async () => {
    await useProvidersStore.getState().selectCredentialSlot('anthropic', 'anthropic-personal');
    const provider = useProvidersStore.getState().catalog?.find((entry) => entry.id === 'anthropic');
    expect(provider?.preferredCredentialSlotID).toBe('anthropic-personal');
    expect(provider?.accountLabel).toBe('Personal fallback');
    expect(JSON.stringify(provider)).not.toContain('apiKey');
  });

  it('rejects disabled or unknown slots before attempting a daemon mutation', async () => {
    await expect(
      useProvidersStore.getState().selectCredentialSlot('anthropic', 'does-not-exist')
    ).rejects.toThrow(/unavailable/i);
  });
});
