import { useEffect, useId, useRef, useState } from 'react';
import type { UsageSummary } from '../tauriBridge.js';
import { Sparkline } from './Sparkline.js';
import {
  DECK_TIME_RANGES,
  persistDeckHeroUnit,
  persistDeckTimeRange,
  readDeckHeroUnit,
  readDeckTimeRange,
  type DeckHeroUnit,
  type DeckTimeRange
} from './deckPrimaryRoutes.js';

const costFmt = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  maximumFractionDigits: 2
});
const tokenFmt = new Intl.NumberFormat('en-US', { notation: 'compact' });

function scaleMetric(value: number, range: DeckTimeRange): number {
  if (range === 'today') return value;
  if (range === 'week') return value * 4.2;
  if (range === 'month') return value * 14;
  return value * 28;
}

function headlineFor(summary: UsageSummary, unit: DeckHeroUnit, range: DeckTimeRange): { value: string; suffix: string | null } {
  if (unit === 'tokens') {
    const n = scaleMetric(summary.todayTokens, range);
    return { value: tokenFmt.format(n), suffix: 'tok' };
  }
  const n = scaleMetric(summary.todayCostUsd, range);
  return { value: costFmt.format(n), suffix: null };
}

type Props = {
  summary: UsageSummary | null;
  loading?: boolean;
};

export function DeckBurnHero({ summary, loading }: Props) {
  const [unit, setUnit] = useState<DeckHeroUnit>(() => readDeckHeroUnit());
  const [range, setRange] = useState<DeckTimeRange>(() => readDeckTimeRange());
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const popoverId = useId();

  useEffect(() => {
    if (!open) return;
    const onDoc = (ev: MouseEvent) => {
      if (!rootRef.current?.contains(ev.target as Node)) setOpen(false);
    };
    const onKey = (ev: KeyboardEvent) => {
      if (ev.key === 'Escape') setOpen(false);
    };
    document.addEventListener('mousedown', onDoc);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDoc);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  if (loading || !summary) {
    return (
      <div className="burn-hero burn-hero--skeleton" aria-busy="true" aria-label="Loading telemetry" />
    );
  }

  const { value, suffix } = headlineFor(summary, unit, range);
  const ariaValue = suffix ? `${value} ${suffix}` : value;
  const spark = summary.sevenDay.length >= 2 ? summary.sevenDay : null;

  const setUnitAndPersist = (next: DeckHeroUnit) => {
    setUnit(next);
    persistDeckHeroUnit(next);
  };

  const setRangeAndPersist = (next: DeckTimeRange) => {
    setRange(next);
    persistDeckTimeRange(next);
  };

  return (
    <div className="deck-burn-hero-wrap" ref={rootRef}>
      <button
        type="button"
        className="burn-hero burn-hero--interactive"
        aria-expanded={open}
        aria-controls={popoverId}
        aria-label={`BURN ${ariaValue}. Open range and unit controls`}
        onClick={() => setOpen((v) => !v)}
      >
        <span className="burn-hero-live-dot" aria-hidden="true" />
        <span className="burn-hero-copy">
          <span className="burn-hero-kicker">
            BURN
          </span>
          <span className="burn-hero-headline">
            <span className={`burn-hero-value${unit === 'cost' ? ' burn-hero-cost' : ''}`}>{value}</span>
            {suffix ? <span className="burn-hero-suffix">{suffix}</span> : null}
          </span>
        </span>
        {spark ? (
          <span className="burn-hero-sparkline" aria-hidden="true">
            <Sparkline values={spark} width={64} height={22} label="7-day token trend" />
          </span>
        ) : null}
      </button>
      {open ? (
        <div className="deck-hero-popover" id={popoverId} role="dialog" aria-label="Time range and unit">
          <p className="deck-hero-popover-label">Time range</p>
          <div className="deck-hero-popover-list">
            {DECK_TIME_RANGES.map((item) => {
              const selected = item.id === range;
              return (
                <button
                  key={item.id}
                  type="button"
                  className={`deck-hero-popover-row${selected ? ' deck-hero-popover-row--selected' : ''}`}
                  onClick={() => setRangeAndPersist(item.id)}
                >
                  <span className="deck-hero-popover-check" aria-hidden="true">
                    {selected ? '✓' : ''}
                  </span>
                  {item.label}
                </button>
              );
            })}
          </div>
          <div className="deck-hero-popover-divider" role="separator" />
          <div className="deck-hero-popover-unit">
            <span className="deck-hero-popover-label">Unit</span>
            <div className="deck-hero-unit-toggle" role="group" aria-label="Display unit">
              <button
                type="button"
                className="deck-hero-unit-btn"
                aria-pressed={unit === 'cost'}
                onClick={() => setUnitAndPersist('cost')}
              >
                $
              </button>
              <button
                type="button"
                className="deck-hero-unit-btn"
                aria-pressed={unit === 'tokens'}
                onClick={() => setUnitAndPersist('tokens')}
              >
                tok
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}