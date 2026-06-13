/**
 * PROOF test for the rewritten cloak claim (B-SEC-1).
 *
 * The honest claims, pinned here so the docs can never drift back to the old
 * over-sold "inversion-proof" / "cross-tenant unlinkability" framing:
 *
 *   (a) GEOMETRY IS PRESERVED EXACTLY. Because Q is orthonormal,
 *       cos(Qx, Qy) == cos(x, y) within 1e-9. This is THE property the rewritten
 *       claim is built around: it is simultaneously the recall feature and the
 *       accepted leakage (a server can compute the full pairwise-cosine / k-NN /
 *       cluster graph over cloaked vectors WITHOUT the key).
 *
 *   (b) PER-USER Q ⇒ DISTINCT STORED BYTES, but NOT decorrelation. The same
 *       plaintext under two keys yields byte-distinct vectors (defeats
 *       exact-match cross-tenant joins). HOWEVER, with the shipped
 *       CLOAK_REFLECTIONS=24 in 384-dim, the cross-tenant cosine is ~0.77 — the
 *       cloak does NOT give full cross-tenant unlinkability. This test measures
 *       and pins that reality so the security claim stays honest. (A naive
 *       earlier version of this task asserted cross-user cosine ≈ 0; that is
 *       FALSE for 24 reflections — see docs/pensieve-leakage-analysis.md.)
 *
 * Runner is `node --test` over compiled lib/*.test.js (NOT vitest); reuses the
 * real exports from embed.ts. Keys are fixed constants so every bound is
 * deterministic and never flakes.
 */
import assert from "node:assert/strict";
import test from "node:test";

import { cloakVector, cosineSimilarity, EMBEDDING_DIM } from "./embed.js";

// Fixed, deterministic vault keys — distinct byte fills so the two derived Qs
// differ. Constants (not random) keep every bound non-flaky.
const KEY_USER_A = Buffer.alloc(32, 0x11);
const KEY_USER_B = Buffer.alloc(32, 0x22);

/** Deterministic pseudo-random vector in [-1, 1]^dim (LCG; no crypto needed). */
function pseudoVector(seed: number, dim = EMBEDDING_DIM): number[] {
  const v: number[] = [];
  let s = seed >>> 0;
  for (let i = 0; i < dim; i += 1) {
    s = (1103515245 * s + 12345) & 0x7fffffff;
    v.push((s / 0x7fffffff) * 2 - 1);
  }
  return v;
}

function l2(v: ArrayLike<number>): number {
  let n = 0;
  for (let i = 0; i < v.length; i += 1) {n += v[i] * v[i];}
  return Math.sqrt(n);
}

test("PROOF (a): cloak preserves pairwise cosine within 1e-9 (geometry is NOT hidden)", () => {
  // The property the rewritten claim is built around: <Qx,Qy>=<x,y>, so a server
  // holding cloaked vectors can compute the full pairwise cosine / k-NN /
  // clustering graph WITHOUT the key.
  let maxDrift = 0;
  for (let i = 0; i < 16; i += 1) {
    const a = pseudoVector(i * 31 + 1);
    const b = pseudoVector(i * 97 + 5);
    const before = cosineSimilarity(a, b);
    const after = cosineSimilarity(
      cloakVector(a, { vaultKey: KEY_USER_A }),
      cloakVector(b, { vaultKey: KEY_USER_A }),
    );
    const drift = Math.abs(before - after);
    maxDrift = Math.max(maxDrift, drift);
    assert.ok(
      drift < 1e-9,
      `cosine drift ${drift} exceeds 1e-9 (before=${before}, after=${after}) — geometry must be preserved exactly`,
    );
  }
  assert.ok(maxDrift < 1e-9, `worst-case drift ${maxDrift} must stay below 1e-9`);
});

