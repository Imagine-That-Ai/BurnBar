import { ConceptStatTile, ConceptStatTileSkeleton } from '../../components/ConceptStatTile.js';
import type { UsageSummary } from '../../tauriBridge.js';
import { resolveCacheHitRateTier } from './cacheHitTier.js';
import { AtelierSpendCurve } from './AtelierSpendCurve.js';
import type { SpendCurveModel } from './overviewAtelierData.js';
import { HOME_READING_MEASURE, buildAtelierHeroCopy, windowSessionCount, windowTokenTotal } from './overviewHomeModel.js';

const tokenFmt = new Intl.NumberFormat('en-US');
const costFmt = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2
});

export function AtelierHero({
  summary,
  cacheHitRatePct,
  curveModel,
  fixtureMode,
  loading,
  providerCount,
  kernelForward
}: {
  summary: UsageSummary | null;
  cacheHitRatePct: number | null;
  curveModel: SpendCurveModel;
  fixtureMode: boolean;
  loading?: boolean;
  providerCount: number;
  kernelForward: boolean;
}) {
  const cacheTier = resolveCacheHitRateTier(cacheHitRatePct);
  const copy = buildAtelierHeroCopy({
    summary,
    providerCount,
    cacheHitRatePct,
    fixtureMode,
    kernelForward
  });
  const legend = curveModel.legend;

  return (
    <div className="atelier-hero">
      {copy.chips.length > 0 ? (
        <div className="atelier-hero-chips">
          {copy.chips.map((chip) => (
            <span key={chip.id} className={`atelier-hero-chip atelier-hero-chip--${chip.tone}`}>
              {chip.label}
            </span>
          ))}
        </div>
      ) : null}

      <div className="atelier-hero-copy">
        <h2 className="atelier-hero-headline" style={{ maxWidth: HOME_READING_MEASURE.headline }}>
          {copy.headline}
        </h2>
        <p className="atelier-hero-sub muted" style={{ maxWidth: HOME_READING_MEASURE.body }}>
          {copy.sub}
        </p>
        {legend.length > 0 ? (
          <ul className="atelier-hero-legend" aria-label="Provider mix in this window">
            {legend.map((item) => (
              <li key={item.id}>
                <span className="atelier-hero-legend-dot" style={{ background: item.color }} aria-hidden />
                <span>{item.label}</span>
              </li>
            ))}
          </ul>
        ) : null}
      </div>

      <AtelierSpendCurve model={curveModel} fixtureMode={fixtureMode} loading={loading} />

      <div className="atelier-stat-row" aria-label="Usage summary">
        {loading || !summary ? (
          <>
            <ConceptStatTileSkeleton />
            <ConceptStatTileSkeleton />
            <ConceptStatTileSkeleton />
            <ConceptStatTileSkeleton />
          </>
        ) : (
          <>
            <ConceptStatTile
              label="Burn · Today"
              value={costFmt.format(summary.todayCostUsd)}
              accent="var(--color-mercury-bright)"
              prominence="hero"
            />
            <ConceptStatTile
              label="Tokens"
              value={tokenFmt.format(windowTokenTotal(summary))}
              accent="var(--color-brass-bright)"
              prominence="hero"
            />
            <ConceptStatTile
              label="Sessions"
              value={tokenFmt.format(windowSessionCount(summary))}
              accent="var(--color-tier-server-readable)"
              prominence="hero"
            />
            <ConceptStatTile
              label="Cache hit rate"
              value={cacheTier.formattedValue}
              caption={cacheTier.caption}
              accent={cacheTier.color}
              prominence="hero"
            />
          </>
        )}
      </div>
    </div>
  );
}
