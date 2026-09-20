/**
 * Void-and-cluster blue-noise tile generator (Ulichney 1993; Wolfe 2019).
 *
 * Pure, deterministic (seeded `mulberry32`), toroidal ⇒ the output tile is
 * seamlessly tileable. Returns a `Uint8Array` of `size·size` grayscale
 * ranks→values. Vitest-testable against the §8 properties (flat 256-bucket
 * histogram, blue spectral profile, toroidal seam, determinism).
 *
 * Pipeline (Ulichney's three ranking phases):
 *   0. seed ~initialDensity random ones, then RELAX to a "prototype binary
 *      pattern" by repeatedly moving the tightest-cluster one into the largest-
 *      void hole until the two stop interacting (the canonical fixed point).
 *   1. phase 1 — remove tightest clusters from the prototype, ranking downward.
 *   2. phase 2 — re-add into largest voids from the prototype, ranking upward.
 *   3. phase 3 — past half, rank the largest void *of the zero set* (the
 *      minority-cluster center = min-energy zero cell).
 *   4. rank → value: v = floor(rank * 256 / N), clamped 0..255 ⇒ flat histogram.
 *
 * The Gaussian splat is precomputed into a toroidal-offset LUT once per `size`
 * so each add/remove of a 1 is O(R²) table adds (no `exp` in the hot loop). A
 * 64² bake runs in ~1–2s — fine for the offline bake script, never at module
 * load. Each function stays well under cyclomatic complexity 15.
 */

const SIGMA = 1.9; // demofox / momentsingraphics recommendation
const ENERGY_DIV = 2 * SIGMA * SIGMA; // 7.22 — Gaussian denominator
/** Gaussian is ~0 past ~3σ; clamp the splat kernel radius to keep the LUT small. */
const KERNEL_RADIUS = Math.ceil(3 * SIGMA); // 6 px ⇒ 13×13 toroidal stamp

export interface BlueNoiseOptions {
  size: number;
  seed?: number;
  /** Fraction of cells seeded as ones for the initial pattern (Ulichney ~0.1). */
  initialDensity?: number;
}

/** Standard mulberry32 — deterministic 32-bit PRNG (seedable, no global state). */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

interface Kernel {
  weights: Float32Array;
  r: number;
}

/**
 * Precompute the Gaussian splat as a (2R+1)² table of weights indexed by
 * toroidal offset (dx,dy) ∈ [-R,R]². Adding a one at (x,y) adds this stamp to
 * the energy field (wrapping at the torus edges); removing subtracts it.
 */
function buildKernel(): Kernel {
  const r = KERNEL_RADIUS;
  const w = 2 * r + 1;
  const weights = new Float32Array(w * w);
  for (let dy = -r; dy <= r; dy++) {
    for (let dx = -r; dx <= r; dx++) {
      weights[(dy + r) * w + (dx + r)] = Math.exp(
        -(dx * dx + dy * dy) / ENERGY_DIV
      );
    }
  }
  return { weights, r };
}

/** Add (sign=+1) or remove (sign=-1) a sample's Gaussian energy, toroidally wrapped. */
function splat(
  energy: Float32Array,
  size: number,
  kernel: Kernel,
  x: number,
  y: number,
  sign: number
): void {
  const { weights, r } = kernel;
  const w = 2 * r + 1;
  for (let dy = -r; dy <= r; dy++) {
    const ny = (((y + dy) % size) + size) % size;
    const row = ny * size;
    const krow = (dy + r) * w;
    for (let dx = -r; dx <= r; dx++) {
      const nx = (((x + dx) % size) + size) % size;
      energy[row + nx] = (energy[row + nx] ?? 0) + sign * weights[krow + (dx + r)]!;
    }
  }
}

/** Index of the tightest cluster: max energy among set cells (ones[i] === 1). */
function tightestCluster(energy: Float32Array, ones: Uint8Array): number {
  let best = -1;
  let bestE = -Infinity;
  for (let i = 0; i < ones.length; i++) {
    if (ones[i] === 1 && energy[i]! > bestE) {
      bestE = energy[i]!;
      best = i;
    }
  }
  return best;
}

/** Index of the largest void: min energy among empty cells (ones[i] === 0). */
function largestVoid(energy: Float32Array, ones: Uint8Array): number {
  let best = -1;
  let bestE = Infinity;
  for (let i = 0; i < ones.length; i++) {
    if (ones[i] === 0 && energy[i]! < bestE) {
      bestE = energy[i]!;
      best = i;
    }
  }
  return best;
}

