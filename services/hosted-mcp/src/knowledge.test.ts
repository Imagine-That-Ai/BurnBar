import assert from "node:assert/strict";
import test from "node:test";

import {
  searchKnowledge,
  readKnowledgeDocument,
  type KnowledgeDocumentFirestore,
  type KnowledgeSearchFirestore,
  type KnowledgeVectorQuery,
} from "./knowledge.js";
import { cosineSimilarity } from "./knowledgeVector.js";
import { signCursor } from "./cursors.js";

interface StubRow {
  ns: string;
  id: string;
  embedding: number[];
  fields: Record<string, unknown>;
}

type StubDb = KnowledgeSearchFirestore & KnowledgeDocumentFirestore;

function vectorArray(raw: unknown): number[] {
  if (Array.isArray(raw)) {return raw.map(Number);}
  if (typeof raw === "object" && raw !== null) {
    const toArray = Reflect.get(raw, "toArray");
    if (typeof toArray === "function") {
      const vector = Reflect.apply(toArray, raw, []);
      if (Array.isArray(vector)) {return vector.map(Number);}
    }
  }
  return [];
}

/** A Firestore stub supporting collection().where().findNearest().get() and doc().get(). */
function makeStubDb(rows: StubRow[]): StubDb {
  function makeQuery(ns: string, filtered: StubRow[]): KnowledgeVectorQuery {
    return {
      where(field: string, _op: "==", value: unknown) {
        return makeQuery(ns, filtered.filter((r) => r.fields[field] === value));
      },
      findNearest({ queryVector, limit, distanceResultField }) {
        const qv = vectorArray(queryVector);
        const ranked = filtered
          .map((r) => ({ r, sim: cosineSimilarity(qv, r.embedding) }))
          .sort((a, b) => b.sim - a.sim)
          .slice(0, limit);
        return {
          async get() {
            return {
              size: ranked.length,
              docs: ranked.map(({ r, sim }) => ({
                id: r.id,
                get: (f: string) => (f === distanceResultField ? 1 - sim : r.fields[f]),
              })),
            };
          },
        };
      },
    };
  }
  function nsFromPath(path: string): string {
    const m = /^users\/([^/]+)\//u.exec(path);
    return m ? m[1] : "";
  }
  return {
    collection(path: string) {
      const ns = nsFromPath(path);
      return makeQuery(ns, rows.filter((r) => r.ns === ns));
    },
    doc(path: string) {
      const ns = nsFromPath(path);
      const id = path.split("/").pop() ?? "";
      const row = rows.find((r) => r.ns === ns && r.id === id);
      return {
        async get() {
          return { exists: !!row, data: () => (row ? row.fields : undefined) };
        },
      };
    },
  };
}

function row(ns: string, id: string, embedding: number[], over: Record<string, unknown> = {}): StubRow {
  return {
    ns,
    id,
    embedding,
    fields: {
      sealedCiphertext: `ct-${id}`,
      sealedMetadata: `meta-${id}`,
      sourceKind: "notes",
      // Vault-keyed HMAC of the slug — the cleartext `sourceSlug` is gone (§3).
      slugHmac: "a".repeat(64),
      embeddingModelVersion: "bge-small-en-v1.5",
      dedupHash: `d-${id}`,
      // Default rows are current-generation (v1); the search floor requires it.
      dedupHashVersion: 1,
      ...over,
    },
  };
}

const Q384 = (lead: number[]) => [...lead, ...Array(384 - lead.length).fill(0)];

test("searchKnowledge ranks by cosine, converts distance->score, shapes sealed hits", async () => {
  const db = makeStubDb([
    row("uidA", "near", Q384([1, 0, 0])),
    row("uidA", "mid", Q384([0.7, 0.7, 0])),
    row("uidA", "far", Q384([0, 1, 0])),
  ]);
  const res = await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]), limit: 10 });
  assert.deepEqual(res.hits.map((h) => h.vectorId), ["near", "mid", "far"]);
  const top = res.hits[0];
  assert.ok(top);
  assert.equal(top.resourceUri, "burnbar://knowledge/near");
  assert.equal(top.ciphertext, "ct-near");
  assert.equal(top.sealedMetadata, "meta-near");
  assert.equal(top.decryptMode, "local_decrypt_shim");
  assert.ok(top.score > 0.99 && top.score <= 1);
  assert.ok(res.readBudget.withinSearchReadBudget);
});

