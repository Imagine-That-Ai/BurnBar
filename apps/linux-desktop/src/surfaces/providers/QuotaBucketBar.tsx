import type { CSSProperties } from 'react';
import type { QuotaBucket, QuotaBucketState } from '../../tauriBridge.js';
import { idealPaceTickFraction, remainingPct } from './providerQuotaMetrics.js';

const STATE_LABEL: Record<QuotaBucketState, string> = {
  ok: 'OK',
  cooling_down: 'Cooling down',
  missing_credential: 'Missing credential',
  exhausted: 'Exhausted'
};

function formatResetsAt(iso?: string): string | null {
  if (!iso) return null;
  try {
    return new Date(iso).toLocaleString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit'
    });
  } catch {
    return null;
  }
}

export function QuotaBucketBar({
  bucket,
  accentColor = 'var(--color-brass-core)'
}: {
  bucket: QuotaBucket;
  accentColor?: string;
}) {
  const usedPct = Math.min(100, Math.max(0, bucket.usedPct));
  const remaining = remainingPct(bucket);
  const paceTick = idealPaceTickFraction(bucket);
  const resetLabel = formatResetsAt(bucket.resetsAt);
  const meterName = `${bucket.label}, ${remaining}% remaining, ${usedPct}% used`;

  return (
    <div
      className="quota-bucket-row"
      style={{ '--provider-quota-accent': accentColor } as CSSProperties}
    >
      <div className="quota-bucket-meta">
        <span className="quota-bucket-label">{bucket.label}</span>
        <span className="quota-state-badge" data-quota-state={bucket.state}>
          {STATE_LABEL[bucket.state]}
        </span>
        {resetLabel ? <span className="quota-bucket-reset muted">{resetLabel}</span> : null}
      </div>
      <div
        className="quota-bucket-meter"
        role="meter"
        aria-valuenow={remaining}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-label={meterName}
      >
        <div className="quota-bucket-track">
          <div
            className={`quota-bucket-fill quota-bucket-fill--${bucket.state}`}
            style={{ width: `${remaining}%` }}
          />
          {paceTick != null ? (
            <span
              className="quota-bucket-pace-tick"
              style={{ left: `${paceTick * 100}%` }}
              aria-hidden="true"
            />
          ) : null}
        </div>
        <span className="quota-bucket-pct mono" aria-hidden="true">
          {remaining}%
        </span>
      </div>
    </div>
  );
}