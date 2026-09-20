/**
 * Compact simplex noise (2D + 3D) and a divergence-free 2D curl field.
 *
 * Adapted from Stefan Gustavson's public-domain reference implementation.
 * Deterministic (fixed permutation table) so simulations are reproducible
 * and unit-testable. Pure math — no DOM, no allocation in the hot path.
 *
 * The curl field drives the flow-field and constellation kernels: sampling
 * the curl of a scalar potential yields a smooth, swirling, *incompressible*
 * vector field (particles flow without piling up), which is what reads as
 * "mesmerizing" rather than "noisy".
 */

const GRAD3 = new Float32Array([
  1, 1, 0, -1, 1, 0, 1, -1, 0, -1, -1, 0, 1, 0, 1, -1, 0, 1, 1, 0, -1, -1, 0,
  -1, 0, 1, 1, 0, -1, 1, 0, 1, -1, 0, -1, -1,
]);

// Base permutation (Ken Perlin's reference table).
const PERM_SOURCE = [
  151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140,
  36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234,
  75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237,
  149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48,
  27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105,
  92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73,
  209, 76, 132, 187, 208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86,
  164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38,
  147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189,
  28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153,
  101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224,
  232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144,
  12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214,
  31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150,
  254, 138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66,
  215, 61, 156, 180,
];

// Doubled tables avoid index wrapping in the inner loops.
const perm = new Uint8Array(512);
const permMod12 = new Uint8Array(512);
for (let i = 0; i < 512; i++) {
  const v = PERM_SOURCE[i & 255]!;
  perm[i] = v;
  permMod12[i] = v % 12;
}

const F2 = 0.5 * (Math.sqrt(3) - 1);
const G2 = (3 - Math.sqrt(3)) / 6;
const F3 = 1 / 3;
const G3 = 1 / 6;

// perm/permMod12 are 512-entry doubled tables; simplex indices always land in range.
function permLookup(i: number): number {
  return perm[i]!;
}

function permMod12Lookup(i: number): number {
  return permMod12[i]!;
}

function gradDot2(gi: number, x: number, y: number): number {
  return GRAD3[gi]! * x + GRAD3[gi + 1]! * y;
}

function gradDot3(gi: number, x: number, y: number, z: number): number {
  return GRAD3[gi]! * x + GRAD3[gi + 1]! * y + GRAD3[gi + 2]! * z;
}

/** 2D simplex noise in roughly [-1, 1]. */
export function noise2(xin: number, yin: number): number {
  let n0 = 0;
  let n1 = 0;
  let n2 = 0;

  const s = (xin + yin) * F2;
  const i = Math.floor(xin + s);
  const j = Math.floor(yin + s);
  const t = (i + j) * G2;
  const x0 = xin - (i - t);
  const y0 = yin - (j - t);

  let i1: number;
  let j1: number;
  if (x0 > y0) {
    i1 = 1;
    j1 = 0;
  } else {
    i1 = 0;
    j1 = 1;
  }

  const x1 = x0 - i1 + G2;
  const y1 = y0 - j1 + G2;
  const x2 = x0 - 1 + 2 * G2;
  const y2 = y0 - 1 + 2 * G2;

  const ii = i & 255;
  const jj = j & 255;

  let t0 = 0.5 - x0 * x0 - y0 * y0;
  if (t0 >= 0) {
    const gi0 = permMod12Lookup(ii + permLookup(jj)) * 3;
    t0 *= t0;
    n0 = t0 * t0 * gradDot2(gi0, x0, y0);
  }
  let t1 = 0.5 - x1 * x1 - y1 * y1;
  if (t1 >= 0) {
    const gi1 = permMod12Lookup(ii + i1 + permLookup(jj + j1)) * 3;
    t1 *= t1;
    n1 = t1 * t1 * gradDot2(gi1, x1, y1);
  }
  let t2 = 0.5 - x2 * x2 - y2 * y2;
  if (t2 >= 0) {
    const gi2 = permMod12Lookup(ii + 1 + permLookup(jj + 1)) * 3;
    t2 *= t2;
    n2 = t2 * t2 * gradDot2(gi2, x2, y2);
  }
  return 70 * (n0 + n1 + n2);
}

