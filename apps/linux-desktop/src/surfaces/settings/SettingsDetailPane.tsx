import type { ReactNode } from 'react';
import { useEffect, useMemo, useState } from 'react';
import type { AccountStatus, ConfigSnapshot, LinuxShellBridge, NotificationConfig, ProviderSettings } from '../../tauriBridge.js';
import type { DaemonStatusCopy } from '../../daemonStatusCopy.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import {
  LINUX_PROVIDER_PATH_REGISTRY,
  providerCoverageSummary,
  resolveProviderLogicalPath
} from '../../providerPathRegistry.js';
import { useSupportStore } from '../../state/supportStore.js';
import { useSettingsWiringStore } from '../../state/settingsWiringStore.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useShellStore } from '../../state/shellStore.js';
import { CopyPathButton } from '../system/CopyPathButton.js';
import { VersionGrid } from '../support/VersionGrid.js';
import { OnboardingSurface } from '../OnboardingSurface.js';
import { TextExpansionSurface } from '../TextExpansionSurface.js';
import { UpdateStatusCard } from '../updates/UpdateStatusCard.js';
import { SettingGroup } from './SettingGroup.js';
import { SettingRow } from './SettingRow.js';
import { ReadOnlyToggle } from './ReadOnlyToggle.js';
import { SettingsHomeView } from './SettingsHomeView.js';
import { SettingsAppearanceControls } from './SettingsAppearanceControls.js';
import { SettingsDrillRow } from './SettingsDrillRow.js';
import { settingsTabMeta, type SettingsTabId } from './settingsTabs.js';
import { fixtureAccountStatus } from '../../daemonFixture.js';

const UPDATE_CHANNEL_COPY: Record<'deb' | 'rpm' | 'appimage' | 'unknown', string> = {
  deb: 'Installed via the Debian package channel; apt/dpkg owns upgrades.',
  rpm: 'Installed via the RPM package channel; dnf/rpm owns upgrades.',
  appimage: 'Installed as AppImage; replace the image file from your release source.',
  unknown: 'Package channel could not be determined; use your distro package manager or release notes.'
};

function SettingsDetailHeader({
  title,
  onDone
}: {
  title: string;
  onDone: () => void;
}) {
  return (
    <header className="settings-detail-header">
      <h2 className="settings-detail-title">{title}</h2>
      <button type="button" className="settings-done-btn" onClick={onDone}>
        Done
      </button>
    </header>
  );
}

function UpdatesDetail({ fixtureMode, status }: { fixtureMode: boolean; status: DaemonStatusCopy }) {
  const versionInfo = useSupportStore((s) => s.versionInfo);
  const versionLoading = useSupportStore((s) => s.versionLoading);
  const versionError = useSupportStore((s) => s.versionError);
  const loadVersion = useSupportStore((s) => s.loadVersion);
  const updateStatus = useSupportStore((s) => s.updateStatus);
  const updateLoading = useSupportStore((s) => s.updateLoading);
  const updateError = useSupportStore((s) => s.updateError);
  const checkUpdate = useSupportStore((s) => s.checkUpdate);
  useLaneLoad(loadVersion);

  if (versionLoading && !versionInfo) {
    return <p className="muted">Loading package channel and version facts…</p>;
  }
  if (versionError && !versionInfo) {
    return (
      <OfflineNotice
        status={status}
        summary="Updates needs the packaged shell to read version and channel facts."
        fixtureMode={fixtureMode}
      />
    );
  }
  if (!versionInfo) {
    return (
      <OfflineNotice
        status={status}
        summary="Version facts are unavailable without the packaged shell or fixture mode."
        fixtureMode={fixtureMode}
      />
    );
  }
  return (
    <>
      <p className="muted settings-tab-lede">
        Updates are delivered by your package manager — this shell does not download or install upgrades in-app.
      </p>
      <VersionGrid info={versionInfo} />
      <UpdateStatusCard
        status={updateStatus}
        loading={updateLoading}
        error={updateError}
        onCheck={() => void checkUpdate()}
      />
      <SettingGroup title="Package channel" sectionHeader>
        <p>{UPDATE_CHANNEL_COPY[versionInfo.packageChannel]}</p>
      </SettingGroup>
    </>
  );
}

function ConfigRefreshRow({ onRefresh, busy }: { onRefresh: () => void; busy: boolean }) {
  return (
    <SettingRow
      iconGlyph="↻"
      label="Refresh daemon config"
      description="Reload paths, Secret Service status, and privacy flags from the local peer."
      control={
        <button type="button" className="ghost" onClick={onRefresh} disabled={busy} aria-busy={busy}>
          {busy ? 'Refreshing…' : 'Refresh'}
        </button>
      }
    />
  );
}

function cloneConfig(config: ConfigSnapshot): ConfigSnapshot {
  return JSON.parse(JSON.stringify(config)) as ConfigSnapshot;
}

function updateProviderSnapshot(
  config: ConfigSnapshot,
  providerID: string,
  mutate: (provider: ProviderSettings) => ProviderSettings
): ConfigSnapshot {
  const next = cloneConfig(config);
  next.providers = (next.providers ?? []).map((provider) =>
    provider.providerID === providerID ? mutate(provider) : provider
  );
  return next;
}

function firstWritableModel(provider: ProviderSettings): string {
  return provider.preferredModelIDs[0]
    ?? provider.customModels[0]?.modelID
    ?? provider.modelVariants[0]?.baseModelID
    ?? 'model-id';
}

