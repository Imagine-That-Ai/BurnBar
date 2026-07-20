import { create } from 'zustand';
import { fixtureProviderCatalog } from '../daemonFixture.js';
import type { CustomModel, ProviderCatalog, ProviderCatalogModel } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

export type ProvidersState = {
  catalog: ProviderCatalog | null;
  loading: boolean;
  error: string | null;
  mutationBusy: string | null;
  mutationError: string | null;
  load(): Promise<void>;
  /** Clear the catalog and invalidate any in-flight response. */
  invalidate(error?: string | null): void;
  setPreferredCredentialSlot(providerID: string, slotID: string): Promise<void>;
  addCustomModel(providerID: string, customModel: CustomModel): Promise<void>;
  removeCustomModel(providerID: string, modelID: string): Promise<void>;
};

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function fixtureCustomModel(customModel: CustomModel): ProviderCatalogModel {
  const modelID = customModel.modelID.trim();
  return {
    id: modelID,
    label: customModel.displayName.trim() || modelID,
    aliases: [],
    capabilities: [],
    enabled: true,
    health: 'unknown',
    provenance: 'custom-model',
    detail: 'Configured custom model'
  };
}

function updateFixtureCatalog(
  catalog: ProviderCatalog,
  providerID: string,
  mutate: (models: ProviderCatalogModel[]) => ProviderCatalogModel[]
): ProviderCatalog {
  return catalog.map((provider) =>
    provider.id === providerID
      ? { ...provider, models: mutate([...(provider.models ?? [])]) }
      : provider
  );
}

let catalogLoadGeneration = 0;

