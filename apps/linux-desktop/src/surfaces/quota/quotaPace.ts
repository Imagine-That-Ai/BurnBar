import type { QuotaBucket } from '../../tauriBridge.js';
import { remainingPct } from '../providers/providerQuotaMetrics.js';

export type PaceSeverity = 'onPace' | 'aheadOfBudget' | 'behindBudget';

export type IdealPace = {
  severity: PaceSeverity;
  humanLabel: string;
  delta: number;
  tickFraction: number | null;
};

const ON_PACE_THRESHOLD = 0.08;

function guessWindowMs(label: string): number {
  const lower = label.toLowerCase();
  const hourMatch = lower.match(/(\d+)\s*h/);
  if (hourMatch) return Number(hourMatch[1]) * 3_600_000;
  if (lower.includes('daily') || lower.includes('day')) return 86_400_000;
  if (lower.includes('weekly') || lower.includes('week') || lower.includes('7-day')) return 7 * 86_400_000;
  if (lower.includes('monthly') || lower.includes('month')) return 30 * 86_400_000;
  if (lower.includes('min')) return 60_000;
  return 86_400_000;
}

export function computeIdealPace(bucket: QuotaBucket, remaining = remainingPct(bucket), now = Date.now()): IdealPace | null {
  if (!bucket.resetsAt) return null;
  const resetMs = Date.parse(bucket.resetsAt);
  if (!Number.isFinite(resetMs)) return null;
  const windowMs = guessWindowMs(bucket.label);
  if (windowMs <= 0) return null;
  const remainingMs = Math.max(0, resetMs - now);
  const elapsedMs = Math.min(windowMs, Math.max(0, windowMs - remainingMs));
  const elapsedFraction = elapsedMs / windowMs;
  const idealRemainingFraction = 1 - elapsedFraction;
  const actualRemainingFraction = remaining / 100;
  const delta = idealRemainingFraction - actualRemainingFraction;
  let severity: PaceSeverity = 'onPace';
  if (delta < -ON_PACE_THRESHOLD) severity = 'aheadOfBudget';
  else if (delta > ON_PACE_THRESHOLD) severity = 'behindBudget';
  const pct = Math.round(Math.abs(delta) * 100);
  const humanLabel =
    severity === 'onPace'
      ? 'On pace'
      : severity === 'aheadOfBudget'
        ? `+${pct}% pace`
        : `-${pct}% pace`;
  return {
    severity,
    humanLabel,
    delta,
    tickFraction: Math.min(1, Math.max(0, idealRemainingFraction))
  };
}