function providerDisplay(provider: ProviderSettings): string {
  return provider.providerID.charAt(0).toUpperCase() + provider.providerID.slice(1);
}

function providerCoverageLabel(coverage: 'local-parser' | 'api-backed' | 'unavailable'): string {
  switch (coverage) {
    case 'local-parser':
      return 'Local parser registered';
    case 'api-backed':
      return 'API-backed; no local parser';
    case 'unavailable':
      return 'Local usage unavailable';
  }
}

function AgentsDetail({ config }: { config: ConfigSnapshot }) {
  const providers = config.providers ?? [];
  const [selectedProviderID, setSelectedProviderID] = useState(providers[0]?.providerID ?? '');
  const health = useShellStore((s) => s.health);
  const busy = useSettingsWiringStore((s) => s.busy);
  const error = useSettingsWiringStore((s) => s.error);
  const routeLog = useSettingsWiringStore((s) => s.routeLog);
  const loadingRouteLog = useSettingsWiringStore((s) => s.loadingRouteLog);
  const replaceSnapshot = useSettingsWiringStore((s) => s.replaceSnapshot);
  const upsertCredentialSlot = useSettingsWiringStore((s) => s.upsertCredentialSlot);
  const removeCredentialSlot = useSettingsWiringStore((s) => s.removeCredentialSlot);
  const upsertModelVariant = useSettingsWiringStore((s) => s.upsertModelVariant);
  const removeModelVariant = useSettingsWiringStore((s) => s.removeModelVariant);
  const upsertModelAlias = useSettingsWiringStore((s) => s.upsertModelAlias);
  const removeModelAlias = useSettingsWiringStore((s) => s.removeModelAlias);
  const upsertCustomModel = useSettingsWiringStore((s) => s.upsertCustomModel);
  const removeCustomModel = useSettingsWiringStore((s) => s.removeCustomModel);
  const setDisplayName = useSettingsWiringStore((s) => s.setDisplayName);
  const clearDisplayName = useSettingsWiringStore((s) => s.clearDisplayName);
  const loadRouteLog = useSettingsWiringStore((s) => s.loadRouteLog);
  const clearRouteLog = useSettingsWiringStore((s) => s.clearRouteLog);

  useLaneLoad(loadRouteLog);

  const provider = providers.find((p) => p.providerID === selectedProviderID) ?? providers[0];
  const disabled = Boolean(busy);
  const endpoint = health?.gatewayEnabled
    ? `${health.gatewayHost ?? '127.0.0.1'}:${health.gatewayPort ?? 0}`
    : 'Gateway disabled or unavailable';

  if (!provider) {
    return (
      <SettingGroup title="Model proxy" sectionHeader hideTitle>
        <p className="muted settings-tab-lede">
          The daemon config snapshot has no provider rows yet. Add provider accounts from the provider lane, then return here.
        </p>
      </SettingGroup>
    );
  }

  const setRouterMode = (routerMode: string) => {
    void replaceSnapshot({ ...cloneConfig(config), routerMode });
  };
  const setProviderEnabled = (isEnabled: boolean) => {
    void replaceSnapshot(updateProviderSnapshot(config, provider.providerID, (p) => ({ ...p, isEnabled })));
  };
  const saveBaseURL = (form: HTMLFormElement) => {
    const baseURL = String(new FormData(form).get('baseURL') ?? '').trim();
    if (!baseURL) return;
    void replaceSnapshot(updateProviderSnapshot(config, provider.providerID, (p) => ({ ...p, baseURL })));
  };

  return (
    <>
      {error ? (
        <Banner tone="degraded" role="alert">
          {error}
        </Banner>
      ) : null}
      <SettingGroup title="Gateway" sectionHeader hideTitle>
        <p className="muted settings-tab-lede">
          Linux v1 reads gateway health from daemon.health. Provider routing and advertised model controls write through daemon config RPCs.
        </p>
        <SettingRow
          iconGlyph="⎔"
          label="Local gateway endpoint"
          description="OpenAI-compatible endpoint served by the daemon when the gateway was launched with gateway flags."
          control={<span className="muted mono">{endpoint}</span>}
        />
        <SettingRow
          iconGlyph="⇄"
          label="Router mode"
          description="Matches macOS model proxy routing strategy at daemon config scope."
          control={
            <select value={config.routerMode ?? 'providerFamilyFailover'} disabled={disabled} onChange={(e) => setRouterMode(e.currentTarget.value)}>
              <option value="providerFamilyFailover">Provider family failover</option>
              <option value="exactModelOnly">Exact model only</option>
              <option value="cheapest">Cheapest eligible</option>
            </select>
          }
        />
      </SettingGroup>

      <SettingGroup title="Providers" sectionHeader hideTitle>
        <SettingRow
          iconGlyph="◇"
          label="Provider"
          description="Choose the daemon provider row to edit."
          control={
            <select value={provider.providerID} disabled={disabled} onChange={(e) => setSelectedProviderID(e.currentTarget.value)}>
              {providers.map((p) => (
                <option key={p.providerID} value={p.providerID}>
                  {providerDisplay(p)}
                </option>
              ))}
            </select>
          }
        />
        <SettingRow
          iconGlyph="●"
          label={`${providerDisplay(provider)} enabled`}
          description="Controls whether this provider is eligible for proxy routing."
          control={
            <button type="button" className="ghost" disabled={disabled} onClick={() => setProviderEnabled(!provider.isEnabled)}>
              {provider.isEnabled ? 'Disable' : 'Enable'}
            </button>
          }
        />
        <form
          className="settings-inline-form"
          onSubmit={(event) => {
            event.preventDefault();
            saveBaseURL(event.currentTarget);
          }}
        >
          <SettingRow
            iconGlyph="↗"
            label="Base URL"
            description="Provider endpoint used by the daemon router."
            control={
              <>
                <input name="baseURL" defaultValue={provider.baseURL} disabled={disabled} aria-label="Provider base URL" />
                <button type="submit" className="ghost" disabled={disabled}>
                  Save
                </button>
              </>
            }
          />
        </form>
      </SettingGroup>

      <SettingGroup title="Credential Slots" sectionHeader hideTitle>
        {provider.credentialSlots.map((slot) => (
          <SettingRow
            key={slot.slotID}
            iconGlyph="🔐"
            label={slot.label}
            description={`Status ${slot.status}${slot.lastQuotaRemainingPercent == null ? '' : ` · ${slot.lastQuotaRemainingPercent}% remaining`}`}
            control={
              <button type="button" className="ghost" disabled={disabled} onClick={() => void removeCredentialSlot(provider.providerID, slot.slotID)}>
                Remove
              </button>
            }
          />
        ))}
        <form
          className="settings-mini-form"
          onSubmit={(event) => {
            event.preventDefault();
            const form = new FormData(event.currentTarget);
            const label = String(form.get('label') ?? '').trim();
            const apiKey = String(form.get('apiKey') ?? '').trim();
            if (!label || !apiKey) return;
            void upsertCredentialSlot({ providerID: provider.providerID, label, apiKey, isEnabled: true });
            event.currentTarget.reset();
          }}
        >
          <input name="label" placeholder="Slot label" disabled={disabled} aria-label="Credential slot label" />
          <input name="apiKey" placeholder="API key" type="password" disabled={disabled} aria-label="Credential API key" />
          <button type="submit" className="ghost" disabled={disabled}>Add slot</button>
        </form>
      </SettingGroup>

      <SettingGroup title="Model Catalog Overrides" sectionHeader hideTitle>
        <p className="muted settings-tab-lede">
          Custom models, aliases, thinking variants, and display names are emitted by the daemon gateway catalog. Secrets are never shown here.
        </p>
        <form
          className="settings-mini-form"
          onSubmit={(event) => {
            event.preventDefault();
            const form = new FormData(event.currentTarget);
            const modelID = String(form.get('modelID') ?? '').trim();
            const displayName = String(form.get('displayName') ?? '').trim();
            if (!modelID) return;
            void upsertCustomModel(provider.providerID, { modelID, displayName });
            event.currentTarget.reset();
          }}
        >
          <input name="modelID" placeholder="custom-model-id" disabled={disabled} aria-label="Custom model ID" />
          <input name="displayName" placeholder="Display name" disabled={disabled} aria-label="Custom model display name" />
          <button type="submit" className="ghost" disabled={disabled}>Add model</button>
        </form>
        {provider.customModels.map((model) => (
          <SettingRow
            key={model.modelID}
            iconGlyph="＋"
            label={model.displayName || model.modelID}
            description={model.modelID}
            control={<button type="button" className="ghost" disabled={disabled} onClick={() => void removeCustomModel(provider.providerID, model.modelID)}>Remove</button>}
          />
        ))}

        <form
          className="settings-mini-form"
          onSubmit={(event) => {
            event.preventDefault();
            const form = new FormData(event.currentTarget);
            const aliasID = String(form.get('aliasID') ?? '').trim();
            const baseModelID = String(form.get('baseModelID') ?? '').trim() || firstWritableModel(provider);
            const displayName = String(form.get('displayName') ?? '').trim();
            if (!aliasID) return;
            void upsertModelAlias(provider.providerID, { aliasID, baseModelID, displayName, hidesBaseModel: false });
            event.currentTarget.reset();
          }}
        >
          <input name="aliasID" placeholder="openburnbar/alias" disabled={disabled} aria-label="Alias ID" />
          <input name="baseModelID" placeholder={firstWritableModel(provider)} disabled={disabled} aria-label="Alias base model" />
          <input name="displayName" placeholder="Alias display name" disabled={disabled} aria-label="Alias display name" />
          <button type="submit" className="ghost" disabled={disabled}>Add alias</button>
        </form>
        {provider.modelAliases.map((alias) => (
          <SettingRow
            key={alias.aliasID}
            iconGlyph="↪"
            label={alias.displayName || alias.aliasID}
            description={`${alias.aliasID} routes to ${alias.baseModelID}`}
            control={<button type="button" className="ghost" disabled={disabled} onClick={() => void removeModelAlias(provider.providerID, alias.aliasID)}>Remove</button>}
          />
        ))}

        <form
          className="settings-mini-form"
          onSubmit={(event) => {
            event.preventDefault();
            const form = new FormData(event.currentTarget);
            const modelID = String(form.get('modelID') ?? '').trim() || firstWritableModel(provider);
            const displayName = String(form.get('displayName') ?? '').trim();
            if (!displayName) return;
            void setDisplayName(provider.providerID, modelID, displayName);
            event.currentTarget.reset();
          }}
        >
          <input name="modelID" placeholder={firstWritableModel(provider)} disabled={disabled} aria-label="Display override model" />
          <input name="displayName" placeholder="Human display name" disabled={disabled} aria-label="Model display override" />
          <button type="submit" className="ghost" disabled={disabled}>Rename</button>
        </form>
        {provider.modelDisplayOverrides.map((override) => (
          <SettingRow
            key={override.modelID}
            iconGlyph="Aa"
            label={override.displayName}
            description={override.modelID}
            control={<button type="button" className="ghost" disabled={disabled} onClick={() => void clearDisplayName(provider.providerID, override.modelID)}>Clear</button>}
          />
        ))}

        <form
          className="settings-mini-form"
          onSubmit={(event) => {
            event.preventDefault();
            const form = new FormData(event.currentTarget);
            const baseModelID = String(form.get('baseModelID') ?? '').trim() || firstWritableModel(provider);
            const thinkingLevel = String(form.get('thinkingLevel') ?? 'xhigh') as 'low' | 'medium' | 'high' | 'xhigh' | 'max';
            const variantID = `${baseModelID}-${thinkingLevel}`;
            void upsertModelVariant(provider.providerID, { variantID, label: thinkingLevel.toUpperCase(), baseModelID, thinkingLevel, maxOutputTokens: null });
          }}
        >
          <input name="baseModelID" placeholder={firstWritableModel(provider)} disabled={disabled} aria-label="Variant base model" />
          <select name="thinkingLevel" disabled={disabled} aria-label="Thinking level" defaultValue="xhigh">
            <option value="low">Low</option>
            <option value="medium">Medium</option>
            <option value="high">High</option>
            <option value="xhigh">XHigh</option>
            <option value="max">Max</option>
          </select>
          <button type="submit" className="ghost" disabled={disabled}>Add variant</button>
        </form>
        {provider.modelVariants.map((variant) => (
          <SettingRow
            key={variant.variantID}
            iconGlyph="↕"
            label={variant.label}
            description={`${variant.variantID} · ${variant.baseModelID}`}
            control={<button type="button" className="ghost" disabled={disabled} onClick={() => void removeModelVariant(provider.providerID, variant.variantID)}>Remove</button>}
          />
        ))}
      </SettingGroup>

      <SettingGroup title="Proxy Route Log" sectionHeader hideTitle>
        <div className="actions">
          <button type="button" className="ghost" disabled={disabled || loadingRouteLog} onClick={() => void loadRouteLog()}>
            {loadingRouteLog ? 'Loading…' : 'Refresh route log'}
          </button>
          <button type="button" className="ghost" disabled={disabled || routeLog.length === 0} onClick={() => void clearRouteLog()}>
            Clear
          </button>
        </div>
        {routeLog.length === 0 ? <p className="muted">No proxy route decisions recorded yet.</p> : null}
        {routeLog.slice(0, 8).map((entry) => (
          <SettingRow
            key={entry.id}
            iconGlyph="⇢"
            label={`${entry.clientModelSlug || 'unknown'} → ${entry.routingModelSlug ?? entry.upstreamModelSlug ?? 'unresolved'}`}
            description={`${entry.finalStatus} · ${entry.rewriteKind} · ${entry.providerName ?? 'No provider'} · ${entry.occurredAt}`}
            control={<span className="muted mono">{entry.httpStatus ?? 'n/a'}</span>}
          />
        ))}
      </SettingGroup>
    </>
  );
}

