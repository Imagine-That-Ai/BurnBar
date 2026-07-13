import { create } from 'zustand';
import { fixtureProviderCatalog } from '../daemonFixture.js';
import type { ProviderCatalog } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

export type ProvidersState = {
  catalog: ProviderCatalog | null;
  loading: boolean;
  error: string | null;
  load(): Promise<void>;
  selectCredentialSlot(providerID: string, slotID: string | null): Promise<void>;
};

export const useProvidersStore = create<ProvidersState>()((set, get) => ({
  catalog: null,
  loading: false,
  error: null,
  async load() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ catalog: fixtureProviderCatalog(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      set({
        catalog: null,
        loading: false,
        error: 'Packaged shell required for live data.'
      });
      return;
    }
    set({ loading: true, error: null });
    try {
      const catalog = await bridge.providerCatalog();
      set({ catalog, loading: false, error: null });
    } catch (e) {
      set({
        catalog: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  },
  async selectCredentialSlot(providerID, slotID) {
    const { fixtureMode, bridge } = useShellStore.getState();
    const provider = get().catalog?.find((candidate) => candidate.id === providerID);
    if (!provider) throw new Error(`Provider '${providerID}' is not loaded.`);
    const normalizedSlotID = slotID?.trim() || null;
    if (
      normalizedSlotID &&
      !provider.credentialSlots?.some((slot) => slot.slotID === normalizedSlotID && slot.isEnabled)
    ) {
      throw new Error(`Credential slot '${normalizedSlotID}' is unavailable for ${provider.label}.`);
    }

    if (fixtureMode) {
      const selected = provider.credentialSlots?.find((slot) => slot.slotID === normalizedSlotID);
      set((state) => ({
        catalog: state.catalog?.map((candidate) =>
          candidate.id === providerID
            ? {
                ...candidate,
                preferredCredentialSlotID: normalizedSlotID ?? undefined,
                accountLabel: selected?.label ?? candidate.accountLabel
              }
            : candidate
        ),
        error: null
      }));
      return;
    }

    if (!bridge?.providerCredentialSlotSelect) {
      throw new Error('Credential account switching is unavailable in this Linux daemon build.');
    }
    await bridge.providerCredentialSlotSelect(providerID, normalizedSlotID);
    await get().load();
  }
}));
