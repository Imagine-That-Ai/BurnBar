import assert from "node:assert/strict";
import test from "node:test";

import {
  cloakVector,
  cosineSimilarity,
  createDeterministicHashingEmbedder,
  embedAndCloak,
  l2normalize,
  EMBEDDING_DIM,
} from "./embed.js";

const KEY_A = Buffer.alloc(32, 7);
const KEY_B = Buffer.alloc(32, 9);

/** Deterministic pseudo-random vector (no crypto needed for the math properties). */
function pseudoVector(seed: number, dim = EMBEDDING_DIM): number[] {
  const v: number[] = [];
  let s = seed >>> 0;
  for (let i = 0; i < dim; i += 1) {
    s = (1103515245 * s + 12345) & 0x7fffffff;
    v.push((s / 0x7fffffff) * 2 - 1);
  }
  return v;
}

test("cloaking preserves cosine similarity to floating-point precision", () => {
  for (let i = 0; i < 12; i += 1) {
    const a = pseudoVector(i * 31 + 1);
    const b = pseudoVector(i * 97 + 5);
    const before = cosineSimilarity(a, b);
    const after = cosineSimilarity(
      cloakVector(a, { vaultKey: KEY_A }),
      cloakVector(b, { vaultKey: KEY_A }),
    );
    assert.ok(
      Math.abs(before - after) < 1e-9,
      `cosine drift ${Math.abs(before - after)} exceeds tolerance (before=${before}, after=${after})`,
    );
  }
});

test("cloaking preserves L2 norm (orthogonal transform)", () => {
  const a = pseudoVector(42);
  const normBefore = Math.sqrt(a.reduce((s, x) => s + x * x, 0));
  const cloaked = cloakVector(a, { vaultKey: KEY_A });
  const normAfter = Math.sqrt(Array.from(cloaked).reduce((s, x) => s + x * x, 0));
  assert.ok(Math.abs(normBefore - normAfter) < 1e-9, `norm drift: ${normBefore} -> ${normAfter}`);
});

test("cloaking preserves nearest-neighbour ranking exactly", () => {
  const query = pseudoVector(1000);
  const corpus = Array.from({ length: 20 }, (_, i) => pseudoVector(i * 13 + 3));

  const rankRaw = corpus
    .map((v, i) => ({ i, score: cosineSimilarity(query, v) }))
    .sort((x, y) => y.score - x.score)
    .map((r) => r.i);

  const cQuery = cloakVector(query, { vaultKey: KEY_A });
  const rankCloaked = corpus
    .map((v, i) => ({ i, score: cosineSimilarity(cQuery, cloakVector(v, { vaultKey: KEY_A })) }))
    .sort((x, y) => y.score - x.score)
    .map((r) => r.i);

  assert.deepEqual(rankCloaked, rankRaw, "ANN ranking over cloaked vectors must match raw-space ranking");
});

test("cloaking is deterministic for a given key + model version", () => {
  const a = pseudoVector(7);
  const c1 = Array.from(cloakVector(a, { vaultKey: KEY_A }));
  const c2 = Array.from(cloakVector(a, { vaultKey: KEY_A }));
  assert.deepEqual(c1, c2);
});

test("different vault keys produce different cloaked vectors (per-user isolation)", () => {
  const a = pseudoVector(7);
  const cA = Array.from(cloakVector(a, { vaultKey: KEY_A }));
  const cB = Array.from(cloakVector(a, { vaultKey: KEY_B }));
  const identical = cA.every((x, i) => Math.abs(x - cB[i]) < 1e-12);
  assert.ok(!identical, "two distinct keys must yield distinct cloaks");
  // ...yet each key independently still preserves cosine internally.
  const b = pseudoVector(8);
  const raw = cosineSimilarity(a, b);
  const viaB = cosineSimilarity(cloakVector(a, { vaultKey: KEY_B }), cloakVector(b, { vaultKey: KEY_B }));
  assert.ok(Math.abs(raw - viaB) < 1e-9);
});

test("cloaking genuinely mixes coordinates (not a signed permutation)", () => {
  // A signed permutation would preserve the multiset of |coordinate| values.
  // A Householder product must not.
  const a = pseudoVector(123);
  const cloaked = Array.from(cloakVector(a, { vaultKey: KEY_A }));
  const sortedAbsBefore = a.map(Math.abs).sort((x, y) => x - y);
  const sortedAbsAfter = cloaked.map(Math.abs).sort((x, y) => x - y);
  let maxDelta = 0;
  for (let i = 0; i < sortedAbsBefore.length; i += 1) {
    maxDelta = Math.max(maxDelta, Math.abs(sortedAbsBefore[i] - sortedAbsAfter[i]));
  }
  assert.ok(maxDelta > 1e-3, "coordinate magnitudes must be remixed, not merely shuffled/flipped");
});

test("deterministic hashing embedder: stable, normalized, query/doc asymmetry, version tag", async () => {
  const embedder = createDeterministicHashingEmbedder();
  assert.equal(embedder.modelVersion, "hashing-bow-v1");
  assert.equal(embedder.dim, EMBEDDING_DIM);

  const [v1] = await embedder.embed(["vault key rotation runbook"]);
  const [v1again] = await embedder.embed(["vault key rotation runbook"]);
  assert.deepEqual(v1, v1again, "embedding must be deterministic");

  const norm = Math.sqrt(v1.reduce((s, x) => s + x * x, 0));
  assert.ok(Math.abs(norm - 1) < 1e-9, "embedding must be L2-normalized");

  const [asDoc] = await embedder.embed(["hello world"], { isQuery: false });
  const [asQuery] = await embedder.embed(["hello world"], { isQuery: true });
  assert.notDeepEqual(asDoc, asQuery, "query instruction prefix must change the embedding");
});

test("embedAndCloak round-trips through the cloak with version tag and preserves cosine", async () => {
  const embedder = createDeterministicHashingEmbedder();
  const docs = ["how to rotate the vault key", "android billing flow", "vault key rotation steps"];
  const { modelVersion, vectors } = await embedAndCloak(docs, embedder, { vaultKey: KEY_A });
  assert.equal(modelVersion, "hashing-bow-v1");
  assert.equal(vectors.length, 3);
  assert.equal(vectors[0].length, EMBEDDING_DIM);

  // Doc 0 and doc 2 are about the same topic -> should be the closest pair, and
  // that relationship must survive cloaking.
  const raw = await embedder.embed(docs);
  const rawSim02 = cosineSimilarity(raw[0], raw[2]);
  const rawSim01 = cosineSimilarity(raw[0], raw[1]);
  const cloakSim02 = cosineSimilarity(vectors[0], vectors[2]);
  const cloakSim01 = cosineSimilarity(vectors[0], vectors[1]);
  assert.ok(rawSim02 > rawSim01, "fixture sanity: doc0~doc2 closer than doc0~doc1");
  assert.ok(Math.abs(rawSim02 - cloakSim02) < 1e-9);
  assert.ok(Math.abs(rawSim01 - cloakSim01) < 1e-9);
});

test("l2normalize returns a unit vector and tolerates the zero vector", () => {
  const unit = l2normalize([3, 4]);
  assert.ok(Math.abs(Math.hypot(unit[0], unit[1]) - 1) < 1e-12);
  const zero = l2normalize([0, 0, 0]);
  assert.deepEqual(Array.from(zero), [0, 0, 0]);
});
