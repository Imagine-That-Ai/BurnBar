import assert from "node:assert/strict";
import test from "node:test";
import { searchConversations } from "./search.js";
import type { Firestore } from "firebase-admin/firestore";

const HASH_OLD = "a".repeat(32);
const HASH_NEW = "b".repeat(32);
const OLD_COMMIT = "1".repeat(32);
const NEW_COMMIT = "2".repeat(32);
const sealedSnippet = {
  algorithm: "AES-256-GCM",
  keyVersion: 1,
  nonce: "bm9uY2U=",
  ciphertext: "Y2lwaGVydGV4dA==",
  tag: "dGFn"
};

function snapshot(id: string, data: Record<string, unknown>, exists = true) {
  return {
    id,
    exists,
    data() { return data; },
    get(field: string) { return data[field]; }
  };
}

function makeSearchFirestore(): Firestore {
  const oldChunk = snapshot("doc-old_0", {
    documentID: "doc-old",
    sourceKind: "conversation",
    sourceID: "session-old",
    provider: "Codex",
    projectName: "BurnBar",
    commitID: OLD_COMMIT,
    bodyHash: "c".repeat(64),
    storagePath: "users/user-1/session_logs/doc-old/body.enc",
    tokenHashes: [HASH_OLD],
    semanticHashes: [],
    sealedSnippet,
    ordinal: 0
  });
  const newChunk = snapshot("doc-new_0", {
    documentID: "doc-new",
    sourceKind: "conversation",
    sourceID: "session-new",
    provider: "Codex",
    projectName: "BurnBar",
    commitID: NEW_COMMIT,
    bodyHash: "d".repeat(64),
    storagePath: "users/user-1/session_logs/doc-new/body.enc",
    tokenHashes: [HASH_NEW],
    semanticHashes: [],
    sealedSnippet,
    ordinal: 0
  });
  const chunksByPath = new Map([
    ["users/user-1/cloud_search_chunks/doc-old_0", oldChunk],
    ["users/user-1/cloud_search_chunks/doc-new_0", newChunk],
  ]);
  const postings = [
    snapshot(`token_${HASH_OLD}_doc-old_0`, {
      postingKey: `token_${HASH_OLD}`,
      kind: "token",
      hash: HASH_OLD,
      chunkID: "doc-old_0",
      documentID: "doc-old",
      provider: "Codex",
      commitID: OLD_COMMIT
    }),
    snapshot(`token_${HASH_NEW}_doc-new_0`, {
      postingKey: `token_${HASH_NEW}`,
      kind: "token",
      hash: HASH_NEW,
      chunkID: "doc-new_0",
      documentID: "doc-new",
      provider: "Codex",
      commitID: NEW_COMMIT
    }),
  ];
  const activeState = snapshot("mac-1", { activeCommitID: NEW_COMMIT });

  const db = {
    doc(path: string) {
      return {
        async get() {
          return chunksByPath.get(path) ?? snapshot(path.split("/").pop() ?? path, {}, false);
        }
      };
    },
    async getAll(...refs: Array<{ get(): Promise<ReturnType<typeof snapshot>> }>) {
      return Promise.all(refs.map((ref) => ref.get()));
    },
    collection(path: string) {
      const docs = path.endsWith("/cloud_search_postings")
        ? postings
        : path.endsWith("/cloud_search_index_state")
          ? [activeState]
          : [];
      const filters: Array<{ field: string; op: string; value: unknown }> = [];
      let limitCount = Number.POSITIVE_INFINITY;
      const query = {
        where(field: string, op: string, value: unknown) {
          filters.push({ field, op, value });
          return query;
        },
        orderBy() { return query; },
        select() { return query; },
        limit(count: number) {
          limitCount = count;
          return query;
        },
        async get() {
          return {
            docs: docs.filter((doc) => filters.every((filter) => {
              const actual = doc.get(filter.field);
              if (filter.op === "in" && Array.isArray(filter.value)) {return filter.value.includes(actual);}
              return actual === filter.value;
            })).slice(0, limitCount)
          };
        }
      };
      return query;
    }
  };
  // @ts-expect-error in-memory Firestore stub for hosted search tests
  return db;
}

test("hosted search can find older per-document commits from posting indexes", async () => {
  const result = await searchConversations(makeSearchFirestore(), "user-1", {
    tokenHashes: [HASH_OLD],
    limit: 10
  });

  assert.equal(result.hits.length, 1);
  assert.equal(result.hits[0].documentID, "doc-old");
  assert.equal(result.hits[0].matchKind, "token");
  assert.equal(result.storageReads, 0);
  assert.equal(result.readBudget.withinSearchReadBudget, true);
});
