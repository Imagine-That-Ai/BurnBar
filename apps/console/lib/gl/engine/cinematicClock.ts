/**
 * Cinematic present clock — paced 30 (or a divisor of the display refresh)
 * with real `dt` and an EMA shutter so 30 fps does not look like dropped 60.
 *
 * Pure functions. No DOM, no GPU. Swift `KernelBackdropFramePolicy` mirrors
 * {@link cinematicPresentFps} so native caps and the JS loop cannot disagree.
 */

/** Shutter time constant. ~one 30 fps frame; enough to hide judder, not smear. */
export const SHUTTER_TAU_MS = 24;

/** Reference frame for `/frame` easings that were tuned at 60 Hz. */
export const REFERENCE_FRAME_MS = 1000 / 60;

export interface CinematicClockState {
  lastNow: number;
  lastFrameAdvanceAt: number;
  primed: boolean;
}

export interface CinematicPresentStep {
  presented: boolean;
  dt: number;
  alpha: number;
}

/**
 * Present rate that divides `refreshHz`. 30 on 60/120; 36 on 144 (never 30 on
 * 144 — 144/30 is not an integer and strobes). Performance-gate stays 60.
 */
export function cinematicPresentFps(refreshHz: number): number {
  const hz = Math.round(refreshHz);
  if (!Number.isFinite(hz) || hz <= 0) return 30;
  if (hz % 30 === 0) return 30;
  if (hz % 36 === 0) return 36;
  if (hz % 24 === 0) return 24;
  for (let fps = 36; fps >= 24; fps--) {
    if (hz % fps === 0) return fps;
  }
  return 30;
}

export function shouldAdvancePresent(
  now: number,
  lastFrameAdvanceAt: number,
  maxFps: number,
): boolean {
  if (!(maxFps > 0)) return true;
  return now - lastFrameAdvanceAt >= 1000 / maxFps;
}

export function frameDeltaMs(
  now: number,
  lastNow: number,
  maxFps: number,
): number {
  const cap = maxFps > 0 ? 100 : 32;
  const raw = now - lastNow;
  if (!Number.isFinite(raw) || raw < 0) return 0;
  return Math.min(raw, cap);
}

/** EMA mix: `history = mix(history, current, alpha)`. */
export function shutterAlpha(
  dtMs: number,
  tauMs: number = SHUTTER_TAU_MS,
): number {
  if (!(dtMs > 0) || !(tauMs > 0)) return 1;
  return 1 - Math.exp(-dtMs / tauMs);
}

/**
 * Scale a 60 Hz per-frame lerp `mix` (e.g. 0.18) so the same time constant
 * holds at an arbitrary `dt`.
 */
export function dtScaledMix(mixPer60HzFrame: number, dtMs: number): number {
  if (!(dtMs > 0)) return 0;
  const s = dtMs / REFERENCE_FRAME_MS;
  return 1 - Math.pow(1 - mixPer60HzFrame, s);
}

export function dtScaledDecay(decayPer60HzFrame: number, dtMs: number): number {
  if (!(dtMs > 0)) return 1;
  const s = dtMs / REFERENCE_FRAME_MS;
  return Math.pow(decayPer60HzFrame, s);
}

export function newCinematicClockState(): CinematicClockState {
  return { lastNow: 0, lastFrameAdvanceAt: 0, primed: false };
}

/**
 * Advance the present clock. Skipped rAF ticks return `presented: false`
 * and do not call kernel `frame`. A presented step carries real `dt` (not a
 * constant 16 ms) and a `dt`-based shutter alpha. First present and uncapped
 * / 60 fps loops use alpha 1 so certification and cold starts are unsmeared.
 */
export function advanceCinematicPresent(
  state: CinematicClockState,
  now: number,
  maxFps: number,
): CinematicPresentStep {
  if (!state.primed) {
    state.primed = true;
    state.lastNow = now;
    state.lastFrameAdvanceAt = now;
    const dt = maxFps > 0 ? 1000 / maxFps : REFERENCE_FRAME_MS;
    return { presented: true, dt, alpha: 1 };
  }
  if (!shouldAdvancePresent(now, state.lastFrameAdvanceAt, maxFps)) {
    return { presented: false, dt: 0, alpha: 1 };
  }
  const dt = frameDeltaMs(now, state.lastNow, maxFps);
  state.lastNow = now;
  state.lastFrameAdvanceAt = now;
  const shutter = maxFps > 0 && maxFps < 60;
  return {
    presented: true,
    dt,
    alpha: shutter ? shutterAlpha(dt) : 1,
  };
}