/** 3D simplex noise in roughly [-1, 1]. */
export function noise3(xin: number, yin: number, zin: number): number {
  let n0 = 0;
  let n1 = 0;
  let n2 = 0;
  let n3 = 0;

  const s = (xin + yin + zin) * F3;
  const i = Math.floor(xin + s);
  const j = Math.floor(yin + s);
  const k = Math.floor(zin + s);
  const t = (i + j + k) * G3;
  const x0 = xin - (i - t);
  const y0 = yin - (j - t);
  const z0 = zin - (k - t);

  let i1: number;
  let j1: number;
  let k1: number;
  let i2: number;
  let j2: number;
  let k2: number;
  if (x0 >= y0) {
    if (y0 >= z0) {
      i1 = 1; j1 = 0; k1 = 0; i2 = 1; j2 = 1; k2 = 0;
    } else if (x0 >= z0) {
      i1 = 1; j1 = 0; k1 = 0; i2 = 1; j2 = 0; k2 = 1;
    } else {
      i1 = 0; j1 = 0; k1 = 1; i2 = 1; j2 = 0; k2 = 1;
    }
  } else {
    if (y0 < z0) {
      i1 = 0; j1 = 0; k1 = 1; i2 = 0; j2 = 1; k2 = 1;
    } else if (x0 < z0) {
      i1 = 0; j1 = 1; k1 = 0; i2 = 0; j2 = 1; k2 = 1;
    } else {
      i1 = 0; j1 = 1; k1 = 0; i2 = 1; j2 = 1; k2 = 0;
    }
  }

  const x1 = x0 - i1 + G3;
  const y1 = y0 - j1 + G3;
  const z1 = z0 - k1 + G3;
  const x2 = x0 - i2 + 2 * G3;
  const y2 = y0 - j2 + 2 * G3;
  const z2 = z0 - k2 + 2 * G3;
  const x3 = x0 - 1 + 3 * G3;
  const y3 = y0 - 1 + 3 * G3;
  const z3 = z0 - 1 + 3 * G3;

  const ii = i & 255;
  const jj = j & 255;
  const kk = k & 255;

  let t0 = 0.6 - x0 * x0 - y0 * y0 - z0 * z0;
  if (t0 >= 0) {
    const gi0 = permMod12Lookup(ii + permLookup(jj + permLookup(kk))) * 3;
    t0 *= t0;
    n0 = t0 * t0 * gradDot3(gi0, x0, y0, z0);
  }
  let t1 = 0.6 - x1 * x1 - y1 * y1 - z1 * z1;
  if (t1 >= 0) {
    const gi1 = permMod12Lookup(ii + i1 + permLookup(jj + j1 + permLookup(kk + k1))) * 3;
    t1 *= t1;
    n1 = t1 * t1 * gradDot3(gi1, x1, y1, z1);
  }
  let t2 = 0.6 - x2 * x2 - y2 * y2 - z2 * z2;
  if (t2 >= 0) {
    const gi2 = permMod12Lookup(ii + i2 + permLookup(jj + j2 + permLookup(kk + k2))) * 3;
    t2 *= t2;
    n2 = t2 * t2 * gradDot3(gi2, x2, y2, z2);
  }
  let t3 = 0.6 - x3 * x3 - y3 * y3 - z3 * z3;
  if (t3 >= 0) {
    const gi3 = permMod12Lookup(ii + 1 + permLookup(jj + 1 + permLookup(kk + 1))) * 3;
    t3 *= t3;
    n3 = t3 * t3 * gradDot3(gi3, x3, y3, z3);
  }
  return 32 * (n0 + n1 + n2 + n3);
}

/**
 * Divergence-free 2D curl of a scalar potential field `P(x, y, t)` sampled
 * from 3D simplex noise (z = time). Returns a unit-ish flow vector written
 * into `out` = [vx, vy]. `eps` is the finite-difference step.
 */
const EPS = 1e-3;
export function curl2(
  x: number,
  y: number,
  t: number,
  out: [number, number] = [0, 0]
): [number, number] {
  // ∂P/∂y and ∂P/∂x via central differences; curl = (∂P/∂y, -∂P/∂x).
  const n1 = noise3(x, y + EPS, t);
  const n2 = noise3(x, y - EPS, t);
  const dPdy = (n1 - n2) / (2 * EPS);

  const n3 = noise3(x + EPS, y, t);
  const n4 = noise3(x - EPS, y, t);
  const dPdx = (n3 - n4) / (2 * EPS);

  out[0] = dPdy;
  out[1] = -dPdx;
  return out;
}

/** Fractal Brownian motion over 2D simplex — layered detail in [-1, 1]. */
export function fbm2(
  x: number,
  y: number,
  octaves = 4,
  lacunarity = 2,
  gain = 0.5
): number {
  let amp = 0.5;
  let freq = 1;
  let sum = 0;
  for (let o = 0; o < octaves; o++) {
    sum += amp * noise2(x * freq, y * freq);
    freq *= lacunarity;
    amp *= gain;
  }
  return sum;
}
