import { useState } from 'react';
import { PROVIDER_GLYPHS } from '../../providerGlyphs.js';
import type {
  ProviderCatalog,
  ProviderCatalogEntry,
  ProviderCatalogModel,
  ProviderHealthState
} from '../../tauriBridge.js';
import { ProviderLogoView } from '../../components/ProviderLogoView.js';
import './providers.css';

const HEALTH_LABEL: Record<ProviderHealthState, string> = {
  healthy: 'Healthy',
  degraded: 'Degraded',
  unavailable: 'Unavailable',
  unknown: 'Health unknown'
};

function providerGlyph(providerID: string) {
  return PROVIDER_GLYPHS.find((glyph) => glyph.id === providerID) ?? {
    id: providerID,
    label: providerID,
    accent: 'var(--color-brass-core)'
  };
}

function ModelState({ model }: { model: ProviderCatalogModel }) {
  return (
    <div className="provider-model-state" aria-label={`${model.label} state`}>
      <span className="provider-model-pill" data-state={model.health}>
        {HEALTH_LABEL[model.health]}
      </span>
      <span className="provider-model-pill" data-state={model.enabled ? 'enabled' : 'disabled'}>
        {model.enabled ? 'Eligible' : 'Not eligible'}
      </span>
      <span className="provider-model-provenance">{model.provenance.replaceAll('-', ' ')}</span>
    </div>
  );
}

function ModelRow({ model }: { model: ProviderCatalogModel }) {
  return (
    <li className="provider-model-row" data-model={model.id}>
      <div className="provider-model-row-heading">
        <div>
          <strong>{model.label}</strong>
          <code>{model.id}</code>
        </div>
        <ModelState model={model} />
      </div>
      {model.aliases.length > 0 ? (
        <p className="provider-model-aliases">
          Aliases: <span className="mono">{model.aliases.join(', ')}</span>
        </p>
      ) : null}
      {model.capabilities.length > 0 ? (
        <ul className="provider-model-capability-list" aria-label={`${model.label} capabilities`}>
          {model.capabilities.map((capability) => (
            <li key={capability}>{capability}</li>
          ))}
        </ul>
      ) : null}
      {model.detail ? <p className="provider-model-detail">{model.detail}</p> : null}
    </li>
  );
}

