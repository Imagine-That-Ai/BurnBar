import { useState } from 'react';
import { PROXY_ROUTE_FINAL_STATUS_COPY } from '../../tauriBridge.js';
import type { ConfigSnapshot, ProviderSettings } from '../../tauriBridge.js';
import { Banner } from '../../components/Banner.js';
import { useSettingsWiringStore } from '../../state/settingsWiringStore.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useShellStore } from '../../state/shellStore.js';
import { SettingGroup } from './SettingGroup.js';
import { SettingRow } from './SettingRow.js';

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

export function AgentsDetail({ config, fixtureMode }: { config: ConfigSnapshot; fixtureMode: boolean }) {
  const providers = config.providers ?? [];
  const [selectedProviderID, setSelectedProviderID] = useState(providers[0]?.providerID ?? '');
  const health = useShellStore((s) => s.health);
  const configUpdate = useShellStore((s) => s.bridge?.configUpdate);
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
  const canWriteConfig = fixtureMode || typeof configUpdate === 'function';
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
  const setPreferredCredentialSlot = (slotID: string) => {
    if (disabled || !canWriteConfig) return;
    void replaceSnapshot(updateProviderSnapshot(config, provider.providerID, (current) => {
      const next = { ...current };
      if (slotID) {
        next.preferredCredentialSlotID = slotID;
      } else {
        // Omission is the daemon contract for automatic credential routing;
        // sending null would be ambiguous to older packaged peers.
        delete next.preferredCredentialSlotID;
      }
      return next;
    }));
  };
  const credentialSlots = provider.credentialSlots ?? [];
  const preferredSlotID = provider.preferredCredentialSlotID ?? '';
  const preferredSlotExists = credentialSlots.some((slot) => slot.slotID === preferredSlotID);
  const preferredSlotDisabled = disabled || !canWriteConfig;

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
            <select value={config.routerMode ?? 'provider_family_failover'} disabled={disabled} onChange={(e) => setRouterMode(e.currentTarget.value)}>
              <option value="provider_family_failover">Stay inside one provider</option>
              <option value="same_model_failover">Exact model failover</option>
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
        <SettingRow
          iconGlyph="⇄"
          label="Preferred account"
          description="Pin a credential slot for this provider, or let the daemon choose the healthiest eligible slot automatically. Secrets are never shown."
          readOnlyNote={!canWriteConfig && !fixtureMode ? 'Packaged shell config.update is unavailable; account routing is read-only.' : undefined}
          control={
            <span className="settings-verification-value">
              <select
                value={preferredSlotID}
                disabled={preferredSlotDisabled}
                aria-label="Preferred credential slot"
                onChange={(event) => setPreferredCredentialSlot(event.currentTarget.value)}
              >
                <option value="">Auto (daemon routing)</option>
                {preferredSlotID && !preferredSlotExists ? (
                  <option value={preferredSlotID} disabled>
                    Current slot unavailable ({preferredSlotID})
                  </option>
                ) : null}
                {credentialSlots.map((slot) => (
                  <option key={slot.slotID} value={slot.slotID}>
                    {slot.label} · {slot.status}
                  </option>
                ))}
              </select>
              <button
                type="button"
                className="ghost"
                disabled={preferredSlotDisabled || preferredSlotID === ''}
                onClick={() => setPreferredCredentialSlot('')}
              >
                Use auto routing
              </button>
            </span>
          }
        />
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
            description={`${PROXY_ROUTE_FINAL_STATUS_COPY[entry.finalStatus]}${entry.streamInterrupted ? ' · stream interrupted' : ''} · ${entry.rewriteKind} · ${entry.providerName ?? 'No provider'} · ${entry.occurredAt}`}
            control={<span className="muted mono">{entry.httpStatus ?? 'n/a'}</span>}
          />
        ))}
      </SettingGroup>
    </>
  );
}
