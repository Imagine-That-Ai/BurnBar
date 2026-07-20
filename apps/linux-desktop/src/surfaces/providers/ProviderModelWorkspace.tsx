import { useEffect, useRef, useState } from 'react';
import { providerRouteHash, providerSelectionFromHash } from '../../routes.js';
import type { CustomModel, ProviderCatalog, ProviderCatalogEntry, ProviderCatalogModel, ProviderHealthState } from '../../tauriBridge.js';
import { useProvidersStore } from '../../state/providersStore.js';
import { useShellStore } from '../../state/shellStore.js';
import './provider-model-workspace.css';

const HEALTH_LABEL: Record<ProviderHealthState, string> = {
  healthy: 'Healthy',
  degraded: 'Degraded',
  unavailable: 'Unavailable',
  unknown: 'Status unavailable'
};

function modelRouteLabel(model: ProviderCatalogModel): string {
  if (model.health === 'unavailable') return 'Unavailable';
  if (model.health === 'degraded') return 'Degraded';
  if (model.health === 'unknown') return 'Status unavailable';
  return model.enabled ? 'Route ready' : 'Disabled';
}

function ModelRow({
  providerID,
  model,
  disabled,
  onRemoveCustomModel,
  deepLinked,
  rowRef
}: {
  providerID: string;
  model: ProviderCatalogModel;
  disabled: boolean;
  onRemoveCustomModel: (providerID: string, modelID: string) => void;
  deepLinked: boolean;
  rowRef: (node: HTMLLIElement | null) => void;
}) {
  return (
    <li
      className="provider-model-row"
      data-model={model.id}
      data-deep-linked={deepLinked || undefined}
      tabIndex={-1}
      ref={rowRef}
    >
      <div className="provider-model-row-heading">
        <div>
          <strong>{model.label}</strong>
          <code>{model.id}</code>
        </div>
        <div className="provider-model-row-actions">
          <span className="provider-model-status" data-state={model.enabled ? model.health : 'disabled'}>
            {modelRouteLabel(model)}
          </span>
          {model.provenance === 'custom-model' ? (
            <button
              type="button"
              className="ghost"
              disabled={disabled}
              onClick={() => onRemoveCustomModel(providerID, model.id)}
              aria-label={`Remove custom model ${model.label}`}
            >
              Remove
            </button>
          ) : null}
        </div>
      </div>
      {model.aliases.length > 0 ? (
        <p className="provider-model-detail">Aliases: <code>{model.aliases.join(', ')}</code></p>
      ) : null}
      <p className="provider-model-detail">
        Source: <strong>{model.provenance.replaceAll('-', ' ')}</strong>
        {model.detail ? ` · ${model.detail}` : ''}
      </p>
    </li>
  );
}

