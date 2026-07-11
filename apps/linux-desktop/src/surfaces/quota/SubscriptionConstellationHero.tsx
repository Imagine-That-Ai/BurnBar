import type { CSSProperties } from 'react';
import type { AggregateSummary, SubscriptionEntry } from './quotaModel.js';
import { eyebrowText, headlineText } from './quotaModel.js';
import { ProviderLogoView } from '../../components/ProviderLogoView.js';
import { findProviderGlyph } from '../../providerGlyphs.js';

type Props = {
  entries: SubscriptionEntry[];
  summary: AggregateSummary;
  orbEntries: SubscriptionEntry[];
  selectedProviderId: string | null;
  totalProviderCount: number;
  onOrbTap: (providerId: string) => void;
  onClearSelection: () => void;
};

export function SubscriptionConstellationHero({
  entries,
  summary,
  orbEntries,
  selectedProviderId,
  onOrbTap,
  onClearSelection
}: Props) {
  const focused = selectedProviderId
    ? entries.find((e) => e.providerId === selectedProviderId)?.providerLabel ?? null
    : null;
  const eyebrow = eyebrowText(summary, selectedProviderId, focused);
  const headline = headlineText(summary, focused);
  const meta: string[] = [];
  if (summary.activeCount > 0) meta.push(`${summary.activeCount} ACTIVE`);
  if (summary.nearEdgeCount > 0) meta.push(`${summary.nearEdgeCount} NEAR EDGE`);

  return (
    <section className="quota-hero" aria-labelledby="quota-hero-title">
      <div className="quota-hero-copy">
        <p className="quota-hero-eyebrow mono">{eyebrow}</p>
        <h2 id="quota-hero-title" className="quota-hero-headline">
          {headline}
        </h2>
        {meta.length > 0 ? (
          <p className="quota-hero-meta mono">
            {meta.map((item, idx) => (
              <span key={item}>
                {idx > 0 ? <span className="quota-hero-dot"> · </span> : null}
                {item}
              </span>
            ))}
          </p>
        ) : null}
        {selectedProviderId ? (
          <button type="button" className="ghost quota-hero-clear" onClick={onClearSelection}>
            Show all providers
          </button>
        ) : null}
      </div>
      <div className="quota-hero-hairline" aria-hidden="true" />
      <div className="quota-constellation" role="group" aria-label="Provider quota constellation">
        {orbEntries.map((entry) => {
          const selected = entry.providerId === selectedProviderId;
          const glyph = findProviderGlyph(entry.providerId);
          const accent = glyph.accent.startsWith('#') ? 'var(--color-brass-core)' : glyph.accent;
          const pct = entry.remainingPercentRounded;
          return (
            <button
              key={entry.providerId}
              type="button"
              className="quota-orb"
              data-provider={entry.providerId}
              data-selected={selected ? 'true' : 'false'}
              data-pressure={entry.pressure >= 0.74 ? 'edge' : entry.pressure >= 0.46 ? 'narrow' : 'ok'}
              aria-pressed={selected}
              aria-label={`${entry.providerLabel}, ${pct}% remaining`}
              onClick={() => onOrbTap(entry.providerId)}
            >
              <span className="quota-orb-ring" style={{ '--orb-accent': accent } as CSSProperties}>
                <svg viewBox="0 0 64 64" className="quota-orb-svg" aria-hidden="true">
                  <circle cx="32" cy="32" r="28" className="quota-orb-track" fill="none" />
                  <circle
                    cx="32"
                    cy="32"
                    r="28"
                    className="quota-orb-fill"
                    fill="none"
                    pathLength={100}
                    strokeDasharray={`${pct} 100`}
                    transform="rotate(-90 32 32)"
                  />
                </svg>
                <span className="quota-orb-logo">
                  <ProviderLogoView id={entry.providerId} size={28} accent={accent} />
                </span>
              </span>
              <span className="quota-orb-pct mono">{pct}%</span>
              <span className="quota-orb-label">{entry.providerLabel}</span>
            </button>
          );
        })}
      </div>
    </section>
  );
}