/** Seed ~initialDensity random ones and build the matching energy field. */
function seedPattern(
  size: number,
  energy: Float32Array,
  ones: Uint8Array,
  kernel: Kernel,
  rng: () => number,
  density: number
): number {
  const n = size * size;
  const target = Math.max(1, Math.round(n * density));
  let count = 0;
  while (count < target) {
    const i = Math.floor(rng() * n);
    if (ones[i] === 0) {
      ones[i] = 1;
      splat(energy, size, kernel, i % size, Math.floor(i / size), +1);
      count++;
    }
  }
  return count;
}

/**
 * Relax the seeded pattern to Ulichney's "prototype binary pattern": repeatedly
 * move the tightest-cluster one into the largest-void hole. Terminates when the
 * removed cell *is itself* the largest void (moving it back would be a no-op).
 */
function relaxToPrototype(
  size: number,
  energy: Float32Array,
  ones: Uint8Array,
  kernel: Kernel
): void {
  // Bounded iteration guard: the swap loop always terminates at the fixed point,
  // but cap defensively against pathological seeds.
  for (let guard = 0; guard < size * size; guard++) {
    const tight = tightestCluster(energy, ones);
    if (tight < 0) break;
    ones[tight] = 0;
    splat(energy, size, kernel, tight % size, Math.floor(tight / size), -1);
    const voidIdx = largestVoid(energy, ones);
    if (voidIdx < 0) break;
    if (voidIdx === tight) {
      ones[tight] = 1;
      splat(energy, size, kernel, tight % size, Math.floor(tight / size), +1);
      break;
    }
    ones[voidIdx] = 1;
    splat(energy, size, kernel, voidIdx % size, Math.floor(voidIdx / size), +1);
  }
}

/** Generate a tileable blue-noise tile. Returns `Uint8Array(size*size)` in 0..255. */
export function generateBlueNoiseTile(opts: BlueNoiseOptions): Uint8Array {
  const { size, seed = 1, initialDensity = 0.1 } = opts;
  const n = size * size;
  const kernel = buildKernel();
  const rng = mulberry32(seed);

  const energy = new Float32Array(n);
  const ones = new Uint8Array(n);
  const rank = new Int32Array(n).fill(-1);

  // 0. Seed + relax to the prototype binary pattern.
  const initialOnes = seedPattern(size, energy, ones, kernel, rng, initialDensity);
  relaxToPrototype(size, energy, ones, kernel);

  // Snapshot the prototype (phases 1 and 2 both start from it).
  const prototype = ones.slice();
  const protoEnergy = energy.slice();

  // 1. PHASE 1 — remove tightest clusters; rank downward.
  //    Ranks [initialOnes-1 … 0]. The prototype's ones carry ranks 0..initialOnes-1.
  let remaining = initialOnes;
  while (remaining > 0) {
    const tight = tightestCluster(energy, ones);
    if (tight < 0) break;
    remaining--;
    rank[tight] = remaining;
    ones[tight] = 0;
    splat(energy, size, kernel, tight % size, Math.floor(tight / size), -1);
  }

  // 2. PHASE 2 — from the prototype, insert into the largest void; rank upward to half.
  //    Ranks [initialOnes … ⌈n/2⌉-1].
  ones.set(prototype);
  energy.set(protoEnergy);
  const half = Math.ceil(n / 2);
  for (let r = initialOnes; r < half; r++) {
    const voidIdx = largestVoid(energy, ones);
    if (voidIdx < 0) break;
    rank[voidIdx] = r;
    ones[voidIdx] = 1;
    splat(energy, size, kernel, voidIdx % size, Math.floor(voidIdx / size), +1);
  }

  // 3. PHASE 3 — past half, rank the largest void of the ZERO set (cluster-of-zeros).
  //    The still-empty cell with the LOWEST energy is exactly that minority-cluster
  //    center (every placed one is already splatted into the energy field), so
  //    largestVoid (argmin over zeros) selects it directly.
  for (let r = half; r < n; r++) {
    const voidIdx = largestVoid(energy, ones);
    if (voidIdx < 0) break;
    rank[voidIdx] = r;
    ones[voidIdx] = 1;
    splat(energy, size, kernel, voidIdx % size, Math.floor(voidIdx / size), +1);
  }

  // 4. rank → 8-bit value: flat 256-bucket histogram by construction.
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    out[i] = Math.min(255, Math.floor((rank[i]! * 256) / n));
  }
  return out;
}