function NotificationsDetail({ mode }: { mode: 'alerts' | 'notifications' }) {
  const config = useSettingsWiringStore((s) => s.notificationConfig);
  const health = useSettingsWiringStore((s) => s.notificationHealth);
  const result = useSettingsWiringStore((s) => s.notificationCommandResult);
  const loading = useSettingsWiringStore((s) => s.loadingNotifications);
  const busy = useSettingsWiringStore((s) => s.busy);
  const error = useSettingsWiringStore((s) => s.error);
  const load = useSettingsWiringStore((s) => s.loadNotifications);
  const update = useSettingsWiringStore((s) => s.updateNotificationConfig);
  const runCommand = useSettingsWiringStore((s) => s.runNotificationCommand);
  useLaneLoad(load);

  const disabled = Boolean(busy);
  const channels = useMemo(() => new Map((health?.channels ?? []).map((c) => [c.channel, c])), [health]);

  if (loading && !config) return <p className="muted">Loading notification settings…</p>;
  if (!config) {
    return (
      <OfflineNotice
        status={{
          tone: 'warn',
          label: 'Notifications unavailable',
          detail: error ?? 'Packaged shell required for notification settings.',
          ok: false
        }}
        summary="Notifications need the local daemon notification RPCs."
        fixtureMode={false}
      />
    );
  }

  const patch = (mutate: (current: NotificationConfig) => NotificationConfig) => {
    void update(mutate(JSON.parse(JSON.stringify(config)) as NotificationConfig));
  };

  return (
    <>
      {error ? <Banner tone="degraded" role="alert">{error}</Banner> : null}
      {result ? <Banner tone={result.ok ? 'ok' : 'degraded'} role="status">{result.message}</Banner> : null}
      <SettingGroup title={mode === 'alerts' ? 'Alerts' : 'Notifications'} sectionHeader hideTitle>
        <SettingRow
          iconGlyph="◉"
          label="Default snooze"
          description="Minutes used by notification followup snooze actions."
          control={
            <input
              type="number"
              min={1}
              max={1440}
              value={config.defaultSnoozeMinutes}
              disabled={disabled}
              aria-label="Default snooze minutes"
              onChange={(e) => patch((c) => ({ ...c, defaultSnoozeMinutes: Number(e.currentTarget.value) }))}
            />
          }
        />
        <SettingRow
          iconGlyph="⏱"
          label="Nudge hours"
          description="Local hours when digest nudges are allowed."
          control={
            <input
              value={config.nudgeHoursLocal.join(',')}
              disabled={disabled}
              aria-label="Nudge hours"
              onChange={(e) =>
                patch((c) => ({
                  ...c,
                  nudgeHoursLocal: e.currentTarget.value.split(',').map((v) => Number(v.trim())).filter((v) => Number.isFinite(v) && v >= 0 && v <= 23)
                }))
              }
            />
          }
        />
      </SettingGroup>
      <SettingGroup title="Channels" sectionHeader hideTitle>
        <SettingRow
          iconGlyph="◈"
          label="Local notifications"
          description={`Health: ${channels.get('local')?.status ?? 'unknown'}`}
          control={<button type="button" className="ghost" disabled={disabled} onClick={() => patch((c) => ({ ...c, local: { ...c.local, isEnabled: !c.local.isEnabled } }))}>{config.local.isEnabled ? 'Disable' : 'Enable'}</button>}
        />
        <SettingRow
          iconGlyph="✈"
          label="Telegram"
          description={`Health: ${channels.get('telegram')?.status ?? 'unknown'} · Token ${config.telegram.botTokenConfigured ? config.telegram.botTokenHint ?? 'configured' : 'not configured'}`}
          control={<button type="button" className="ghost" disabled={disabled} onClick={() => patch((c) => ({ ...c, telegram: { ...c.telegram, isEnabled: !c.telegram.isEnabled } }))}>{config.telegram.isEnabled ? 'Disable' : 'Enable'}</button>}
        />
        <form
          className="settings-mini-form"
          onSubmit={(event) => {
            event.preventDefault();
            const form = new FormData(event.currentTarget);
            const botToken = String(form.get('botToken') ?? '').trim();
            const chatID = String(form.get('chatID') ?? '').trim();
            patch((c) => ({
              ...c,
              telegram: {
                ...c.telegram,
                botToken: botToken || undefined,
                botTokenConfigured: botToken ? true : c.telegram.botTokenConfigured,
                chatID: chatID || c.telegram.chatID
              }
            }));
            event.currentTarget.reset();
          }}
        >
          <input name="botToken" type="password" placeholder="Bot token" disabled={disabled} aria-label="Telegram bot token" />
          <input name="chatID" placeholder={config.telegram.chatID ?? 'Chat ID'} disabled={disabled} aria-label="Telegram chat ID" />
          <button type="submit" className="ghost" disabled={disabled}>Save Telegram</button>
        </form>
        <SettingRow
          iconGlyph="□"
          label="Calendar"
          description={`Health: ${channels.get('calendar')?.status ?? 'unknown'} · Default ${config.calendar.defaultDurationMinutes}m`}
          control={<button type="button" className="ghost" disabled={disabled} onClick={() => patch((c) => ({ ...c, calendar: { ...c.calendar, isEnabled: !c.calendar.isEnabled } }))}>{config.calendar.isEnabled ? 'Disable' : 'Enable'}</button>}
        />
      </SettingGroup>
      <SettingGroup title="Commands" sectionHeader hideTitle>
        <div className="actions">
          {['status', 'pending', 'followups', 'latest'].map((command) => (
            <button key={command} type="button" className="ghost" disabled={disabled} onClick={() => void runCommand(command)}>
              {command}
            </button>
          ))}
        </div>
      </SettingGroup>
    </>
  );
}

