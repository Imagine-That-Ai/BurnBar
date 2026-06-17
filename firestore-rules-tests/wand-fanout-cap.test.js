/**
 * Firestore rules tests for The Wand per-tier fan-out cap.
 *
 * validMissionGroup() caps childMissionIDs / runtimeTokens / parallelismLimit
 * at wandFanOutCap(userId): Free 1 / Cloud 3 / Cloud Pro 8 / Ultra 16.
 * Everything else in the mission_group doc is held valid (sealed payload +
 * active vault key) so each assertion exercises ONLY the cap — and proves the
 * get()-budget of the new tier helpers does not break otherwise-valid writes.
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { doc, setDoc, Timestamp } from "firebase/firestore";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);
const rules = readFileSync(new URL("../firestore.rules", import.meta.url), "utf8");

const vaultKeyID = "v1_0123456789abcdef0123456789abcdef";
const futureExpiry = Timestamp.fromMillis(Date.now() + 86_400_000);

const CLOUD_PRODUCT = "com.openburnbar.pro.monthly";
const PRO_MAX_PRODUCT = "com.openburnbar.proMax.v2.monthly";
const ULTRA_PRODUCT = "com.openburnbar.ultra.monthly";

function sealedPayload() {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    vaultKeyID,
    sealedBoxBase64: "QUJD",
    aad: "OpenBurnBar-CloudVaultSealedPayload-v2",
  };
}

function missionGroup(n) {
  return {
    id: "group-1",
    childMissionIDs: Array.from({ length: n }, (_, i) => `child-${i}`),
    runtimeTokens: Array.from({ length: n }, (_, i) => `rt-${i}`),
    parallelismLimit: n,
    mergeStrategy: "pick_one",
    phase: "queued",
    createdAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    schemaVersion: 1,
    source: "test",
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID,
    sealedPayload: sealedPayload(),
  };
}

console.log("wand fan-out cap rules tests");

const testEnv = await initializeTestEnvironment({
  projectId: PROJECT_ID,
  firestore: { rules, host: FIRESTORE_HOST, port: FIRESTORE_PORT },
});

await testEnv.clearFirestore();

async function seed(uid, entitlements) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `users/${uid}/cloud_vault_state/current`), {
      vaultKeyID,
      status: "active",
    });
    for (const [id, productID] of entitlements) {
      await setDoc(doc(db, `users/${uid}/entitlements/${id}`), {
        active: true,
        productID,
        expireAt: futureExpiry,
      });
    }
  });
}

function db(uid) {
  return testEnv.authenticatedContext(uid).firestore();
}

let failures = 0;
async function expectAllow(label, uid, n) {
  try {
    await assertSucceeds(setDoc(doc(db(uid), `users/${uid}/mission_groups/group-1`), missionGroup(n)));
    console.log(`  PASS ${label}`);
  } catch (e) {
    failures += 1;
    console.error(`  FAIL ${label}: ${e.message}`);
  }
}
async function expectDeny(label, uid, n) {
  try {
    await assertFails(setDoc(doc(db(uid), `users/${uid}/mission_groups/group-1`), missionGroup(n)));
    console.log(`  PASS ${label}`);
  } catch (e) {
    failures += 1;
    console.error(`  FAIL ${label}: ${e.message}`);
  }
}

// Free (no entitlement) → cap 1.
await seed("free-u", []);
await expectAllow("free allows 1", "free-u", 1);
await expectDeny("free denies 2", "free-u", 2);

// Cloud (burnbar_pro) → cap 3.
await seed("cloud-u", [["burnbar_pro", CLOUD_PRODUCT]]);
await expectAllow("cloud allows 3", "cloud-u", 3);
await expectDeny("cloud denies 4", "cloud-u", 4);

// Cloud Pro (burnbar_pro_max) → cap 8.
await seed("pro-u", [["burnbar_pro_max", PRO_MAX_PRODUCT]]);
await expectAllow("pro allows 8", "pro-u", 8);
await expectDeny("pro denies 9", "pro-u", 9);

// Ultra (burnbar_ultra) → cap 16.
await seed("ultra-u", [["burnbar_ultra", ULTRA_PRODUCT]]);
await expectAllow("ultra allows 16", "ultra-u", 16);
await expectDeny("ultra denies 17", "ultra-u", 17);

await testEnv.cleanup();
if (failures > 0) {
  console.error(`${failures} wand fan-out cap assertion(s) FAILED`);
  process.exit(1);
}
console.log("all wand fan-out cap rules tests passed");