export const useProvidersStore = create<ProvidersState>()((set, get) => ({
  catalog: null,
  loading: false,
  error: null,
  mutationBusy: null,
  mutationError: null,
  invalidate(error = null) {
    catalogLoadGeneration += 1;
    set({ catalog: null, loading: false, error });
  },
  async setPreferredCredentialSlot(providerID, slotID) {
    const normalizedProviderID = providerID.trim();
    const normalizedSlotID = slotID.trim();
    if (!normalizedProviderID) {
      set({ mutationError: 'Provider ID is required.' });
      return;
    }

    const mutationKey = `provider.preferred_account:${normalizedProviderID}`;
    set({ mutationBusy: mutationKey, mutationError: null });
    try {
      const { fixtureMode, bridge } = useShellStore.getState();
      const advertisedProvider = get().catalog?.find((provider) => provider.id === normalizedProviderID);
      const advertisedSlots = advertisedProvider?.credentialSlots ?? [];
      if (normalizedSlotID && advertisedSlots.length > 0 && !advertisedSlots.some((slot) => slot.slotID === normalizedSlotID)) {
        throw new Error('That credential slot is not available for this provider. Refresh the catalog and try again.');
      }

      if (fixtureMode) {
        const catalog = get().catalog ?? fixtureProviderCatalog();
        const provider = catalog.find((entry) => entry.id === normalizedProviderID);
        if (!provider) throw new Error('Provider is not present in the fixture catalog.');
        if (normalizedSlotID && !(provider.credentialSlots ?? []).some((slot) => slot.slotID === normalizedSlotID)) {
          throw new Error('That credential slot is not available for this provider.');
        }
        set({
          catalog: catalog.map((entry) =>
            entry.id === normalizedProviderID
              ? { ...entry, preferredCredentialSlotID: normalizedSlotID || undefined }
              : entry
          ),
          mutationBusy: null,
          mutationError: null
        });
        return;
      }

      if (!bridge) throw new Error('Packaged shell required to change provider routing.');
      if (typeof bridge.configUpdate !== 'function') {
        throw new Error('Provider routing is read-only because the config mutation RPC is unavailable.');
      }
      const snapshot = await bridge.configSnapshot();
      const currentProvider = snapshot.providers?.find((provider) => provider.providerID === normalizedProviderID);
      if (!currentProvider) throw new Error('Provider is not present in the daemon config snapshot.');
      if (normalizedSlotID && !currentProvider.credentialSlots.some((slot) => slot.slotID === normalizedSlotID)) {
        throw new Error('That credential slot is not present in the daemon config snapshot.');
      }
      const providers = (snapshot.providers ?? []).map((provider) => {
        if (provider.providerID !== normalizedProviderID) return provider;
        const next = { ...provider };
        if (normalizedSlotID) next.preferredCredentialSlotID = normalizedSlotID;
        else delete next.preferredCredentialSlotID;
        return next;
      });
      await bridge.configUpdate({ ...snapshot, providers });
      await get().load();
      set({ mutationBusy: null, mutationError: null });
    } catch (error) {
      set({ mutationBusy: null, mutationError: errorMessage(error, 'Provider routing update failed.') });
    }
  },
  async load() {
    const requestGeneration = ++catalogLoadGeneration;
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      if (requestGeneration !== catalogLoadGeneration) return;
      set({ catalog: fixtureProviderCatalog(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      if (requestGeneration !== catalogLoadGeneration) return;
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
      if (requestGeneration !== catalogLoadGeneration) return;
      set({ catalog, loading: false, error: null });
    } catch (e) {
      if (requestGeneration !== catalogLoadGeneration) return;
      set({
        catalog: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  },
  async addCustomModel(providerID, customModel) {
    const normalizedProviderID = providerID.trim();
    const normalizedModelID = customModel.modelID.trim();
    const normalizedDisplayName = customModel.displayName.trim() || normalizedModelID;
    if (!normalizedProviderID || !normalizedModelID) {
      set({ mutationError: 'Provider and model ID are required.' });
      return;
    }

    const mutationKey = `provider.custom_model.upsert:${normalizedProviderID}:${normalizedModelID}`;
    set({ mutationBusy: mutationKey, mutationError: null });
    try {
      const { fixtureMode, bridge } = useShellStore.getState();
      const nextModel = { modelID: normalizedModelID, displayName: normalizedDisplayName };
      if (fixtureMode) {
        const catalog = get().catalog ?? fixtureProviderCatalog();
        set({
          catalog: updateFixtureCatalog(catalog, normalizedProviderID, (models) => [
            ...models.filter((model) => model.id !== normalizedModelID),
            fixtureCustomModel(nextModel)
          ]),
          mutationBusy: null,
          mutationError: null
        });
        return;
      }
      if (!bridge) throw new Error('Packaged shell required to configure custom models.');
      if (!bridge.providerCustomModelUpsert) {
        throw new Error('Provider custom-model RPC bridge is unavailable.');
      }
      await bridge.providerCustomModelUpsert(normalizedProviderID, nextModel);
      await get().load();
      set({ mutationBusy: null, mutationError: null });
    } catch (error) {
      set({ mutationBusy: null, mutationError: errorMessage(error, 'Custom model update failed.') });
    }
  },
  async removeCustomModel(providerID, modelID) {
    const normalizedProviderID = providerID.trim();
    const normalizedModelID = modelID.trim();
    if (!normalizedProviderID || !normalizedModelID) {
      set({ mutationError: 'Provider and model ID are required.' });
      return;
    }

    const mutationKey = `provider.custom_model.remove:${normalizedProviderID}:${normalizedModelID}`;
    set({ mutationBusy: mutationKey, mutationError: null });
    try {
      const { fixtureMode, bridge } = useShellStore.getState();
      if (fixtureMode) {
        const catalog = get().catalog ?? fixtureProviderCatalog();
        set({
          catalog: updateFixtureCatalog(catalog, normalizedProviderID, (models) =>
            models.filter((model) => model.id !== normalizedModelID)
          ),
          mutationBusy: null,
          mutationError: null
        });
        return;
      }
      if (!bridge) throw new Error('Packaged shell required to configure custom models.');
      if (!bridge.providerCustomModelRemove) {
        throw new Error('Provider custom-model RPC bridge is unavailable.');
      }
      await bridge.providerCustomModelRemove(normalizedProviderID, normalizedModelID);
      await get().load();
      set({ mutationBusy: null, mutationError: null });
    } catch (error) {
      set({ mutationBusy: null, mutationError: errorMessage(error, 'Custom model removal failed.') });
    }
  }
}));
