import { ConceptStatTile, ConceptStatTileSkeleton } from '../../components/ConceptStatTile.js';
import type { UsageSummary } from '../../tauriBridge.js';
import { resolveCacheHitRateTier } from './cacheHitTier.js';
import { AtelierSpendCurve } from './AtelierSpendCurve.js';
import type { SpendCurveModel } from './overviewAtelierData.js';

const tokenFmt = new Intl.NumberFormat('en-US');
const costFmt = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2
});

function windowSessionCount(summary: UsageSummary): number {
  return new Set(summary.recentEvents.map((e) => e.id)).size;
}

function windowTokenTotal(summary: UsageSummary): number {
  return summary.sevenDay.reduce((a, b) => a + b, 0);
}

const HERO_LEGEND = [
  { id: 'claude-code', label: 'Claude Code', color: 'var(--color-tier-server-readable)' },
  { id: 'codex', label: 'Codex', color: 'var(--color-brass-bright)' },
  { id: 'antigravity', label: 'Antigravity', color: 'var(--color-mercury-bright)' },
  { id: 'factory', label: 'Factory', color: 'var(--color-tier-end-to-end)' },
  { id: 'cursor', label: 'Cursor', color: 'var(--color-brass-core)' },
  { id: 'other', label: 'Other', color: 'var(--color-text-mute)' }
];

export function AtelierHero({
  summary,
  cacheHitRatePct,
  curveModel,
  fixtureMode,
  loading
}: {
  summary: UsageSummary | null;
  cacheHitRatePct: number | null;
  curveModel: SpendCurveModel;
  fixtureMode: boolean;
  loading?: boolean;
}) {
  const cacheTier = resolveCacheHitRateTier(cacheHitRatePct);

  return (
    <div className="atelier-hero">
      <div className="atelier-hero-chips">
        <span className="atelier-hero-chip atelier-hero-chip--swarm">Swarm forming</span>
        <span className="atelier-hero-chip atelier-hero-chip--kernel">WebGL kernel</span>
      </div>

      <div className="atelier-hero-copy">
        <h2 className="atelier-hero-headline">
          A living substrate,
          <br />
          tuned to your spend.
        </h2>
        <p className="atelier-hero-sub muted">
          Provider logos emerge from the kernel and dissolve back into it. Every layout is its own ecosystem — pick a
          concept, tune the glass.
        </p>
        <ul className="atelier-hero-legend" aria-label="Provider legend">
          {HERO_LEGEND.map((item) => (
            <li key={item.id}>
              <span className="atelier-hero-legend-dot" style={{ background: item.color }} aria-hidden />
              <span>{item.label}</span>
            </li>
          ))}
        </ul>
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
              value={tokenFmt.format(fixtureMode ? 1_284_000 : windowTokenTotal(summary))}
              accent="var(--color-brass-bright)"
              prominence="hero"
            />
            <ConceptStatTile
              label="Sessions"
              value={tokenFmt.format(fixtureMode ? 19_039 : windowSessionCount(summary))}
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