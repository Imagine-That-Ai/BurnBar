import { useEffect, useState } from 'react';
import type { CustomModel, ProviderCatalog, ProviderCatalogEntry, ProviderCatalogModel, ProviderHealthState } from '../../tauriBridge.js';
import { useProvidersStore } from '../../state/providersStore.js';
import './provider-model-workspace.css';

const HEALTH_LABEL: Record<ProviderHealthState, string> = {
  healthy: 'Healthy',
  degraded: 'Degraded',
  unavailable: 'Unavailable',
  unknown: 'Status unavailable'
};

function ModelRow({
  providerID,
  model,
  disabled,
  onRemoveCustomModel
}: {
  providerID: string;
  model: ProviderCatalogModel;
  disabled: boolean;
  onRemoveCustomModel: (providerID: string, modelID: string) => void;
}) {
  return (
    <li className="provider-model-row" data-model={model.id}>
      <div className="provider-model-row-heading">
        <div>
          <strong>{model.label}</strong>
          <code>{model.id}</code>
        </div>
        <div className="provider-model-row-actions">
          <span className="provider-model-status" data-state={model.health}>
            {model.enabled ? 'Route ready' : HEALTH_LABEL[model.health]}
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
  onRemoveCustomModel
}: {
  provider: ProviderCatalogEntry;
  mutationBusy: string | null;
  onRemoveCustomModel: (providerID: string, modelID: string) => void;
}) {
  const models = provider.models ?? [];
  const health = provider.health ?? 'unknown';
  const failover = provider.failover;
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
  const load = useProvidersStore((state) => state.load);
  const [selectedProviderID, setSelectedProviderID] = useState(providers[0]?.id ?? '');
  useEffect(() => {
    // Catalog refreshes can remove or reorder providers. Never leave the
    // mutation form pointing at a provider ID that is no longer present.
    setSelectedProviderID((current) => {
      if (providers.some((provider) => provider.id === current)) return current;
      return providers[0]?.id ?? '';
    });
  }, [providers]);
  const modelCount = providers.reduce((count, provider) => count + (provider.models?.length ?? 0), 0);
  const catalogUnavailable = providers.some((provider) => provider.catalogAvailable === false);
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
          {providers.map((provider) => (
            <ProviderCard
              key={provider.id}
              provider={provider}
              mutationBusy={mutationBusy}
              onRemoveCustomModel={(providerID, modelID) => void removeCustomModel(providerID, modelID)}
            />
          ))}
        </div>
      ) : (
        <p className="provider-model-empty" role="status">No daemon provider rows are available.</p>
      )}
    </section>
  );
}
