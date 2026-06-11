import assert from "node:assert/strict";
import { seedAndroidDemoAccount } from "../lib/demoSeed.js";

function createMockDb() {
  const store = new Map();
  // Mirrors Firestore set() semantics: merge:false replaces the document,
  // merge:true deep-merges plain maps, and FieldValue.increment sentinels
  // apply against the existing numeric value (the rollup counters keep a
  // nested all_time dailyTokens increment map).
  function mergeFieldValue(existing, value) {
    if (value && typeof value === "object" && "operand" in value) {
      return (typeof existing === "number" ? existing : 0) + value.operand;
    }
    if (value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
      const next =
        existing && typeof existing === "object" && Object.getPrototypeOf(existing) === Object.prototype
          ? { ...existing }
          : {};
      for (const [key, entry] of Object.entries(value)) {
        next[key] = mergeFieldValue(next[key], entry);
      }
      return next;
    }
    return value;
  }

  function applySet(path, data, options) {
    const merge = options?.merge === true;
    const next = merge ? { ...(store.get(path) ?? {}) } : {};
    for (const [key, value] of Object.entries(data)) {
      next[key] = mergeFieldValue(merge ? next[key] : undefined, value);
    }
    store.set(path, next);
  }

  const db = {
    store,
    collection(path) {
      const listDocs = () => {
        const prefix = `${path}/`;
        const expectedSegments = path.split("/").length + 1;
        return [...store.entries()]
          .filter(([key]) => key.startsWith(prefix) && key.split("/").length === expectedSegments)
          .map(([key, data]) => {
            const ref = db.doc(key);
            return {
              id: key.split("/").at(-1),
              ref,
              data: () => data,
              get: (field) => data[field],
            };
          });
      };
      // Supports the documentId range filters and document-id paging used by
      // the rollup day fetch and raw-usage repair scan.
      const makeQuery = (clauses, limitCount = undefined, startAfterId = undefined) => ({
        where(_field, op, value) {
          return makeQuery([...clauses, [op, value]], limitCount, startAfterId);
        },
        orderBy() {
          return makeQuery(clauses, limitCount, startAfterId);
        },
        limit(count) {
          return makeQuery(clauses, count, startAfterId);
        },
        startAfter(doc) {
          return makeQuery(clauses, limitCount, doc.id);
        },
        async get() {
          const docs = listDocs()
            .sort((a, b) => a.id.localeCompare(b.id))
            .filter((doc) => !startAfterId || doc.id > startAfterId)
            .filter((doc) =>
              clauses.every(([op, value]) => (op === ">=" ? doc.id >= value : op === "<=" ? doc.id <= value : false)),
            )
            .slice(0, limitCount ?? listDocs().length);
          return {
            empty: docs.length === 0,
            docs,
          };
        },
      });
      return {
        doc(id) {
          return db.doc(`${path}/${id}`);
        },
        ...makeQuery([]),
      };
    },
    doc(path) {
      return {
        path,
        collection(name) {
          return db.collection(`${path}/${name}`);
        },
        async get() {
          const data = store.get(path);
          return {
            exists: data != null,
            data: () => data,
          };
        },
      };
    },
    batch() {
      const writes = [];
      return {
        set(ref, data, options) {
          writes.push({ type: "set", path: ref.path, data, options });
        },
        delete(ref) {
          writes.push({ type: "delete", path: ref.path });
        },
        async commit() {
          for (const write of writes) {
            if (write.type === "delete") {
              store.delete(write.path);
            } else {
              applySet(write.path, write.data, write.options);
            }
          }
        },
      };
    },
    async runTransaction(work) {
      const transaction = {
        async get(ref) {
          const data = store.get(ref.path);
          return {
            exists: data != null,
            data: () => data,
          };
        },
        set(ref, data, options) {
          applySet(ref.path, data, options);
        },
      };
      return work(transaction);
    },
    async recursiveDelete(ref) {
      for (const key of [...store.keys()]) {
        if (key === ref.path || key.startsWith(`${ref.path}/`)) {
          store.delete(key);
        }
      }
    },
  };

  return db;
}

const db = createMockDb();
db.store.set("users/test-uid/usage/real_usage", {
  provider: "codex",
  providerID: "codex",
  sessionId: "real-usage",
  model: "gpt-5.5",
  inputTokens: 100,
  outputTokens: 50,
  totalTokens: 150,
  costUsd: 0.01,
  startTime: "2026-05-01T12:00:00.000Z",
  schemaVersion: 1,
});
db.store.set("users/test-uid/usage/demo_android_stale", {
  provider: "codex",
  providerID: "codex",
  sessionId: "old-demo",
  totalTokens: 1,
  costUsd: 0.01,
  startTime: "2026-04-01T12:00:00.000Z",
  demo: true,
  schemaVersion: 1,
});

const result = await seedAndroidDemoAccount(db, "test-uid", new Date("2026-05-13T16:00:00.000Z"));

assert.equal(result.success, true);
assert.equal(result.usageCount, 12);
assert.equal(result.providerAccountCount, 4);
assert.equal(result.quotaSnapshotCount, 4);
assert.equal(result.projectCount, 4);
assert.equal(db.store.has("users/test-uid/usage/real_usage"), true);
assert.equal(db.store.has("users/test-uid/usage/demo_android_stale"), false);

const seededUsage = [...db.store.keys()].filter((path) =>
  path.startsWith("users/test-uid/usage/demo_android_")
);
assert.equal(seededUsage.length, 12);

const codexAccount = db.store.get("users/test-uid/provider_accounts/demo_android_codex");
assert.equal(codexAccount.providerID, "codex");
assert.equal(codexAccount.demo, true);
assert.equal(codexAccount.storageScope, "server_private");

const codexQuota = db.store.get("users/test-uid/quota_snapshots/demo_android_codex");
assert.equal(codexQuota.buckets[0].meta.demo, true);
assert.equal(codexQuota.accountID, "demo_android_codex");

const rollup = db.store.get("users/test-uid/usage_rollups/all_time");
assert.equal(rollup.schemaVersion, 3);
assert.equal(rollup.totals.requests, 13);
assert.equal(rollup.providerSummaries.some((provider) => provider.provider === "codex"), true);
assert.equal(rollup.dailyPoints["2026-05-13"] > 0, true);

const project = db.store.get("users/test-uid/projects/demo_android_burnbar-android-parity");
assert.equal(project.name, "BurnBar Android parity");
assert.equal(project.demo, true);

const secondResult = await seedAndroidDemoAccount(db, "test-uid", new Date("2026-05-13T16:00:00.000Z"));
assert.equal(secondResult.usageCount, 12);
assert.equal(
  [...db.store.keys()].filter((path) => path.startsWith("users/test-uid/usage/demo_android_")).length,
  12
);
assert.equal(db.store.has("users/test-uid/usage/real_usage"), true);

console.log("Android demo seed invariants passed");
