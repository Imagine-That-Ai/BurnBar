import assert from "node:assert/strict";
import test from "node:test";

import { getEntitlementState } from "./entitlements.js";
import type { RemoteMcpClientFirestore } from "./firestoreTypes.js";

const FUTURE = new Date(Date.now() + 86_400_000).toISOString();

/** Minimal Firestore stub returning the given per-path entitlement docs. */
function stubDb(docs: Record<string, Record<string, unknown> | undefined>): RemoteMcpClientFirestore {
  const firestore = {
    doc(path: string) {
      return {
        async get() {
          const data = docs[path];
          return { exists: data !== undefined, data: () => data };
        },
        async set() {},
      };
    },
  };
  // @ts-expect-error in-memory Firestore stub for entitlement tier tests
  return firestore;
}

function entPath(uid: string, id: string) {
  return `users/${uid}/entitlements/${id}`;
}

test("Ultra entitlement resolves tier=ultra (source burnbar_ultra)", async () => {
  const uid = "u-ultra";
  const state = await getEntitlementState(uid, stubDb({ [entPath(uid, "burnbar_ultra")]: { active: true, expireAt: FUTURE } }));
  assert.equal(state.active, true);
  assert.equal(state.tier, "ultra");
  assert.equal(state.source, "burnbar_ultra");
});

test("Cloud Pro (proMax) is recognized by the hosted MCP with tier=pro", async () => {
  const uid = "u-promax";
  const state = await getEntitlementState(uid, stubDb({ [entPath(uid, "burnbar_pro_max")]: { active: true, expireAt: FUTURE } }));
  assert.equal(state.active, true);
  assert.equal(state.tier, "pro");
  assert.equal(state.source, "burnbar_pro_max");
});

test("legacy Pro still resolves active tier=pro", async () => {
  const uid = "u-pro";
  const state = await getEntitlementState(uid, stubDb({ [entPath(uid, "burnbar_pro")]: { active: true, expireAt: FUTURE } }));
  assert.equal(state.tier, "pro");
  assert.equal(state.source, "burnbar_pro");
});

test("no entitlement resolves inactive tier=none", async () => {
  const uid = "u-none";
  const state = await getEntitlementState(uid, stubDb({}));
  assert.equal(state.active, false);
  assert.equal(state.tier, "none");
  assert.equal(state.source, "none");
});

test("expired Ultra falls through (inactive)", async () => {
  const uid = "u-expired";
  const past = new Date(Date.now() - 1000).toISOString();
  const state = await getEntitlementState(uid, stubDb({ [entPath(uid, "burnbar_ultra")]: { active: true, expireAt: past } }));
  assert.equal(state.active, false);
  assert.equal(state.tier, "none");
});
