/**
 * Shared motion vocabulary. Numbers come from the generated pensieve tokens;
 * fallbacks exist only for jsdom, where the CSS custom properties are not loaded.
 */

import { prefersReducedMotion as systemPrefersReducedMotion } from '../a11y.js';

const FALLBACK = {
  settleResponseMs: 420,
  arriveResponseMs: 340,
  arriveRisePx: 18,
  arriveScale: 0.97,
  departMs: 160,
  staggerStepMs: 60,
  staggerCapMs: 240,
  tickMs: 300,
  pulsePeriodMs: 1400,
  pulseFloor: 0.55,
  reducedMs: 180
} as const;

function readNumber(name: string, fallback: number): number {
  if (typeof window === 'undefined' || typeof getComputedStyle !== 'function') return fallback;
  const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const parsed = Number.parseFloat(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
}

/** Duration token → the fallback used when its custom property is absent. */
const TOKEN_MS = {
  '--motion-settle-response-ms': FALLBACK.settleResponseMs,
  '--motion-arrive-response-ms': FALLBACK.arriveResponseMs,
  '--motion-depart-ms': FALLBACK.departMs,
  '--motion-stagger-step-ms': FALLBACK.staggerStepMs,
  '--motion-stagger-cap-ms': FALLBACK.staggerCapMs,
  '--motion-tick-ms': FALLBACK.tickMs,
  '--motion-pulse-period-ms': FALLBACK.pulsePeriodMs,
  '--motion-reduced-ms': FALLBACK.reducedMs
} as const;

function motionTokenMs(name: keyof typeof TOKEN_MS): number {
  return readNumber(name, TOKEN_MS[name]);
}

/**
 * The `reduced-motion` body class wins so a surface honours the preference even
 * where `matchMedia` is unavailable (jsdom); otherwise defer to the app's one
 * accessibility gate rather than restating the query here.
 */
export function prefersReducedMotion(): boolean {
  if (typeof document !== 'undefined' && document.body?.classList.contains('reduced-motion')) {
    return true;
  }
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false;
  return systemPrefersReducedMotion();
}

/** Stagger delay for a group arrival. Reduced motion is simultaneous. */
export function staggerDelayMs(index: number, reduced: boolean): number {
  if (reduced) return 0;
  const step = motionTokenMs('--motion-stagger-step-ms');
  const cap = motionTokenMs('--motion-stagger-cap-ms');
  return Math.min(Math.max(0, index) * step, cap);
}

export const MOTION_FALLBACK = FALLBACK;