test("PROOF (b): per-user Q yields byte-distinct stored vectors (defeats exact-match cross-tenant joins)", () => {
  // Distinct keys must never produce the same stored bytes for the same input,
  // and the difference must be substantial, not a rounding wobble.
  for (const seed of [1, 7, 42, 997]) {
    const x = pseudoVector(seed);
    const underA = Array.from(cloakVector(x, { vaultKey: KEY_USER_A }));
    const underB = Array.from(cloakVector(x, { vaultKey: KEY_USER_B }));
    const identical = underA.every((z, i) => Math.abs(z - underB[i]) < 1e-12);
    assert.ok(!identical, `seed ${seed}: two distinct keys must yield distinct stored vectors`);

    // Relative L2 separation ‖Q_A x − Q_B x‖ / ‖x‖ is large (~0.74 in 384-dim).
    const diff = underA.map((z, i) => z - underB[i]);
    const rel = l2(diff) / l2(x);
    assert.ok(rel > 0.3, `seed ${seed}: per-user stored vectors too close (relative L2 ${rel.toFixed(3)})`);
  }
});

test("PROOF (b): cross-tenant cosine is HIGH at 24 reflections — cloak does NOT give full unlinkability", () => {
  // HONEST NEGATIVE PROOF. cos(Q_A x, Q_B x) = cos(x, Q_Aᵀ Q_B x). With only 24
  // Householder reflections per user in 384-dim, Q_Aᵀ Q_B is far from a
  // Haar-random rotation, so the same plaintext stays cosine-correlated across
  // tenants. We pin the measured band (~0.77) to keep the security claim honest:
  // similarity-based cross-tenant linkage is NOT defeated by the shipped cloak.
  // (To reach |cos| < 0.2 you need ~dim reflections — see leakage analysis.)
  const seeds = [1, 2, 3, 7, 11, 13, 101, 997];
  let sumAbs = 0;
  let minAbs = Infinity;
  let maxAbs = 0;
  for (const seed of seeds) {
    const x = pseudoVector(seed);
    const cos = cosineSimilarity(
      cloakVector(x, { vaultKey: KEY_USER_A }),
      cloakVector(x, { vaultKey: KEY_USER_B }),
    );
    const a = Math.abs(cos);
    sumAbs += a;
    minAbs = Math.min(minAbs, a);
    maxAbs = Math.max(maxAbs, a);
  }
  const meanAbs = sumAbs / seeds.length;
  // Lower bound: prove the leak is real (NOT near-zero). Upper bound: stays well
  // below 1, i.e. the keys genuinely differ. Bounds are wide enough to never
  // flake on these fixed seeds while still pinning the documented ~0.77 band.
  assert.ok(
    meanAbs > 0.5,
    `mean cross-tenant |cos| ${meanAbs.toFixed(3)} should be HIGH (~0.77) — the cloak does not decorrelate at 24 reflections`,
  );
  assert.ok(
    maxAbs < 0.95,
    `cross-tenant |cos| max ${maxAbs.toFixed(3)} too high — distinct keys must still produce distinct rotations`,
  );
  assert.ok(minAbs > 0.4, `cross-tenant |cos| min ${minAbs.toFixed(3)} unexpectedly low for these fixtures`);
});

test("PROOF (b'): within each user, geometry is preserved exactly (the high cross-tenant cos is NOT geometry loss)", () => {
  // Guard: the cross-tenant correlation above is a property of Q_Aᵀ Q_B, not of
  // the cloak destroying geometry — each user independently preserves cosine.
  const a = pseudoVector(555);
  const b = pseudoVector(777);
  const raw = cosineSimilarity(a, b);
  const viaA = cosineSimilarity(
    cloakVector(a, { vaultKey: KEY_USER_A }),
    cloakVector(b, { vaultKey: KEY_USER_A }),
  );
  const viaB = cosineSimilarity(
    cloakVector(a, { vaultKey: KEY_USER_B }),
    cloakVector(b, { vaultKey: KEY_USER_B }),
  );
  assert.ok(Math.abs(raw - viaA) < 1e-9, "user A must preserve pairwise cosine");
  assert.ok(Math.abs(raw - viaB) < 1e-9, "user B must preserve pairwise cosine");
});
