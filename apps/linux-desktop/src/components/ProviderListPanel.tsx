import { ProviderLogoView } from './ProviderLogoView.js';
import { formatProviderCost, type OverviewProviderRow } from '../surfaces/overview/overviewAtelierData.js';
import './provider-list-panel.css';

export function ProviderListPanel({
  rows,
  title = 'Providers',
  subtitle,
  logoSize = 40,
  skeleton,
  onSelect,
  rowCount
}: {
  rows: OverviewProviderRow[];
  title?: string;
  subtitle?: string;
  logoSize?: number;
  skeleton?: boolean;
  onSelect?: (id: string) => void;
  /** Rows granted by Fit/Feed/Breathe. Omit to show the whole list. */
  rowCount?: number;
}) {
  if (skeleton) {
    return (
      <section className="provider-list-panel provider-list-panel--skeleton" aria-busy="true" aria-label="Loading providers">
        <div className="provider-list-panel-skel-head" />
        {Array.from({ length: 6 }, (_, i) => (
          <div key={i} className="provider-list-panel-skel-row" />
        ))}
      </section>
    );
  }

  return (
    <section className="provider-list-panel" aria-label={title}>
      <header className="provider-list-panel-header">
        <div>
          {subtitle ? <p className="provider-list-panel-subtitle">{subtitle}</p> : null}
          <h3 className="provider-list-panel-title">{title}</h3>
        </div>
        <span className="provider-list-panel-count mono tabular-nums">{rows.length} active</span>
      </header>
      {rows.length === 0 ? (
        <p className="provider-list-panel-empty muted">No provider activity yet.</p>
      ) : (
        <ul className="provider-list-panel-list">
          {(typeof rowCount === 'number' ? rows.slice(0, Math.max(0, rowCount)) : rows).map((row, index) => (
            <li key={`${row.id}-${index}`}>
              <button
                type="button"
                className="provider-list-panel-row"
                onClick={() => onSelect?.(row.id)}
                aria-label={`${row.label}, ${formatProviderCost(row.costUsd)}`}
              >
                <ProviderLogoView id={row.id} size={logoSize} accent={row.accent} />
                <span className="provider-list-panel-name">{row.label}</span>
                <span className="provider-list-panel-cost mono tabular-nums">{formatProviderCost(row.costUsd)}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}