function ProviderAccountSelector({
  provider,
  loading,
  onSelect
}: {
  provider: ProviderCatalogEntry;
  loading: boolean;
  onSelect?: (providerID: string, slotID: string | null) => Promise<void>;
}) {
  const slots = provider.credentialSlots ?? [];
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (slots.length === 0) return null;

  const selected = provider.preferredCredentialSlotID ?? '';
  const disabled = loading || busy || !onSelect;
  const handleChange = async (slotID: string) => {
    if (!onSelect || slotID === selected) return;
    setBusy(true);
    setError(null);
    try {
      await onSelect(provider.id, slotID || null);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Account switch failed.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="provider-account-selector">
      <label htmlFor={`provider-account-${provider.id}`}>Active account</label>
      <select
        id={`provider-account-${provider.id}`}
        value={selected}
        disabled={disabled}
        onChange={(event) => void handleChange(event.currentTarget.value)}
        aria-describedby={error ? `provider-account-error-${provider.id}` : undefined}
      >
        <option value="">Automatic routing</option>
        {slots.map((slot) => (
          <option key={slot.slotID} value={slot.slotID} disabled={!slot.isEnabled}>
            {slot.label} · {slot.status}
          </option>
        ))}
      </select>
      <span className="provider-account-selector-note" role="status">
        {busy ? 'Saving account…' : selected ? `Pinned to ${slots.find((slot) => slot.slotID === selected)?.label ?? selected}` : 'Router chooses an eligible account'}
      </span>
      {error ? (
        <span id={`provider-account-error-${provider.id}`} className="provider-account-selector-error" role="alert">
          {error}
        </span>
      ) : null}
    </div>
  );
}

function ProviderModelCard({
  provider,
  loading,
  onSelectAccount
}: {
  provider: ProviderCatalogEntry;
  loading: boolean;
  onSelectAccount?: (providerID: string, slotID: string | null) => Promise<void>;
}) {
  const glyph = providerGlyph(provider.id);
  return (
    <article className="provider-model-card" data-provider={provider.id}>
      <header className="provider-model-card-header">
        <div className="provider-model-card-title">
          <ProviderLogoView id={provider.id} size={30} accent={glyph.accent} className="provider-model-logo" />
          <div>
            <h3>{provider.label}</h3>
            <p className="provider-model-account">{provider.accountLabel}</p>
          </div>
        </div>
        <span className="provider-model-health" data-state={provider.health}>
          {HEALTH_LABEL[provider.health]}
        </span>
      </header>

      <div className="provider-model-meta">
        <span>
          Source: <strong>{provider.provenance}</strong>
        </span>
        <span>
          Failover: <strong>{provider.failover.eligible ? 'Eligible' : 'Unavailable'}</strong>
        </span>
        <span>
          Mode: <strong>{provider.failover.mode}</strong>
        </span>
      </div>

      {provider.capabilities.length > 0 ? (
        <ul className="provider-capability-list" aria-label={`${provider.label} capabilities`}>
          {provider.capabilities.map((capability) => (
            <li key={capability}>{capability.replaceAll('_', ' ')}</li>
          ))}
        </ul>
      ) : (
        <p className="provider-model-muted">No provider capabilities were advertised by the daemon.</p>
      )}

      <p className="provider-failover-detail" role="status">
        {provider.failover.detail}
      </p>

      <ProviderAccountSelector provider={provider} loading={loading} onSelect={onSelectAccount} />

      {provider.models.length > 0 ? (
        <ul className="provider-model-list" aria-label={`${provider.label} model catalog`}>
          {provider.models.map((model) => (
            <ModelRow key={`${provider.id}:${model.id}`} model={model} />
          ))}
        </ul>
      ) : (
        <div className="provider-model-empty" role="status">
          No model entries returned for this provider.
        </div>
      )}
    </article>
  );
}

export function ProviderModelWorkspace({
  providers,
  loading,
  onRefresh,
  onSelectAccount
}: {
  providers: ProviderCatalog;
  loading: boolean;
  onRefresh: () => void;
  onSelectAccount?: (providerID: string, slotID: string | null) => Promise<void>;
}) {
  const modelCount = providers.reduce((count, provider) => count + provider.models.length, 0);
  const catalogUnavailable = providers.some((provider) => !provider.catalogAvailable);
  const catalogError = providers.find((provider) => provider.catalogError)?.catalogError;

  return (
    <section className="provider-model-workspace" aria-labelledby="provider-model-workspace-heading">
      <header className="provider-model-workspace-header">
        <div>
          <p className="provider-model-eyebrow mono">MODEL WORKSPACE</p>
          <h2 id="provider-model-workspace-heading">Providers &amp; models</h2>
          <p className="provider-model-lede">
            Review the daemon catalog, route eligibility, and model provenance without exposing provider credentials.
          </p>
        </div>
        <div className="provider-model-actions">
          <span className="provider-model-count" aria-live="polite">
            {providers.length} providers · {modelCount} models
          </span>
          <button
            type="button"
            className="ghost"
            onClick={onRefresh}
            disabled={loading}
            aria-busy={loading}
            aria-label="Refresh provider and model catalog"
          >
            {loading ? 'Refreshing…' : 'Refresh catalog'}
          </button>
        </div>
      </header>

      <p className="provider-model-provenance" role="status">
        Source: {catalogUnavailable ? 'daemon config only; model catalog unavailable' : 'daemon catalog + local daemon config'}
      </p>

      {catalogUnavailable ? (
        <div className="provider-model-retry" role="alert">
          <div>
            <strong>Model catalog needs a refresh.</strong>
            <p>{catalogError ?? 'The daemon did not return model entries. Quota and configuration rows remain visible.'}</p>
          </div>
          <button type="button" className="ghost" onClick={onRefresh} disabled={loading}>
            {loading ? 'Retrying…' : 'Retry catalog'}
          </button>
        </div>
      ) : null}

      <div className="provider-model-grid">
        {providers.map((provider) => (
          <ProviderModelCard
            key={provider.id}
            provider={provider}
            loading={loading}
            onSelectAccount={onSelectAccount}
          />
        ))}
      </div>
    </section>
  );
}
