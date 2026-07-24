import { useState } from 'react';
import type { CSSProperties } from 'react';
import { ArcDial } from './ArcDial.js';
import { ProviderLogoView } from './ProviderLogoView.js';
import { findProviderGlyph } from '../providerGlyphs.js';
import type { SubscriptionBucketView, SubscriptionEntry } from '../surfaces/quota/quotaModel.js';

function PaceBadge({ pace }: { pace: SubscriptionBucketView['pace'] }) {
  if (!pace || pace.severity === 'onPace') return null;
  const tone =
    pace.severity === 'aheadOfBudget' ? 'ahead' : pace.severity === 'behindBudget' ? 'behind' : 'neutral';
  return (
    <span className="quota-pace-badge" data-pace={tone}>
      {pace.humanLabel}
    </span>
  );
}

function MicroBadge({ text, tone = 'neutral' }: { text: string; tone?: string }) {
  return (
    <span className="quota-micro-badge" data-tone={tone}>
      {text}
    </span>
  );
}

function WindowRow({
  label,
  bucket
}: {
  label: string;
  bucket: SubscriptionBucketView | null;
}) {
  if (!bucket) {
    return (
      <div className="quota-window-row quota-window-row--empty">
        <span className="quota-window-label">{label}</span>
        <span className="muted">—</span>
      </div>
    );
  }
  const fill = bucket.remainingPct;
  return (
    <div className="quota-window-row">
      <div className="quota-window-meta">
        <span className="quota-window-label">{label}</span>
        <span className="quota-window-remaining mono">{bucket.remainingPct}% left</span>
        <PaceBadge pace={bucket.pace} />
      </div>
      <div
        className="quota-window-track"
        role="meter"
        aria-label={`${label}: ${fill}% remaining`}
        aria-valuenow={fill}
        aria-valuemin={0}
        aria-valuemax={100}
      >
        <div className="quota-window-fill" style={{ width: `${fill}%` }} data-state={bucket.state} />
      </div>
    </div>
  );
}

export function QuotaCard({ entry, onManage }: { entry: SubscriptionEntry; onManage: () => void }) {
  const [expanded, setExpanded] = useState(false);
  const glyph = findProviderGlyph(entry.providerId);
  const accent = glyph.accent;
  const visibleBuckets = expanded ? entry.buckets : entry.buckets.slice(0, 2);
  const bucketToggle =
    entry.buckets.length > 2
      ? expanded
        ? 'Hide buckets'
        : `Show all buckets (${entry.buckets.length})`
      : null;

  return (
    <article
      className="quota-card"
      style={{ '--quota-card-accent': accent } as CSSProperties}
      data-provider={entry.providerId}
      data-inactive={entry.isInactive ? 'true' : 'false'}
    >
      <header className="quota-card-header">
        <ProviderLogoView id={entry.providerId} size={36} accent={accent} />
        <div className="quota-card-identity">
          <div className="quota-card-title-row">
            <h3 className="quota-card-title">{entry.providerLabel}</h3>
            {entry.planTierBadge ? <MicroBadge text={entry.planTierBadge} tone="tier" /> : null}
            {entry.isInactive ? (
              <MicroBadge text="Missing credential" tone="err" />
            ) : !entry.planTierBadge && entry.buckets.some((b) => b.isEstimated) ? (
              <MicroBadge text="Estimated" tone="warn" />
            ) : (
              <MicroBadge text="Active" tone="active" />
            )}
          </div>
          <p className="quota-card-account muted">{entry.accountLabel}</p>
          <p className="quota-card-routing" data-routing={entry.routing.mode} role="status">
            <strong>{entry.routing.mode === 'preferred' ? 'Preferred route' : entry.routing.mode === 'automatic' ? 'Auto route' : 'Route unavailable'}</strong>
            <span>{entry.routing.detail}</span>
          </p>
          <div className="quota-card-badges">
            <MicroBadge text={entry.sourceLabel} tone="source" data-confidence={entry.confidence} />
            {entry.storageScope === 'local' || entry.storageScope === 'keychain' ? (
              <MicroBadge text="Local session" tone="neutral" />
            ) : null}
          </div>
        </div>
        <span className="quota-source-pill" data-confidence={entry.confidence}>
          {entry.sourceLabel}
        </span>
      </header>

      <div className="quota-card-body">
        <ArcDial
          outer={entry.longBucket ?? entry.sevenDayBucket ?? entry.primaryBucket}
          inner={entry.shortBucket}
          providerId={entry.providerId}
          dominantLabel={entry.primaryBucket?.label}
        />
        <div className="quota-card-windows">
          <WindowRow label="Short window" bucket={entry.shortBucket} />
          <WindowRow label="Long window" bucket={entry.longBucket ?? entry.primaryBucket} />
          <WindowRow label="7-Day window" bucket={entry.sevenDayBucket ?? entry.longBucket} />
        </div>
      </div>

      {entry.isInactive ? (
        <p className="quota-card-empty muted" data-reason="missing-credential">
          Missing credential — reconnect the provider to track quota.
        </p>
      ) : visibleBuckets.length > 0 ? (
        <ul className="quota-card-bucket-list">
          {visibleBuckets.map((b) => (
            <li key={b.id}>
              <span>{b.label}</span>
              <span className="mono">{b.remainingPct}%</span>
              <PaceBadge pace={b.pace} />
            </li>
          ))}
        </ul>
      ) : (
        <p className="quota-card-empty muted">No quota bars yet — connect credentials to start tracking.</p>
      )}

      <footer className="quota-card-footer">
        {bucketToggle ? (
          <button type="button" className="ghost quota-card-expand" onClick={() => setExpanded((v) => !v)}>
            {bucketToggle}
          </button>
        ) : (
          <span />
        )}
        <button type="button" className="ghost quota-card-manage" onClick={onManage}>
          Manage →
        </button>
      </footer>
    </article>
  );
}

export function QuotaListRow({ entry, onManage }: { entry: SubscriptionEntry; onManage: () => void }) {
  const glyph = findProviderGlyph(entry.providerId);
  const accent = glyph.accent.startsWith('#') ? 'var(--color-brass-core)' : glyph.accent;
  return (
    <div className="quota-list-row" data-provider={entry.providerId}>
      <ProviderLogoView id={entry.providerId} size={28} accent={accent} />
      <div className="quota-list-copy">
        <strong>{entry.providerLabel}</strong>
        <span className="muted">{entry.accountLabel}</span>
      </div>
      <div className="quota-list-strip">
        <WindowRow label="Short" bucket={entry.shortBucket} />
        <WindowRow label="Long" bucket={entry.longBucket ?? entry.primaryBucket} />
      </div>
      <span className="quota-list-pct mono">{entry.remainingPercentRounded}%</span>
      <button type="button" className="ghost quota-list-manage" onClick={onManage}>Manage →</button>
    </div>
  );
}
