/**
 * Pure CPU mirror of the moiré quasicrystal math (stream 02).
 *
 * The GLSL kernel renders the *band-limited* sum; this module is the
 * GPU-free reference for the un-filtered wave set + value, so the quasicrystal
 * geometry (even π/N spacing, golden-angle phases, boundedness, symmetry) is
 * unit-testable without a WebGL context — exactly how `simplex.ts` is tested.
 *
 * `N` equally-rotated plane waves at angles `θⱼ = π·j/N + spin` (the de Bruijn
 * dual-grid construction) form an aperiodic field with 2N-fold rotational
 * symmetry. Odd `N` (5, 7) gives the iconic Penrose-like quasi*periodic* look;
 * `N=4,6` degenerates toward a periodic crystallographic lattice (avoided).
 */

/** Golden angle π(3−√5) ≈ 2.399963 rad — per-wave phase seed (decorrelates phases). */
export const QC_GOLDEN = Math.PI * (3 - Math.sqrt(5));
/** Number of plane waves (14-fold quasiperiodic symmetry; odd ⇒ Penrose-like). */
export const QC_WAVES = 7;
/** Base spatial frequency of each wave (≈ "stripes"). */
export const QC_FREQ = 9.0;

export interface QuasicrystalWave {
  /** Direction angle (rad). */
  angle: number;
  /** Wave-vector x,y (|k| = freq). */
  kx: number;
  ky: number;
  /** Golden-angle phase seed (rad). */
  phase: number;
}

/** Generate the `n` equally-rotated wave-vectors + golden phase seeds (mirrors
 *  the GLSL STEP 3 sum). `spin` rotates the whole basis (the authentic QC
 *  animation clock); it must NOT perturb the per-wave spacing. */
export function quasicrystalWaves(
  n: number = QC_WAVES,
  freq: number = QC_FREQ,
  spin = 0
): QuasicrystalWave[] {
  const out: QuasicrystalWave[] = [];
  for (let j = 0; j < n; j++) {
    const angle = (Math.PI * j) / n + spin;
    out.push({
      angle,
      kx: Math.cos(angle) * freq,
      ky: Math.sin(angle) * freq,
      phase: j * QC_GOLDEN,
    });
  }
  return out;
}

/** Raw (un-filtered) quasicrystal value at (x,y) — reference for the GLSL sum,
 *  ≈ [−1, 1] (the mean of `n` unit cosines). `scrub` is the global phase drift. */
export function quasicrystalValue(
  waves: QuasicrystalWave[],
  x: number,
  y: number,
  scrub = 0
): number {
  let q = 0;
  for (const w of waves) {
    q += Math.cos(w.kx * x + w.ky * y + w.phase + scrub);
  }
  return q / waves.length;
}