function ProviderCard({
  provider,
  mutationBusy,
  onRemoveCustomModel,
  onPreferredCredentialSlot,
  routingWritable,
  deepLinkedModelID,
  modelRowRef
}: {
  provider: ProviderCatalogEntry;
  mutationBusy: string | null;
  onRemoveCustomModel: (providerID: string, modelID: string) => void;
  onPreferredCredentialSlot: (providerID: string, slotID: string) => void;
  routingWritable: boolean;
  deepLinkedModelID: string | null;
  modelRowRef: (modelID: string, node: HTMLLIElement | null) => void;
}) {
  const models = provider.models ?? [];
  const health = provider.health ?? 'unknown';
  const failover = provider.failover;
  const credentialSlots = provider.credentialSlots ?? [];
  const preferredSlotID = provider.preferredCredentialSlotID ?? '';
  const preferredSlotExists = credentialSlots.some((slot) => slot.slotID === preferredSlotID);
  const routingBusy = mutationBusy?.startsWith(`provider.preferred_account:${provider.id}`) ?? false;
  return (
    <article className="provider-model-card" data-provider={provider.id}>
      <header className="provider-model-card-header">
        <div>
          <p className="provider-model-eyebrow">{provider.provenance ?? 'daemon-config'}</p>
          <h3>{provider.label}</h3>
          <p className="provider-model-account">{provider.accountLabel}</p>
        </div>
        <span className="provider-model-health" data-state={health}>{HEALTH_LABEL[health]}</span>
      </header>
      {credentialSlots.length > 0 ? (
        <label className="provider-routing-control">
          <span>Routing account</span>
          <select
            value={preferredSlotID}
            disabled={mutationBusy != null || !routingWritable}
            aria-label={`${provider.label} preferred account`}
            aria-busy={routingBusy}
            onChange={(event) => onPreferredCredentialSlot(provider.id, event.currentTarget.value)}
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
          {!routingWritable ? <small>Read-only until daemon config mutation is available.</small> : null}
        </label>
      ) : (
        <p className="provider-routing-unavailable" role="status">
          No credential slots were advertised; account routing is unavailable for this provider.
        </p>
      )}
      <dl className="provider-model-meta">
        <div><dt>Provider ID</dt><dd><code>{provider.id}</code></dd></div>
        <div><dt>Failover</dt><dd>{failover?.eligible ? 'Eligible' : 'Unavailable'}</dd></div>
        <div><dt>Mode</dt><dd>{failover?.mode ?? 'Unknown'}</dd></div>
      </dl>
      {provider.capabilities && provider.capabilities.length > 0 ? (
        <ul className="provider-capability-list" aria-label={`${provider.label} capabilities`}>
          {provider.capabilities.map((capability) => <li key={capability}>{capability.replaceAll('_', ' ')}</li>)}
        </ul>
      ) : <p className="provider-model-detail">No provider capabilities were advertised by the daemon.</p>}
      <p className="provider-model-detail" role="status">
        {failover?.detail ?? 'Route health is not available yet.'}
      </p>
      {models.length > 0 ? (
        <ul className="provider-model-list" aria-label={`${provider.label} model catalog`}>
          {models.map((model) => (
            <ModelRow
              key={`${provider.id}:${model.id}`}
              providerID={provider.id}
              model={model}
              disabled={mutationBusy != null}
              onRemoveCustomModel={onRemoveCustomModel}
              deepLinked={model.id === deepLinkedModelID}
              rowRef={(node) => modelRowRef(model.id, node)}
            />
          ))}
        </ul>
      ) : (
        <p className="provider-model-empty" role="status">
          {provider.catalogAvailable === false
            ? provider.catalogError ?? 'The daemon did not return a verified model catalog.'
            : 'No model entries returned for this provider.'}
        </p>
      )}
    </article>
  );
}

