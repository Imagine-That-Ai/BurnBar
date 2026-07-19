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
