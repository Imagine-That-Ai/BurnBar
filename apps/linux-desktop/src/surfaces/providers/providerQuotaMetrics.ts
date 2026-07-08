import type { QuotaBucket } from '../../tauriBridge.js';

/** Fuel-gauge fill: remaining share of the window (0–100). */
export function remainingPct(bucket: QuotaBucket): number {
  const ext = bucket as QuotaBucket & { remainingPct?: number };
  if (typeof ext.remainingPct === 'number' && Number.isFinite(ext.remainingPct)) {
    return Math.min(100, Math.max(0, ext.remainingPct));
  }
  return Math.min(100, Math.max(0, 100 - bucket.usedPct));
}

/** Ideal pace tick position along the bar (0–1), fuel-gauge semantics. */
export function idealPaceTickFraction(bucket: QuotaBucket, now = Date.now()): number | null {
  const ext = bucket as QuotaBucket & { idealPaceElapsedFraction?: number };
  if (typeof ext.idealPaceElapsedFraction === 'number' && Number.isFinite(ext.idealPaceElapsedFraction)) {
    const elapsed = Math.min(1, Math.max(0, ext.idealPaceElapsedFraction));
    return 1 - elapsed;
  }
  if (!bucket.resetsAt) return null;
  const resetMs = Date.parse(bucket.resetsAt);
  if (!Number.isFinite(resetMs)) return null;
  const windowMs = guessWindowMs(bucket.label);
  if (windowMs <= 0) return null;
  const remainingMs = Math.max(0, resetMs - now);
  const elapsedMs = Math.min(windowMs, Math.max(0, windowMs - remainingMs));
  const elapsedFraction = elapsedMs / windowMs;
  return Math.min(1, Math.max(0, 1 - elapsedFraction));
}

function guessWindowMs(label: string): number {
  const lower = label.toLowerCase();
  const hourMatch = lower.match(/(\d+)\s*h/);
  if (hourMatch) return Number(hourMatch[1]) * 3_600_000;
  if (lower.includes('daily') || lower.includes('day')) return 86_400_000;
  if (lower.includes('weekly') || lower.includes('week')) return 7 * 86_400_000;
  if (lower.includes('monthly') || lower.includes('month')) return 30 * 86_400_000;
  if (lower.includes('min')) return 60_000;
  return 86_400_000;
}