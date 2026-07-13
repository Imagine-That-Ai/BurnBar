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
  ProxyRouteLogEntry
} from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';
import { useSystemStore } from './systemStore.js';

type MutationKind = string;

export type PrivacyMutationStatus = 'idle' | 'pending' | 'success' | 'error';

export type PrivacyMutationState = {
  status: PrivacyMutationStatus;
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
  loadRouteLog(): Promise<void>;
  clearRouteLog(): Promise<void>;
  loadNotifications(): Promise<void>;
  updateNotificationConfig(config: NotificationConfig): Promise<void>;
  runNotificationCommand(command: string, args?: string[]): Promise<void>;
  updatePrivacySettings(patch: PrivacySettingsPatch): Promise<void>;
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
  const { fixtureMode, bridge } = useShellStore.getState();
  if (!fixtureMode && bridge) {
    await useSystemStore.getState().loadConfig();
  }
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
      const next = fixtureMode ? requested : await bridge!.configUpdate!(requested);
      // Config responses may omit the path envelope because the canonical
      // daemon contract returns provider configuration plus consent fields.
      // Preserve the already-loaded daemon facts until the next explicit
      // config refresh rather than replacing them with empty renderer values.
      const committed: ConfigSnapshot = {
        ...current,
        ...next,
        paths: next.paths?.supportDir ? next.paths : current.paths,
        secretServiceStatus: next.secretServiceStatus || current.secretServiceStatus,
        providers: next.providers ?? current.providers
      };
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
