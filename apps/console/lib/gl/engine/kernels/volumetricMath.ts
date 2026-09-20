/**
 * Pure, GPU-free twins of the volumetric kernel's math — unit-testable and the
 * single source of truth the GLSL constants mirror. No allocation.
 */

/** Light-orbit geometry (mirrors GLSL lightOrbit). */
export const ORBIT_SPEED = 0.06;
export const ORBIT_CENTER: readonly [number, number, number] = [0.0, 0.35, 2.6];
export const ORBIT_RADIUS: readonly [number, number, number] = [1.7, 0.55, 0.9];

/** Light position at time `tSec` (no pointer/scroll). Mirrors GLSL lightOrbit. */
export function lightOrbit(tSec: number): [number, number, number] {
  const a = tSec * ORBIT_SPEED;
  return [
    ORBIT_CENTER[0] + ORBIT_RADIUS[0] * Math.cos(a),
    ORBIT_CENTER[1] + ORBIT_RADIUS[1] * Math.sin(a * 0.7),
    ORBIT_CENTER[2] + ORBIT_RADIUS[2] * Math.sin(a * 0.4),
  ];
}

/** Jimenez interleaved gradient noise constants (verifies the magic numbers). */
export const IGN_MAGIC = 52.9829189;
export const IGN_FX = 0.06711056;
export const IGN_FY = 0.00583715;

/** Interleaved gradient noise — static spatial jitter (no time term ⇒ stable). */
export function ign(x: number, y: number): number {
  const fract = (v: number) => v - Math.floor(v);
  return fract(IGN_MAGIC * fract(IGN_FX * x + IGN_FY * y));
}

/** Beer–Lambert transmittance for a given optical depth. */
export function beerLambert(opticalDepth: number): number {
  return Math.exp(-opticalDepth);
}

/** Irrational-ratio breath LFO in [0.86, 1.18] (mirrors GLSL breath). */
export function breathAt(tSec: number): number {
  const u =
    0.5 +
    0.5 * (0.62 * Math.sin(tSec * 0.2244) + 0.38 * Math.sin(tSec * 0.1013 + 1.3));
  return 0.86 + (1.18 - 0.86) * Math.min(Math.max(u, 0), 1);
}