/** Provider/model deep-dive surface backed only by daemon catalog/config data. */
export function ProviderModelWorkspace({ providers }: { providers: ProviderCatalog }) {
  const loading = useProvidersStore((state) => state.loading);
  const catalogError = useProvidersStore((state) => state.error);
  const mutationBusy = useProvidersStore((state) => state.mutationBusy);
  const mutationError = useProvidersStore((state) => state.mutationError);
  const addCustomModel = useProvidersStore((state) => state.addCustomModel);
  const removeCustomModel = useProvidersStore((state) => state.removeCustomModel);
  const setPreferredCredentialSlot = useProvidersStore((state) => state.setPreferredCredentialSlot);
  const load = useProvidersStore((state) => state.load);
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const bridge = useShellStore((state) => state.bridge);
  const initialSelection = providerSelectionFromHash(location.hash);
  const [selectedProviderID, setSelectedProviderID] = useState(
    initialSelection?.providerID ?? providers[0]?.id ?? ''
  );
  const [deepLinkedModelID, setDeepLinkedModelID] = useState(initialSelection?.modelID ?? null);
  const modelRows = useRef(new Map<string, HTMLLIElement>());
  useEffect(() => {
    const syncSelectionFromHash = () => {
      const selection = providerSelectionFromHash(location.hash);
      if (!selection) return;
      setSelectedProviderID(selection.providerID);
      setDeepLinkedModelID(selection.modelID);
    };
    window.addEventListener('hashchange', syncSelectionFromHash);
    return () => window.removeEventListener('hashchange', syncSelectionFromHash);
  }, []);
  useEffect(() => {
    // Catalog refreshes can remove or reorder providers. Never leave the
    // mutation form pointing at a provider ID that is no longer present.
    setSelectedProviderID((current) => {
      if (providers.some((provider) => provider.id === current)) return current;
      return providers[0]?.id ?? '';
    });
  }, [providers]);
  useEffect(() => {
    if (!deepLinkedModelID) return;
    const row = modelRows.current.get(deepLinkedModelID);
    if (!row) return;
    row.scrollIntoView({ block: 'nearest' });
    row.focus({ preventScroll: true });
  }, [deepLinkedModelID, selectedProviderID, providers]);
  const modelCount = providers.reduce((count, provider) => count + (provider.models?.length ?? 0), 0);
  const catalogUnavailable = providers.some((provider) => provider.catalogAvailable === false);
  const routingWritable = fixtureMode || typeof bridge?.configUpdate === 'function';
  const selectedProvider = providers.find((provider) => provider.id === selectedProviderID) ?? providers[0];
  return (
    <section className="provider-model-workspace" aria-labelledby="provider-model-workspace-heading">
      <header className="provider-model-workspace-header">
        <div>
          <p className="provider-model-eyebrow">MODEL WORKSPACE</p>
          <h2 id="provider-model-workspace-heading">Providers &amp; models</h2>
          <p className="provider-model-lede">Review daemon-advertised routes, health, failover eligibility, and model provenance.</p>
        </div>
        <div className="provider-model-actions">
          <span aria-live="polite">{providers.length} providers · {modelCount} models</span>
          <label className="provider-model-provider-picker">
            <span>Provider detail</span>
            <select
              value={selectedProvider?.id ?? ''}
              onChange={(event) => {
                const providerID = event.currentTarget.value;
                setSelectedProviderID(providerID);
                setDeepLinkedModelID(null);
                location.hash = providerRouteHash(providerID);
              }}
              disabled={providers.length === 0}
              aria-label="Provider detail"
            >
              {providers.map((provider) => (
                <option key={provider.id} value={provider.id}>{provider.label}</option>
              ))}
            </select>
          </label>
          <button type="button" className="ghost" onClick={() => void load()} disabled={loading} aria-busy={loading}>
            {loading ? 'Refreshing…' : 'Refresh catalog'}
          </button>
        </div>
      </header>
      {catalogError ? (
        <div className="provider-model-degraded" role="status" aria-live="polite">
          <span>Live provider catalog is unavailable. Showing the last available catalog.</span>
          <button type="button" className="ghost" onClick={() => void load()} disabled={loading} aria-busy={loading}>
            {loading ? 'Retrying…' : 'Retry catalog'}
          </button>
        </div>
      ) : null}
      <form
        className="provider-custom-model-form"
        onSubmit={(event) => {
          event.preventDefault();
          const form = new FormData(event.currentTarget);
          const providerID = String(form.get('providerID') ?? '').trim();
          const modelID = String(form.get('modelID') ?? '').trim();
          const displayName = String(form.get('displayName') ?? '').trim();
          if (!providerID || !modelID) return;
          const customModel: CustomModel = { modelID, displayName: displayName || modelID };
          void addCustomModel(providerID, customModel);
          event.currentTarget.reset();
        }}
      >
        <div>
          <p className="provider-model-eyebrow">CUSTOM MODEL</p>
          <strong>Add a provider model outside the bundled catalog</strong>
        </div>
        <label>
          <span>Provider</span>
          <select
            name="providerID"
            value={selectedProviderID}
            onChange={(event) => setSelectedProviderID(event.currentTarget.value)}
            disabled={mutationBusy != null}
            aria-label="Custom model provider"
          >
            {providers.map((provider) => <option key={provider.id} value={provider.id}>{provider.label}</option>)}
          </select>
        </label>
        <label>
          <span>Model ID</span>
          <input name="modelID" required placeholder="vendor/model-id" disabled={mutationBusy != null} aria-label="Custom model ID" />
        </label>
        <label>
          <span>Display name</span>
          <input name="displayName" placeholder="Optional label" disabled={mutationBusy != null} aria-label="Custom model display name" />
        </label>
        <button type="submit" className="ghost" disabled={mutationBusy != null || providers.length === 0} aria-busy={mutationBusy != null}>
          {mutationBusy?.includes('.upsert:') ? 'Adding…' : 'Add model'}
        </button>
      </form>
      {mutationError ? <p className="provider-model-mutation-error" role="alert">{mutationError}</p> : null}
      <p className="provider-model-source" role="status">
        Source: {catalogUnavailable ? 'daemon config; verified model catalog unavailable' : 'daemon catalog + daemon config'}
      </p>
      {providers.length > 0 ? (
        <div className="provider-model-grid">
          {selectedProvider ? (
            <ProviderCard
              key={selectedProvider.id}
              provider={selectedProvider}
              mutationBusy={mutationBusy}
              onRemoveCustomModel={(providerID, modelID) => void removeCustomModel(providerID, modelID)}
              onPreferredCredentialSlot={(providerID, slotID) => void setPreferredCredentialSlot(providerID, slotID)}
              routingWritable={routingWritable}
              deepLinkedModelID={deepLinkedModelID}
              modelRowRef={(modelID, node) => {
                if (node) modelRows.current.set(modelID, node);
                else modelRows.current.delete(modelID);
              }}
            />
          ) : null}
        </div>
      ) : (
        <p className="provider-model-empty" role="status">No daemon provider rows are available.</p>
      )}
    </section>
  );
}