type DeviceSyncAction = 'refresh' | 'sign-out' | 'rotate-identity' | null;

function accountPostureCopy(status: AccountStatus | null, loading: boolean, error: string | null): string {
  if (loading) return 'Checking daemon-owned account and enrollment posture…';
  if (error) return `Account posture unavailable: ${error}`;
  if (!status) return 'Account posture has not been loaded.';
  if (status.state === 'unavailable') {
    return status.detail === 'device_rejected'
      ? 'This installation was rejected; replace its identity before requesting approval again.'
      : 'Cloud account services are unavailable; local SQLite remains canonical.';
  }
  if (status.state === 'awaiting-device-approval' || status.deviceApprovalRequired) {
    return 'This installation is enrolled and waiting for approval from a trusted OpenBurnBar device.';
  }
  if (status.signedIn) return `Signed in as ${status.identityLabel ?? 'Linux identity'}; cloud sync is ${status.syncState}.`;
  return 'Signed out; local-first mode remains available.';
}

function DevicesAndSyncDetail({
  config,
  fixtureMode,
  bridge,
  onSelectTab
}: {
  config: ConfigSnapshot;
  fixtureMode: boolean;
  bridge: LinuxShellBridge | null;
  onSelectTab: (tab: SettingsTabId) => void;
}) {
  const [account, setAccount] = useState<AccountStatus | null>(null);
  const [loading, setLoading] = useState(false);
  const [action, setAction] = useState<DeviceSyncAction>(null);
  const [error, setError] = useState<string | null>(null);

  const loadAccountPosture = async (requestedAction: DeviceSyncAction = 'refresh') => {
    if (action !== null) return;
    setLoading(true);
    setAction(requestedAction);
    setError(null);
    try {
      const next = fixtureMode
        ? fixtureAccountStatus()
        : bridge
          ? await bridge.accountStatus()
          : null;
      if (!next) throw new Error('Packaged shell required for live account posture.');
      setAccount(next);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Account status request failed.');
    } finally {
      setLoading(false);
      setAction(null);
    }
  };

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    const request = fixtureMode
      ? Promise.resolve(fixtureAccountStatus())
      : bridge
        ? bridge.accountStatus()
        : Promise.reject(new Error('Packaged shell required for live account posture.'));
    void request
      .then((next) => {
        if (!cancelled) setAccount(next);
      })
      .catch((cause: unknown) => {
        if (!cancelled) setError(cause instanceof Error ? cause.message : 'Account status request failed.');
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [fixtureMode, bridge]);

  const runAccountMutation = async (kind: Exclude<DeviceSyncAction, 'refresh' | null>) => {
    if (action !== null || fixtureMode || !bridge) return;
    setAction(kind);
    setError(null);
    try {
      const next = kind === 'sign-out'
        ? await bridge.accountSignOut()
        : await bridge.accountRotateIdentity();
      setAccount(next);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Account mutation failed.');
    } finally {
      setAction(null);
    }
  };

  const rejected = account?.detail === 'device_rejected';
  const awaitingApproval = account?.state === 'awaiting-device-approval' || account?.deviceApprovalRequired;
  const statusText = accountPostureCopy(account, loading, error);

  return (
    <>
      {error ? <Banner tone="degraded" role="alert">{error}</Banner> : null}
      <SettingGroup title="Devices & Sync" sectionHeader hideTitle>
        <p className="muted settings-tab-lede">
          Account and enrollment posture comes from the daemon&apos;s authenticated account RPC. Secrets stay in the native
          Secret Service; local SQLite remains canonical while cloud sync is unavailable.
        </p>
        <SettingRow
          iconGlyph="⊞"
          label="Cloud sync source"
          description={`Provider rows: ${(config.providers ?? []).length}. ${statusText}`}
          control={<button type="button" className="ghost" onClick={() => onSelectTab('account')}>Open Account</button>}
        />
        <SettingRow
          iconGlyph="⛨"
          label="Secret Service"
          description="Cloud credentials require unlocked GNOME Keyring/KWallet before sync credentials can be saved."
          control={<span className="muted">{config.secretServiceStatus}</span>}
        />
        {account?.installationDeviceID ? (
          <SettingRow
            iconGlyph="⌘"
            label="Linux installation identity"
            description={awaitingApproval ? 'Approval is required on a trusted OpenBurnBar device.' : 'Daemon-owned identity used for cloud enrollment.'}
            control={
              <span className="settings-verification-value">
                <code className="mono">{account.installationDeviceID}</code>
                <CopyPathButton path={account.installationDeviceID} label="Copy device ID" />
              </span>
            }
          />
        ) : null}
        {account?.installationSafetyFingerprint ? (
          <SettingRow
            iconGlyph="#"
            label="Safety fingerprint"
            description="Compare this value on the approving device before trusting the installation."
            control={
              <span className="settings-verification-value">
                <code className="mono">{account.installationSafetyFingerprint}</code>
                <CopyPathButton path={account.installationSafetyFingerprint} label="Copy fingerprint" />
              </span>
            }
          />
        ) : null}
        <div className="actions">
          <button type="button" className="ghost" disabled={loading || action !== null} onClick={() => void loadAccountPosture()}>
            {action === 'refresh' ? 'Checking…' : 'Check account posture'}
          </button>
          {account?.signedIn ? (
            <button type="button" className="ghost" disabled={action !== null || fixtureMode} onClick={() => void runAccountMutation('sign-out')}>
              {action === 'sign-out' ? 'Signing out…' : 'Sign out'}
            </button>
          ) : null}
          {rejected ? (
            <button type="button" className="danger" disabled={action !== null || fixtureMode} onClick={() => void runAccountMutation('rotate-identity')}>
              {action === 'rotate-identity' ? 'Replacing identity…' : 'Replace rejected identity'}
            </button>
          ) : null}
        </div>
        <p className="muted settings-tab-lede">
          Trusted-device approval and revoke remain unavailable here because the daemon exposes no Linux mutation contract
          for those cloud callables. The pending/rejected state is shown fail-closed instead of presenting a fixture device.
        </p>
      </SettingGroup>
    </>
  );
}

function MediaDetail() {
  return (
    <SettingGroup title="Media & Sharing" sectionHeader hideTitle>
      <p className="muted settings-tab-lede">
        Mercury media is gated outside the settings RPC surface for this lane. File transfer, screen share, and calls need the media packet/runtime lane before Linux Settings can expose mutation controls.
      </p>
      <SettingRow
        iconGlyph="▣"
        label="Media engine gate"
        description="No daemon settings RPC exists here; this pane intentionally does not invent packet controls."
        control={<span className="muted">Blocked by media runtime lane</span>}
      />
    </SettingGroup>
  );
}

export function SettingsDetailPane({
  activeTab,
  config,
  fixtureMode,
  bridge,
  status,
  loading,
  error,
  onRetryConfig,
  onRefreshConfig,
  refreshBusy,
  onDone,
  onSelectTab
}: {
  activeTab: SettingsTabId;
  config: ConfigSnapshot | null;
  fixtureMode: boolean;
  bridge: unknown;
  status: DaemonStatusCopy;
  loading: boolean;
  error: string | null;
  onRetryConfig: () => void;
  onRefreshConfig: () => void;
  refreshBusy: boolean;
  onDone: () => void;
  onSelectTab: (tab: SettingsTabId) => void;
}) {
  const meta = settingsTabMeta(activeTab);

  const providerRegistryRows = useMemo(() => {
    // Browser/test env may lack process.env; fall back to logical-only display.
    const env =
      typeof process !== 'undefined'
        ? {
            XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME,
            XDG_DATA_HOME: process.env.XDG_DATA_HOME
          }
        : {};
    const home =
      typeof process !== 'undefined' && process.env.HOME
        ? process.env.HOME
        : '~';
    return LINUX_PROVIDER_PATH_REGISTRY.map((row) => ({
      ...row,
      resolvedHint:
        home === '~'
          ? undefined
          : resolveProviderLogicalPath(row.logicalPath, home, env)
    }));
  }, []);

  let content: ReactNode = null;

  if (activeTab === 'home') {
    content = (
      <SettingsHomeView
        config={config}
        status={status}
        fixtureMode={fixtureMode}
        onSelectTab={onSelectTab}
      />
    );
  } else if (!config && loading) {
    content = <p className="muted">Loading settings…</p>;
  } else if (!config) {
    const offline = !fixtureMode && !bridge && !loading;
    content = offline ? (
      <OfflineNotice
        status={status}
        summary="Settings need the local daemon before paths, Secret Service, and privacy flags can load."
        fixtureMode={fixtureMode}
      />
    ) : (
      <Banner tone="degraded" role="alert">
        {error ?? 'Config unavailable'}
        <div className="actions">
          <button type="button" className="ghost" onClick={onRetryConfig}>
            Retry
          </button>
        </div>
      </Banner>
    );
  } else {
    const secretLocked =
      config.secretServiceStatus === 'locked' || config.secretServiceStatus === 'unavailable';

    switch (activeTab) {
      case 'general':
        content = (
          <>
            <SettingGroup title="Appearance" sectionHeader hideTitle>
              <SettingsAppearanceControls />
            </SettingGroup>
            <SettingGroup title="Data refresh" sectionHeader hideTitle>
              <ConfigRefreshRow onRefresh={onRefreshConfig} busy={refreshBusy} />
            </SettingGroup>
            <SettingGroup title="First-run setup" sectionHeader hideTitle>
              <p className="muted settings-tab-lede">
                Linux onboarding wizard for daemon, Secret Service, and desktop environment limits.
              </p>
              <OnboardingSurface />
            </SettingGroup>
          </>
        );
        break;
      case 'updates':
        content = <UpdatesDetail fixtureMode={fixtureMode} status={status} />;
        break;
      case 'daemon':
        content = (
          <SettingGroup title="Engine Room" sectionHeader hideTitle>
            <p className="muted settings-tab-lede">
              Local peer health, AF_UNIX RPC, and Secret Service status.
            </p>
            <SettingRow
              iconGlyph="⎔"
              label="AF_UNIX socket"
              description="Local health and RPC traffic; never expose this socket outside your user session."
              control={<CopyPathButton path={config.paths.socketPath} label="Copy socket path" />}
            />
            <p className="system-path-row">
              <code>{config.paths.socketPath}</code>
            </p>
            <SettingRow
              iconGlyph="📁"
              label="Support directory (XDG data)"
              description="Canonical state and logs live here (~/.local/share/openburnbar). Legacy ~/.config/OpenBurnBar: set OPENBURNBAR_DAEMON_SUPPORT_DIR or move the tree."
              control={<CopyPathButton path={config.paths.supportDir} />}
            />
            <p className="system-path-row">
              <code>{config.paths.supportDir}</code>
            </p>
            <SettingRow
              iconGlyph="⚙"
              label="Config directory (XDG config)"
              description="Daemon-managed configuration."
              control={<CopyPathButton path={config.paths.configDir} />}
            />
            <p className="system-path-row">
              <code>{config.paths.configDir}</code>
            </p>
            <SettingRow
              iconGlyph="∑"
              label="Usage ingestion coverage"
              description="The catalog mirrors all canonical providers and labels local parser, API-backed, and unavailable sources separately."
              control={<span className="muted" role="status">{providerCoverageSummary()}</span>}
            />
            {/* VAL-PARSER-002: the catalog is the source of truth for display paths and coverage. */}
            {providerRegistryRows.map((row) => (
              <div key={row.providerId}>
                <SettingRow
                  iconGlyph="📄"
                  label={`${row.displayLabel} log path`}
                  description={`${providerCoverageLabel(row.coverage)} · ${row.coverageNote} · pattern ${row.filePattern}`}
                  control={<CopyPathButton path={row.logicalPath} label="Copy log path" />}
                />
                <p className="system-path-row">
                  <code>{row.logicalPath}</code>
                  {' '}
                  <span className={`provider-coverage provider-coverage--${row.coverage}`} data-provider-coverage={row.coverage}>
                    {providerCoverageLabel(row.coverage)}
                  </span>
                  {row.resolvedHint ? (
                    <>
                      {' '}
                      → <code>{row.resolvedHint}</code>
                    </>
                  ) : null}
                </p>
              </div>
            ))}
            {config.paths.providerLogPaths.length > 0 &&
            !config.paths.providerLogPaths.every((p) =>
              providerRegistryRows.some((r) => r.logicalPath === p)
            )
              ? config.paths.providerLogPaths
                  .filter((p) => !providerRegistryRows.some((r) => r.logicalPath === p))
                  .map((logPath) => (
                    <div key={`extra-${logPath}`}>
                      <SettingRow
                        iconGlyph="📄"
                        label="Daemon-reported log path"
                        description="Additional path from daemon config snapshot."
                        control={<CopyPathButton path={logPath} label="Copy log path" />}
                      />
                      <p className="system-path-row">
                        <code>{logPath}</code>
                      </p>
                    </div>
                  ))
              : null}
            <SettingRow
              iconGlyph="🔐"
              label="GNOME Keyring / KWallet"
              description={
                secretLocked
                  ? 'Unlock your desktop keyring so provider credentials can be stored without plain-text files.'
                  : 'Secret Service is reachable; credentials stay off disk when unlocked.'
              }
              control={
                <span className="muted" role="status">
                  {config.secretServiceStatus}
                </span>
              }
            />
          </SettingGroup>
        );
        break;
      case 'agents':
        content = <AgentsDetail config={config} />;
        break;
      case 'model-proxy':
        content = <AgentsDetail config={config} />;
        break;
      case 'account':
        content = (
          <SettingGroup title="Account" sectionHeader hideTitle>
            <SettingsDrillRow
              as="div"
              iconGlyph="◎"
              iconTint="var(--color-brass-bright)"
              title="Account & cloud"
              subtitle="BurnBar session, entitlements, and optional cloud mirror"
              trailing={
                <a className="system-danger-link settings-drill-link" href="#/account">
                  Open Account
                </a>
              }
            />
          </SettingGroup>
        );
        break;
      case 'cloud':
        content = (
          <SettingGroup title="Cloud" sectionHeader hideTitle>
            <p className="muted settings-tab-lede">
              OpenBurnBar Cloud — hosted refresh, backup, and Hermes anywhere — is managed from the Account lane on
              Linux until cloud store RPCs ship in Settings.
            </p>
            <SettingsDrillRow
              as="div"
              iconGlyph="✦"
              iconTint="var(--color-brass-bright)"
              title="OpenBurnBar Cloud"
              subtitle="Subscription and hosted services"
              trailing={
                <a className="system-danger-link settings-drill-link" href="#/account">
                  Account
                </a>
              }
            />
          </SettingGroup>
        );
        break;
      case 'alerts':
      case 'notifications':
        content = <NotificationsDetail mode={activeTab} />;
        break;
      case 'devices-and-sync':
        content = (
          <DevicesAndSyncDetail
            config={config}
            fixtureMode={fixtureMode}
            bridge={bridge as LinuxShellBridge | null}
            onSelectTab={onSelectTab}
          />
        );
        break;
      case 'media':
        content = <MediaDetail />;
        break;
      case 'computer-use':
        content = (
          <SettingGroup title="Computer Use" sectionHeader hideTitle>
            <p className="muted settings-tab-lede">
              Browser automation remains approval-gated by the daemon. Open the dedicated surface for live session state,
              pending approvals, panic halt, and audit export.
            </p>
            <SettingRow
              iconGlyph="⌁"
              label="Computer Use control surface"
              description="No Linux system-mode controls are shown until the compositor and portal capability is verified."
              control={<a className="system-danger-link settings-drill-link" href="#/computer-use">Open Computer Use</a>}
            />
          </SettingGroup>
        );
        break;
      case 'pets':
        content = (
          <SettingGroup title="Pets" sectionHeader hideTitle>
            <p className="muted settings-tab-lede">
              The companion uses a contained draggable surface when compositor pass-through is unavailable. Open the
              dedicated route to inspect the current asset and capability tier.
            </p>
            <SettingRow
              iconGlyph="✧"
              label="Pet companion"
              description="Linux keeps the fallback visible and honest instead of claiming a click-through overlay."
              control={<a className="system-danger-link settings-drill-link" href="#/pet">Open Pets</a>}
            />
          </SettingGroup>
        );
        break;
      case 'text-expansion':
        content = (
          <div className="settings-embedded-surface">
            <TextExpansionSurface />
          </div>
        );
        break;
      case 'data-privacy':
        content = (
          <>
            <SettingGroup title="Consent flags" sectionHeader hideTitle>
              <SettingRow
                iconGlyph="📡"
                label="Telemetry"
                description="Opt-in only. When enabled, the daemon may emit anonymized stability events — never prompt content."
                control={<ReadOnlyToggle checked={config.telemetryEnabled} label="Telemetry" />}
                readOnlyNote="Managed by daemon config"
              />
              <SettingRow
                iconGlyph="🛡"
                label="Privacy opt-in"
                description="Explicit consent before cloud-adjacent features sync metadata off this machine."
                control={<ReadOnlyToggle checked={config.privacyOptIn} label="Privacy opt-in" />}
                readOnlyNote="Managed by daemon config"
              />
            </SettingGroup>
            <SettingGroup title="Diagnostics" sectionHeader hideTitle>
              <SettingsDrillRow
                as="div"
                iconGlyph="⚠"
                iconTint="var(--color-tier-server-readable)"
                title="Support & diagnostics"
                subtitle="Export redacted logs and perf samples"
                trailing={
                  <a className="system-danger-link settings-drill-link" href="#/support">
                    Support
                  </a>
                }
              />
            </SettingGroup>
          </>
        );
        break;
      default:
        content = null;
    }
  }

  return (
    <div className="settings-detail" role="region" aria-label={meta.detailTitle}>
      <SettingsDetailHeader title={meta.detailTitle} onDone={onDone} />
      <div className="settings-detail-scroll">{content}</div>
    </div>
  );
}
