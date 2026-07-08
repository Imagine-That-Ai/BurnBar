import { resolveCacheHitRateTier } from '../overview/cacheHitTier.js';

export function StatCallout({
  value,
  caption,
  deltaPct,
  cacheHitRatePct
}: {
  value?: string;
  caption: string;
  deltaPct?: number | null;
  /** When set, renders tier-colored value + dot + tier caption (macOS CacheHitRateBadge). */
  cacheHitRatePct?: number | null;
}) {
  let deltaText: string | null = null;
  if (deltaPct != null && Number.isFinite(deltaPct)) {
    const rounded = Math.round(deltaPct * 10) / 10;
    const prefix = rounded > 0 ? '+' : rounded < 0 ? '−' : '';
    const magnitude = rounded === 0 ? '0' : String(Math.abs(rounded));
    deltaText = `${prefix}${magnitude}% week over week`;
  }

  const tier =
    cacheHitRatePct !== undefined ? resolveCacheHitRateTier(cacheHitRatePct ?? null) : null;
  const displayValue = tier ? tier.formattedValue : (value ?? '—');
  const displayCaption = tier ? tier.caption : caption;
  const valueColor = tier?.color;

  return (
    <div className={`stat-callout${tier ? ` stat-callout--cache-${tier.id}` : ''}`}>
      <div className="stat-value-row">
        {tier ? (
          <span
            className="stat-tier-dot"
            style={{ background: tier.color }}
            aria-hidden="true"
          />
        ) : null}
        <span
          className="stat-number"
          style={valueColor ? { color: valueColor } : undefined}
        >
          {displayValue}
        </span>
      </div>
      <span className="stat-caption">{displayCaption}</span>
      {deltaText ? <span className="stat-delta">{deltaText}</span> : null}
    </div>
  );
}