test("searchKnowledge is isolated per namespace", async () => {
  const db = makeStubDb([row("uidA", "a1", Q384([1, 0, 0])), row("uidB", "b1", Q384([1, 0, 0]))]);
  assert.deepEqual((await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]) })).hits.map((h) => h.vectorId), ["a1"]);
  assert.deepEqual((await searchKnowledge(db, "uidB", { queryVector: Q384([1, 0, 0]) })).hits.map((h) => h.vectorId), ["b1"]);
  assert.deepEqual((await searchKnowledge(db, "uidC", { queryVector: Q384([1, 0, 0]) })).hits, []);
});

test("searchKnowledge floors dedupHashVersion==1: a non-shim OAuth caller never reaches a v0 row", async () => {
  // FLAG-DAY (dedup-v0 retirement): a stranded legacy v0 row carries
  // `dedupHashVersion: 0` (or, for pre-versioned ancients, no field at all) and
  // its doc id is the cleartext SHA-256 confirm-the-guess oracle. The hosted-MCP
  // search must hard-floor v1 so a non-shim OAuth caller cannot query it.
  const db = makeStubDb([
    row("uidA", "v1doc", Q384([1, 0, 0]), { dedupHashVersion: 1 }),
    row("uidA", "v0doc", Q384([1, 0, 0]), { dedupHashVersion: 0 }),
    // A pre-versioned ancient: the field is absent entirely.
    row("uidA", "ancientDoc", Q384([1, 0, 0]), { dedupHashVersion: undefined }),
  ]);
  const ids = (await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]), limit: 10 })).hits.map((h) => h.vectorId);
  // Only the v1 row surfaces; the v0 oracle row and the ancient are unreachable.
  assert.deepEqual(ids, ["v1doc"]);
  assert.ok(!ids.includes("v0doc"));
  assert.ok(!ids.includes("ancientDoc"));
});

test("searchKnowledge applies the v0 floor even when embeddingModelVersion is omitted (OAuth caller)", async () => {
  // The shim pins embeddingModelVersion, but an OAuth caller may omit it. The v0
  // floor must still hold so v0 rows are never served regardless of the tag.
  const db = makeStubDb([
    row("uidA", "v1doc", Q384([1, 0, 0]), { dedupHashVersion: 1, embeddingModelVersion: "bge-small-en-v1.5-vault-dedup-v1" }),
    row("uidA", "v0doc", Q384([1, 0, 0]), { dedupHashVersion: 0, embeddingModelVersion: "bge-small-en-v1.5" }),
  ]);
  const ids = (await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]), limit: 10 })).hits.map((h) => h.vectorId);
  assert.deepEqual(ids, ["v1doc"]);
});

test("searchKnowledge honours content-free server filters (sourceKind + slugHmac)", async () => {
  const journalHmac = "1".repeat(64);
  const repoHmac = "2".repeat(64);
  const db = makeStubDb([
    row("uidA", "n1", Q384([1, 0, 0]), { sourceKind: "notes", slugHmac: journalHmac }),
    row("uidA", "d1", Q384([1, 0, 0]), { sourceKind: "repo_docs", slugHmac: repoHmac }),
  ]);
  assert.deepEqual(
    (await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]), sourceKind: "repo_docs" })).hits.map((h) => h.vectorId),
    ["d1"],
  );
  // The source filter is the vault-keyed slugHmac (no cleartext sourceSlug).
  assert.deepEqual(
    (await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]), filters: { slugHmac: journalHmac } })).hits.map((h) => h.vectorId),
    ["n1"],
  );
  // Every returned hit exposes only the opaque slugHmac, never a cleartext slug.
  const hits = (await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]) })).hits;
  for (const hit of hits) {
    assert.equal(typeof hit.slugHmac, "string");
    assert.ok(!Object.prototype.hasOwnProperty.call(hit, "sourceSlug"));
  }
});

