import { create } from 'zustand';
import {
  fixtureConfigSnapshot,
  fixtureNotificationConfig,
  fixtureNotificationHealth,
  fixtureProxyRouteLog
} from '../daemonFixture.js';
import type {
  ConfigSnapshot,
  CustomModel,
  ModelAlias,
  ModelVariant,
  NotificationCommandResult,
  NotificationConfig,
  NotificationHealth,
  NativeNotificationCapabilities,
  NativeShortcutStatus,
  ProviderSettings,
  ProviderCredentialSlot,
  ProxyRouteLogEntry,
  LinuxPrivacyDeletionPreview,
  LinuxPrivacyDeletionResult,
  LinuxPrivacyExportRequest,
  LinuxPrivacyExportResult,
  LinuxPrivacyInventory,
  LinuxPrivacyRetentionApplyRequest,
  LinuxPrivacyRetentionApplyResult,
  LinuxPrivacyRetentionStatus,
  LinuxPrivacyStoreID
} from '../tauriBridge.js';
import { useProvidersStore } from './providersStore.js';
import { useShellStore } from './shellStore.js';
import { useSystemStore } from './systemStore.js';

type MutationKind = string;

export type PrivacyMutationStatus = 'idle' | 'pending' | 'success' | 'error';

export type PrivacyMutationState = {
  status: PrivacyMutationStatus;
  message: string | null;
};

export type PrivacyDeletionStatus = 'idle' | 'loading' | 'previewing' | 'ready' | 'deleting' | 'success' | 'error';

export type PrivacyDeletionState = {
  status: PrivacyDeletionStatus;
  inventory: LinuxPrivacyInventory | null;
  preview: LinuxPrivacyDeletionPreview | null;
  result: LinuxPrivacyDeletionResult | null;
  message: string | null;
};

export type PrivacyExportState = {
  status: PrivacyMutationStatus;
  result: LinuxPrivacyExportResult | null;
  message: string | null;
};

export type PrivacyRetentionStatus = 'idle' | 'loading' | 'ready' | 'applying' | 'success' | 'error';

export type PrivacyRetentionState = {
  status: PrivacyRetentionStatus;
  data: LinuxPrivacyRetentionStatus | null;
  result: LinuxPrivacyRetentionApplyResult | null;
  message: string | null;
};

export type PrivacySettingsPatch = Partial<
  Pick<ConfigSnapshot, 'telemetryEnabled' | 'privacyOptIn' | 'cloudSyncEnabled'>
>;

export type SettingsWiringState = {
  routeLog: ProxyRouteLogEntry[];
  notificationConfig: NotificationConfig | null;
  notificationHealth: NotificationHealth | null;
  notificationCommandResult: NotificationCommandResult | null;
  nativeNotificationCapabilities: NativeNotificationCapabilities | null;
  nativeShortcutStatus: NativeShortcutStatus | null;
  loadingRouteLog: boolean;
  loadingNotifications: boolean;
  busy: MutationKind | null;
  error: string | null;
  privacyMutation: PrivacyMutationState;
  privacyDeletion: PrivacyDeletionState;
  privacyExport: PrivacyExportState;
  privacyRetention: PrivacyRetentionState;
  loadRouteLog(): Promise<void>;
  clearRouteLog(): Promise<void>;
  loadNotifications(): Promise<void>;
  updateNotificationConfig(config: NotificationConfig): Promise<void>;
  runNotificationCommand(command: string, args?: string[]): Promise<void>;
  updatePrivacySettings(patch: PrivacySettingsPatch): Promise<void>;
  loadPrivacyInventory(): Promise<void>;
  previewPrivacyDeletion(stores: LinuxPrivacyStoreID[]): Promise<void>;
  executePrivacyDeletion(confirmation: string): Promise<void>;
  exportPrivacyData(request: LinuxPrivacyExportRequest): Promise<void>;
  loadPrivacyRetention(): Promise<void>;
  applyPrivacyRetention(request: LinuxPrivacyRetentionApplyRequest): Promise<void>;
  clearPrivacyDeletionPreview(): void;
  replaceSnapshot(snapshot: ConfigSnapshot): Promise<void>;
  upsertCredentialSlot(params: {
    providerID: string;
    slotID?: string;
    label: string;
    apiKey: string;
    isEnabled: boolean;
    endpointProfileID?: string | null;
    authMethodID?: string | null;
  }): Promise<void>;
  removeCredentialSlot(providerID: string, slotID: string): Promise<void>;
  upsertModelVariant(providerID: string, variant: ModelVariant): Promise<void>;
  removeModelVariant(providerID: string, variantID: string): Promise<void>;
  upsertModelAlias(providerID: string, alias: ModelAlias): Promise<void>;
  removeModelAlias(providerID: string, aliasID: string): Promise<void>;
  upsertCustomModel(providerID: string, customModel: CustomModel): Promise<void>;
  removeCustomModel(providerID: string, modelID: string): Promise<void>;
  setDisplayName(providerID: string, modelID: string, displayName: string): Promise<void>;
  clearDisplayName(providerID: string, modelID: string): Promise<void>;
};

