import type { ProviderCatalog, ProviderCatalogEntry, ProviderCatalogModel, ProviderHealthState } from '../../tauriBridge.js';
import { useProvidersStore } from '../../state/providersStore.js';
import './provider-model-workspace.css';

const HEALTH_LABEL: Record<ProviderHealthState, string> = {
  healthy: 'Healthy',
  degraded: 'Degraded',
  unavailable: 'Unavailable',
  unknown: 'Status unavailable'
};

function ModelRow({ model }: { model: ProviderCatalogModel }) {
  return (
    <li className="provider-model-row" data-model={model.id}>
      <div className="provider-model-row-heading">
        <div>
          <strong>{model.label}</strong>
          <code>{model.id}</code>
        </div>
        <span className="provider-model-status" data-state={model.health}>
          {model.enabled ? 'Route ready' : HEALTH_LABEL[model.health]}
        </span>
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

function ProviderCard({ provider }: { provider: ProviderCatalogEntry }) {
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
          {models.map((model) => <ModelRow key={`${provider.id}:${model.id}`} model={model} />)}
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
  const load = useProvidersStore((state) => state.load);
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
      <p className="provider-model-source" role="status">
        Source: {catalogUnavailable ? 'daemon config; verified model catalog unavailable' : 'daemon catalog + daemon config'}
      </p>
      {providers.length > 0 ? (
        <div className="provider-model-grid">
          {providers.map((provider) => <ProviderCard key={provider.id} provider={provider} />)}
        </div>
      ) : (
        <p className="provider-model-empty" role="status">No daemon provider rows are available.</p>
      )}
    </section>
  );
}
