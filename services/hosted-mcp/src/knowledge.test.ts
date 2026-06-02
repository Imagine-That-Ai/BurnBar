import assert from "node:assert/strict";
import test from "node:test";

import { searchKnowledge, readKnowledgeDocument } from "./knowledge.js";
import { cosineSimilarity } from "./knowledgeVector.js";
import { signCursor } from "./cursors.js";

interface StubRow {
  ns: string;
  id: string;
  embedding: number[];
  fields: Record<string, unknown>;
}

/** A Firestore stub supporting collection().where().findNearest().get() and doc().get(). */
function makeStubDb(rows: StubRow[]) {
  function makeQuery(ns: string, filtered: StubRow[]): any {
    return {
      where(field: string, _op: string, value: unknown) {
        return makeQuery(ns, filtered.filter((r) => r.fields[field] === value));
      },
      findNearest({ queryVector, limit, distanceResultField }: any) {
        const qv: number[] = typeof queryVector?.toArray === "function" ? queryVector.toArray() : queryVector;
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
  } as any;
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
      sourceSlug: "journal",
      embeddingModelVersion: "bge-small-en-v1.5",
      contentHash: `h-${id}`,
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
  assert.deepEqual(res.hits.map((h: any) => h.vectorId), ["near", "mid", "far"]);
  const top = res.hits[0] as any;
  assert.equal(top.resourceUri, "burnbar://knowledge/near");
  assert.equal(top.ciphertext, "ct-near");
  assert.equal(top.sealedMetadata, "meta-near");
  assert.equal(top.decryptMode, "local_decrypt_shim");
  assert.ok(top.score > 0.99 && top.score <= 1);
  assert.ok(res.readBudget.withinSearchReadBudget);
});

test("searchKnowledge is isolated per namespace", async () => {
  const db = makeStubDb([row("uidA", "a1", Q384([1, 0, 0])), row("uidB", "b1", Q384([1, 0, 0]))]);
  assert.deepEqual((await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]) })).hits.map((h: any) => h.vectorId), ["a1"]);
  assert.deepEqual((await searchKnowledge(db, "uidB", { queryVector: Q384([1, 0, 0]) })).hits.map((h: any) => h.vectorId), ["b1"]);
  assert.deepEqual((await searchKnowledge(db, "uidC", { queryVector: Q384([1, 0, 0]) })).hits, []);
});

test("searchKnowledge honours plaintext server filters", async () => {
  const db = makeStubDb([
    row("uidA", "n1", Q384([1, 0, 0]), { sourceKind: "notes", sourceSlug: "journal" }),
    row("uidA", "d1", Q384([1, 0, 0]), { sourceKind: "repo_docs", sourceSlug: "repoX" }),
  ]);
  assert.deepEqual(
    (await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]), sourceKind: "repo_docs" })).hits.map((h: any) => h.vectorId),
    ["d1"],
  );
  assert.deepEqual(
    (await searchKnowledge(db, "uidA", { queryVector: Q384([1, 0, 0]), filters: { sourceSlug: "journal" } })).hits.map((h: any) => h.vectorId),
    ["n1"],
  );
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
  assert.deepEqual(page2.hits.map((h: any) => h.vectorId), ["v3"]);
  assert.equal(page2.nextCursor, undefined);
});

test("readKnowledgeDocument returns the inline atomic sealed envelope", async () => {
  const envelope = { algorithm: "AES-256-GCM", keyVersion: 1, nonce: "n", ciphertext: "ct", tag: "t" };
  const meta = { algorithm: "AES-256-GCM", keyVersion: 1, nonce: "n2", ciphertext: "m", tag: "t2" };
  const db = makeStubDb([
    row("uidA", "v1", Q384([1, 0, 0]), { sealedCiphertext: envelope, sealedMetadata: meta, contentHash: "deadbeef" }),
  ]);
  const doc = await readKnowledgeDocument(db, "uidA", { resourceUri: "burnbar://knowledge/v1" });
  assert.deepEqual(doc.sealedCiphertext, envelope);
  assert.deepEqual(doc.sealedMetadata, meta);
  assert.equal(doc.contentHash, "deadbeef");
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