test("searchKnowledge rejects a malformed query vector", async () => {
  const db = makeStubDb([]);
  await assert.rejects(() => searchKnowledge(db, "uidA", { queryVector: [1, 2, 3] }), /384-dimension/);
  await assert.rejects(() => searchKnowledge(db, "uidA", { queryVector: Q384([Number.NaN]) }), /finite/);
});

test("searchKnowledge paginates with a signed cursor", async () => {
  const db = makeStubDb([
    row("uidA", "v1", Q384([1, 0, 0])),
    row("uidA", "v2", Q384([0.9, 0.1, 0])),
    row("uidA", "v3", Q384([0.8, 0.2, 0])),
  ]);
  const page1 = await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]), limit: 2 });
  assert.equal(page1.hits.length, 2);
  assert.ok(page1.nextCursor, "expected a nextCursor when more results remain");
  const page2 = await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]), limit: 2, cursor: page1.nextCursor });
  assert.deepEqual(page2.hits.map((h) => h.vectorId), ["v3"]);
  assert.equal(page2.nextCursor, undefined);
});

test("readKnowledgeDocument returns the inline atomic sealed envelope", async () => {
  const envelope = { algorithm: "AES-256-GCM", keyVersion: 1, nonce: "n", ciphertext: "ct", tag: "t" };
  const meta = { algorithm: "AES-256-GCM", keyVersion: 1, nonce: "n2", ciphertext: "m", tag: "t2" };
  const db = makeStubDb([
    row("uidA", "v1", Q384([1, 0, 0]), { sealedCiphertext: envelope, sealedMetadata: meta, dedupHash: "deadbeef", slugHmac: "f".repeat(64) }),
  ]);
  const doc = await readKnowledgeDocument(db, "uidA", { resourceUri: "burnbar://knowledge/v1" });
  assert.deepEqual(doc.sealedCiphertext, envelope);
  assert.deepEqual(doc.sealedMetadata, meta);
  // Vault-keyed dedupHash + slugHmac only; no cleartext contentHash/sourceSlug (§3).
  assert.equal(doc.dedupHash, "deadbeef");
  assert.equal(doc.slugHmac, "f".repeat(64));
  assert.ok(!Object.prototype.hasOwnProperty.call(doc, "contentHash"));
  assert.ok(!Object.prototype.hasOwnProperty.call(doc, "sourceSlug"));
  assert.equal(doc.encrypted, true);
  assert.equal(doc.decryptMode, "local_decrypt_shim");
});

test("readKnowledgeDocument rejects bad URIs, missing docs, and cross-namespace reads", async () => {
  const db = makeStubDb([row("uidA", "v1", Q384([1, 0, 0]))]);
  await assert.rejects(() => readKnowledgeDocument(db, "uidA", { resourceUri: "burnbar://conversation/v1" }), /invalid_resource_uri|burnbar:\/\/knowledge/);
  await assert.rejects(() => readKnowledgeDocument(db, "uidA", { resourceUri: "burnbar://knowledge/missing" }), /not found/);
  await assert.rejects(() => readKnowledgeDocument(db, "uidB", { resourceUri: "burnbar://knowledge/v1" }), /not found/);
});

test("searchKnowledge rejects a cursor minted for another tool", async () => {
  const db = makeStubDb([row("uidA", "v1", Q384([1, 0, 0]))]);
  // A cursor scoped to a different tool must fail the tool-scope check.
  const foreign = signCursor({ uid: "uidA", tool: "burnbar_get_conversation_body", offset: 0, exp: Date.now() + 60_000 });
  await assert.rejects(
    () => searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]), cursor: foreign }),
    /cursor/i,
  );
});