function message(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

async function refreshSnapshotFrom(result: ConfigSnapshot): Promise<void> {
  useSystemStore.setState({ config: result, loading: false, error: null });
  // Invalidate quota-facing state before the follow-up config RPC so the old
  // account cannot remain visible while either refresh is in flight.
  const providerRefresh = refreshProviderCatalogAfterMutation();
  const { fixtureMode, bridge } = useShellStore.getState();
  if (!fixtureMode && bridge) {
    await useSystemStore.getState().loadConfig();
  }
  await providerRefresh;
}

/**
 * Config mutations also change the provider catalog consumed by quota and
 * provider routes. Drop the old catalog before asking the daemon again so a
 * successful account switch cannot leave the previous account visible while
 * the refresh is in flight. The request-generation guard in providersStore
 * prevents an older route hydration response from resurrecting that state.
 */
async function refreshProviderCatalogAfterMutation(): Promise<void> {
  const { fixtureMode, bridge } = useShellStore.getState();
  useProvidersStore.getState().invalidate();

  if (fixtureMode) {
    await useProvidersStore.getState().load();
    return;
  }

  if (!bridge || typeof bridge.providerCatalog !== 'function') {
    useProvidersStore.getState().invalidate('Provider catalog refresh RPC bridge is unavailable.');
    return;
  }

  await useProvidersStore.getState().load();
}

function mutateFixture(mutator: (snapshot: ConfigSnapshot) => ConfigSnapshot): ConfigSnapshot {
  const current = useSystemStore.getState().config ?? fixtureConfigSnapshot();
  return mutator(structuredClone(current));
}

function mutateProvider(
  snapshot: ConfigSnapshot,
  providerID: string,
  mutate: (provider: ProviderSettings) => ProviderSettings
): ConfigSnapshot {
  return {
    ...snapshot,
    providers: (snapshot.providers ?? []).map((provider) =>
      provider.providerID === providerID ? mutate({ ...provider }) : provider
    )
  };
}

function mergeConfigSnapshot(current: ConfigSnapshot, next: ConfigSnapshot): ConfigSnapshot {
  return {
    ...current,
    ...next,
    // Older daemon peers can omit the path envelope from mutation/readback
    // responses. Keep the last verified paths rather than replacing them with
    // empty renderer values.
    paths: next.paths?.supportDir ? next.paths : current.paths,
    secretServiceStatus: next.secretServiceStatus || current.secretServiceStatus,
    providers: next.providers ?? current.providers
  };
}

function assertPrivacyReadback(snapshot: ConfigSnapshot, patch: PrivacySettingsPatch): void {
  for (const key of Object.keys(patch) as (keyof PrivacySettingsPatch)[]) {
    const expected = patch[key];
    if (expected !== undefined && snapshot[key] !== expected) {
      throw new Error(`Daemon did not confirm ${key} after save.`);
    }
  }
}

export const useSettingsWiringStore = create<SettingsWiringState>()((set, get) => ({
  routeLog: [],
  notificationConfig: null,
  notificationHealth: null,
  notificationCommandResult: null,
  nativeNotificationCapabilities: null,
  nativeShortcutStatus: null,
  loadingRouteLog: false,
  loadingNotifications: false,
  busy: null,
  error: null,
  privacyMutation: { status: 'idle', message: null },
  privacyDeletion: { status: 'idle', inventory: null, preview: null, result: null, message: null },
  privacyExport: { status: 'idle', result: null, message: null },
  privacyRetention: { status: 'idle', data: null, result: null, message: null },

  async loadRouteLog() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ routeLog: fixtureProxyRouteLog(), loadingRouteLog: false, error: null });
      return;
    }
    if (!bridge) {
      set({ routeLog: [], loadingRouteLog: false, error: 'Packaged shell required for proxy route log.' });
      return;
    }
    set({ loadingRouteLog: true, error: null });
    try {
      if (!bridge.proxyRouteLogRecent) throw new Error('Proxy route log RPC bridge is unavailable.');
      const routeLog = await bridge.proxyRouteLogRecent(20);
      set({ routeLog, loadingRouteLog: false, error: null });
    } catch (e) {
      set({ routeLog: [], loadingRouteLog: false, error: message(e, 'Route log request failed') });
    }
  },

  async clearRouteLog() {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'route-log.clear', error: null });
    try {
      if (fixtureMode) {
        set({ routeLog: [], busy: null, error: null });
        return;
      }
      if (!bridge) throw new Error('Packaged shell required to clear proxy route log.');
      if (!bridge.proxyRouteLogClear) throw new Error('Proxy route log clear RPC bridge is unavailable.');
      await bridge.proxyRouteLogClear();
      await get().loadRouteLog();
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Route log clear failed') });
    }
  },

  async loadNotifications() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({
        notificationConfig: fixtureNotificationConfig(),
        notificationHealth: fixtureNotificationHealth(),
        nativeNotificationCapabilities: null,
        nativeShortcutStatus: null,
        loadingNotifications: false,
        error: null
      });
      return;
    }
    if (!bridge) {
      set({
        notificationConfig: null,
        notificationHealth: null,
        nativeNotificationCapabilities: null,
        nativeShortcutStatus: null,
        loadingNotifications: false,
        error: 'Packaged shell required for notification settings.'
      });
      return;
    }
    set({ loadingNotifications: true, error: null });
    try {
      const [notificationConfig, notificationHealth, nativeNotificationCapabilities, nativeShortcutStatus] = await Promise.all([
        bridge.notificationConfigGet ? bridge.notificationConfigGet() : Promise.reject(new Error('Notification config RPC bridge is unavailable.')),
        bridge.notificationHealth ? bridge.notificationHealth() : Promise.reject(new Error('Notification health RPC bridge is unavailable.')),
        bridge.nativeNotificationCapabilities ? bridge.nativeNotificationCapabilities() : Promise.resolve(null),
        bridge.nativeShortcutStatus ? bridge.nativeShortcutStatus() : Promise.resolve(null)
      ]);
      set({ notificationConfig, notificationHealth, nativeNotificationCapabilities, nativeShortcutStatus, loadingNotifications: false, error: null });
    } catch (e) {
      set({ loadingNotifications: false, error: message(e, 'Notification request failed') });
    }
  },

  async updateNotificationConfig(config) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'notification.config.update', error: null });
    try {
      if (fixtureMode) {
        set({ notificationConfig: config, notificationHealth: fixtureNotificationHealth(), busy: null, error: null });
        return;
      }
      if (!bridge) throw new Error('Packaged shell required to update notification settings.');
      if (!bridge.notificationConfigUpdate) throw new Error('Notification update RPC bridge is unavailable.');
      await bridge.notificationConfigUpdate(config);
      await get().loadNotifications();
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Notification update failed') });
    }
  },

  async runNotificationCommand(command, args = []) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: `notification.command.${command}`, notificationCommandResult: null, error: null });
    try {
      if (fixtureMode) {
        set({
          busy: null,
          notificationCommandResult: { command, ok: true, message: `Fixture ${command} command accepted.` },
          error: null
        });
        return;
      }
      if (!bridge) throw new Error('Packaged shell required to send notification commands.');
      if (!bridge.notificationCommand) throw new Error('Notification command RPC bridge is unavailable.');
      const notificationCommandResult = await bridge.notificationCommand(command, args);
      await get().loadNotifications();
      set({ busy: null, notificationCommandResult, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Notification command failed') });
    }
  },

  async updatePrivacySettings(patch) {
    const { fixtureMode, bridge } = useShellStore.getState();
    const current = useSystemStore.getState().config;
    set({
      busy: 'privacy.config.update',
      error: null,
      privacyMutation: { status: 'pending', message: 'Saving privacy choices…' }
    });
    try {
      if (!current) throw new Error('Config snapshot is unavailable. Refresh settings and try again.');
      if (!fixtureMode && !bridge?.configUpdate) {
        throw new Error('Packaged shell required to save privacy choices.');
      }
      const requested = { ...current, ...patch };
      let committed: ConfigSnapshot;
      if (fixtureMode) {
        committed = requested;
      } else {
        // A successful mutation response is not proof that the daemon
        // persisted the choice. Read the canonical snapshot after the write
        // and fail closed when it does not confirm the requested fields.
        await bridge!.configUpdate!(requested);
        committed = mergeConfigSnapshot(current, await bridge!.configSnapshot());
      }
      assertPrivacyReadback(committed, patch);
      useSystemStore.setState({ config: committed, loading: false, error: null });
      set({
        busy: null,
        error: null,
        privacyMutation: { status: 'success', message: 'Privacy choices saved.' }
      });
    } catch (e) {
      const failure = message(e, 'Privacy choices could not be saved.');
      set({
        busy: null,
        error: failure,
        privacyMutation: { status: 'error', message: failure }
      });
    }
  },

  async loadPrivacyInventory() {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ privacyDeletion: { ...get().privacyDeletion, status: 'loading', message: null } });
    try {
      if (fixtureMode) throw new Error('Privacy deletion requires the packaged Linux daemon.');
      if (!bridge?.linuxPrivacyInventory) throw new Error('Privacy inventory RPC bridge is unavailable.');
      const inventory = await bridge.linuxPrivacyInventory();
      set({ privacyDeletion: { ...get().privacyDeletion, status: 'idle', inventory, preview: null, result: null, message: null } });
    } catch (e) {
      set({ privacyDeletion: { ...get().privacyDeletion, status: 'error', message: message(e, 'Privacy inventory failed.') } });
    }
  },

  async previewPrivacyDeletion(stores) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'privacy.deletion.preview', privacyDeletion: { ...get().privacyDeletion, status: 'previewing', message: null, preview: null, result: null } });
    try {
      if (fixtureMode) throw new Error('Privacy deletion requires the packaged Linux daemon.');
      if (!bridge?.linuxPrivacyDeletionPreview) throw new Error('Privacy deletion preview RPC bridge is unavailable.');
      if (stores.length === 0) throw new Error('Choose at least one local store.');
      const preview = await bridge.linuxPrivacyDeletionPreview(stores);
      set({ busy: null, privacyDeletion: { ...get().privacyDeletion, status: 'ready', preview, message: null } });
    } catch (e) {
      set({ busy: null, privacyDeletion: { ...get().privacyDeletion, status: 'error', message: message(e, 'Privacy deletion preview failed.') } });
    }
  },

  async executePrivacyDeletion(confirmation) {
    const { fixtureMode, bridge } = useShellStore.getState();
    const preview = get().privacyDeletion.preview;
    set({ busy: 'privacy.deletion.execute', privacyDeletion: { ...get().privacyDeletion, status: 'deleting', message: null } });
    try {
      if (fixtureMode) throw new Error('Privacy deletion requires the packaged Linux daemon.');
      if (!bridge?.linuxPrivacyDeletionExecute) throw new Error('Privacy deletion RPC bridge is unavailable.');
      if (!preview) throw new Error('Preview local data before confirming deletion.');
      const result = await bridge.linuxPrivacyDeletionExecute({
        token: preview.token,
        stores: preview.stores,
        confirmation
      });
      let inventory = get().privacyDeletion.inventory;
      if (bridge.linuxPrivacyInventory) inventory = await bridge.linuxPrivacyInventory();
      set({ busy: null, privacyDeletion: { status: 'success', inventory, preview: null, result, message: 'Selected local stores deleted.' } });
    } catch (e) {
      set({ busy: null, privacyDeletion: { ...get().privacyDeletion, status: 'error', message: message(e, 'Privacy deletion failed.') } });
    }
  },

  async exportPrivacyData(request) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'privacy.export', privacyExport: { status: 'pending', result: null, message: null } });
    try {
      if (fixtureMode) throw new Error('Privacy export requires the packaged Linux daemon.');
      if (!bridge?.linuxPrivacyExport) throw new Error('Privacy export RPC bridge is unavailable.');
      if (request.stores.length === 0) throw new Error('Choose at least one local store to export.');
      if (request.destinationPath.trim().length === 0) throw new Error('Choose an export destination.');
      if (request.passphrase.length < 8) throw new Error('Use an export passphrase of at least 8 characters.');
      const result = await bridge.linuxPrivacyExport(request);
      set({ busy: null, privacyExport: { status: 'success', result, message: 'Encrypted local privacy export written.' } });
    } catch (e) {
      const failure = message(e, 'Privacy export failed.');
      set({ busy: null, privacyExport: { status: 'error', result: null, message: failure } });
    }
  },

  async loadPrivacyRetention() {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ privacyRetention: { ...get().privacyRetention, status: 'loading', message: null } });
    try {
      if (fixtureMode) throw new Error('Privacy retention requires the packaged Linux daemon.');
      if (!bridge?.linuxPrivacyRetentionStatus) throw new Error('Privacy retention status RPC bridge is unavailable.');
      const data = await bridge.linuxPrivacyRetentionStatus();
      set({ privacyRetention: { status: 'ready', data, result: null, message: null } });
    } catch (e) {
      set({ privacyRetention: { ...get().privacyRetention, status: 'error', message: message(e, 'Privacy retention status failed.') } });
    }
  },

  async applyPrivacyRetention(request) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'privacy.retention.apply', privacyRetention: { ...get().privacyRetention, status: 'applying', message: null } });
    try {
      if (fixtureMode) throw new Error('Privacy retention requires the packaged Linux daemon.');
      if (!bridge?.linuxPrivacyRetentionApply) throw new Error('Privacy retention apply RPC bridge is unavailable.');
      if (request.confirmation !== 'APPLY RETENTION POLICY') throw new Error('Type the exact retention confirmation phrase.');
      if (request.rules.length !== 2) throw new Error('Retention policy must cover both local stores.');
      const result = await bridge.linuxPrivacyRetentionApply(request);
      set({
        busy: null,
        privacyRetention: {
          status: 'success',
          data: result.status,
          result,
          message: `Retention policy applied; removed ${result.removedEntries} store entr${result.removedEntries === 1 ? 'y' : 'ies'}.`
        }
      });
    } catch (e) {
      const failure = message(e, 'Privacy retention apply failed.');
      set({ busy: null, privacyRetention: { ...get().privacyRetention, status: 'error', message: failure } });
    }
  },

  clearPrivacyDeletionPreview() {
    set({ privacyDeletion: { ...get().privacyDeletion, status: 'idle', preview: null, message: null } });
  },

  async replaceSnapshot(snapshot) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'config.update', error: null });
    try {
      if (!fixtureMode && !bridge?.configUpdate) throw new Error('Config update RPC bridge is unavailable.');
      const next = fixtureMode ? snapshot : await bridge!.configUpdate!(snapshot);
      await refreshSnapshotFrom(next);
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Config update failed') });
    }
  },

  async upsertCredentialSlot(params) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'provider.credential_slot.upsert', error: null });
    try {
      const next = fixtureMode
        ? mutateFixture((snapshot) =>
            mutateProvider(snapshot, params.providerID, (provider) => ({
              ...provider,
              credentialSlots: [
                ...provider.credentialSlots.filter((slot: ProviderCredentialSlot) => slot.slotID !== (params.slotID ?? `${params.providerID}-fixture-slot`)),
                {
                  slotID: params.slotID ?? `${params.providerID}-fixture-slot`,
                  label: params.label,
                  isEnabled: params.isEnabled,
                  status: 'ready',
                  authMethodID: params.authMethodID ?? undefined,
                  updatedAt: new Date().toISOString()
                } satisfies ProviderCredentialSlot
              ]
            }))
          )
        : await bridge!.providerCredentialSlotUpsert!(params);
      await refreshSnapshotFrom(next);
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Credential slot update failed') });
    }
  },

  async removeCredentialSlot(providerID, slotID) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'provider.credential_slot.remove', error: null });
    try {
      const next = fixtureMode
        ? mutateFixture((snapshot) =>
            mutateProvider(snapshot, providerID, (provider) => ({
              ...provider,
              credentialSlots: provider.credentialSlots.filter((slot: ProviderCredentialSlot) => slot.slotID !== slotID)
            }))
          )
        : await bridge!.providerCredentialSlotRemove!(providerID, slotID);
      await refreshSnapshotFrom(next);
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Credential slot removal failed') });
    }
  },

  async upsertModelVariant(providerID, variant) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'provider.model_variant.upsert', error: null });
    try {
      const next = fixtureMode
        ? mutateFixture((snapshot) =>
            mutateProvider(snapshot, providerID, (provider) => ({
              ...provider,
              modelVariants: [...provider.modelVariants.filter((v) => v.variantID !== variant.variantID), variant]
            }))
          )
        : await bridge!.providerModelVariantUpsert!(providerID, variant);
      await refreshSnapshotFrom(next);
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Model variant update failed') });
    }
  },

  async removeModelVariant(providerID, variantID) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'provider.model_variant.remove', error: null });
    try {
      const next = fixtureMode
        ? mutateFixture((snapshot) =>
            mutateProvider(snapshot, providerID, (provider) => ({
              ...provider,
              modelVariants: provider.modelVariants.filter((variant) => variant.variantID !== variantID)
            }))
          )
        : await bridge!.providerModelVariantRemove!(providerID, variantID);
      await refreshSnapshotFrom(next);
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Model variant removal failed') });
    }
  },

  async upsertModelAlias(providerID, alias) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'provider.model_alias.upsert', error: null });
    try {
      const next = fixtureMode
        ? mutateFixture((snapshot) =>
            mutateProvider(snapshot, providerID, (provider) => ({
              ...provider,
              modelAliases: [...provider.modelAliases.filter((a) => a.aliasID !== alias.aliasID), alias]
            }))
          )
        : await bridge!.providerModelAliasUpsert!(providerID, alias);
      await refreshSnapshotFrom(next);
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Model alias update failed') });
    }
  },

  async removeModelAlias(providerID, aliasID) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'provider.model_alias.remove', error: null });
    try {
      const next = fixtureMode
        ? mutateFixture((snapshot) =>
            mutateProvider(snapshot, providerID, (provider) => ({
              ...provider,
              modelAliases: provider.modelAliases.filter((alias) => alias.aliasID !== aliasID)
            }))
          )
        : await bridge!.providerModelAliasRemove!(providerID, aliasID);
      await refreshSnapshotFrom(next);
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Model alias removal failed') });
    }
  },

  async upsertCustomModel(providerID, customModel) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'provider.custom_model.upsert', error: null });
    try {
      const next = fixtureMode
        ? mutateFixture((snapshot) =>
            mutateProvider(snapshot, providerID, (provider) => ({
              ...provider,
              customModels: [...provider.customModels.filter((model) => model.modelID !== customModel.modelID), customModel]
            }))
          )
        : await bridge!.providerCustomModelUpsert!(providerID, customModel);
      await refreshSnapshotFrom(next);
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Custom model update failed') });
    }
  },

  async removeCustomModel(providerID, modelID) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'provider.custom_model.remove', error: null });
    try {
      const next = fixtureMode
        ? mutateFixture((snapshot) =>
            mutateProvider(snapshot, providerID, (provider) => ({
              ...provider,
              customModels: provider.customModels.filter((model) => model.modelID !== modelID)
            }))
          )
        : await bridge!.providerCustomModelRemove!(providerID, modelID);
      await refreshSnapshotFrom(next);
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Custom model removal failed') });
    }
  },

  async setDisplayName(providerID, modelID, displayName) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'provider.model_display_name.set', error: null });
    try {
      const next = fixtureMode
        ? mutateFixture((snapshot) =>
            mutateProvider(snapshot, providerID, (provider) => ({
              ...provider,
              modelDisplayOverrides: [
                ...provider.modelDisplayOverrides.filter((override) => override.modelID !== modelID),
                { modelID, displayName }
              ]
            }))
          )
        : await bridge!.providerModelDisplayNameSet!(providerID, modelID, displayName);
      await refreshSnapshotFrom(next);
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Display name update failed') });
    }
  },

  async clearDisplayName(providerID, modelID) {
    const { fixtureMode, bridge } = useShellStore.getState();
    set({ busy: 'provider.model_display_name.clear', error: null });
    try {
      const next = fixtureMode
        ? mutateFixture((snapshot) =>
            mutateProvider(snapshot, providerID, (provider) => ({
              ...provider,
              modelDisplayOverrides: provider.modelDisplayOverrides.filter((override) => override.modelID !== modelID)
            }))
          )
        : await bridge!.providerModelDisplayNameClear!(providerID, modelID);
      await refreshSnapshotFrom(next);
      set({ busy: null, error: null });
    } catch (e) {
      set({ busy: null, error: message(e, 'Display name clear failed') });
    }
  }
}));
