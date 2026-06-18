/**
 * Firestore rules tests for The Wand fan-out cap.
 *
 * The mobile clients dispatch a fan-out as one atomic batch:
 *   users/{uid}/mission_groups/{groupID}
 *   users/{uid}/cli_agent_mission_requests/{childID}...
 *
 * The rules cap fan-out by tier, keep CloudVault payloads path-bound, and reject
 * malformed parent/request shapes before the Mac listener sees them.
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { doc, setDoc, writeBatch, Timestamp } from "firebase/firestore";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);

const aliceUid = "alice-uid";
const vaultKeyID = "v1_0123456789abcdef0123456789abcdef";
const GLOBAL_SEALED_PAYLOAD_AAD = "OpenBurnBar-CloudVaultSealedPayload-v2";

const tierEntitlements = {
  cloud: {
    docID: "hosted_quota_sync",
    productID: "com.openburnbar.hostedQuotaSync.cloud.monthly",
  },
  legacyCloud: {
    docID: "burnbar_pro",
    productID: "com.openburnbar.pro.monthly",
  },
  proMax: {
    docID: "burnbar_pro_max",
    productID: "com.openburnbar.proMax.v2.monthly",
  },
  ultra: {
    docID: "burnbar_ultra",
    productID: "com.openburnbar.ultra.monthly",
  },
};

function payloadAad(uid, collection, docId) {
  return `OpenBurnBar-CloudVault-aad-v2|${uid}|${collection}|${docId}|sealedPayload|2|sealedPayload`;
}

function sealedPayload(aad) {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    vaultKeyID,
    sealedBoxBase64: "U2VhbGVkUGF5bG9hZENpcGhlcnRleHRCb2R5",
    aad,
  };
}

async function seed(testEnv, uid, tier = "free", entitlementOverride = null) {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `users/${uid}/cloud_vault_state/current`), {
      vaultKeyID,
      status: "active",
    });
    const entitlement = entitlementOverride ?? tierEntitlements[tier];
    if (entitlement) {
      await setDoc(doc(db, `users/${uid}/entitlements/${entitlement.docID}`), {
        active: true,
        productID: entitlement.productID,
        expireAt: Timestamp.fromMillis(Date.now() + 86_400_000),
      });
    }
  });
}

function missionGroup(groupID, childIDs, runtimeTokens = childIDs.map((_, index) => `runtime-${index}`)) {
  const now = Timestamp.fromMillis(Date.now());
  return {
    id: groupID,
    missionKind: "diligence",
    childMissionIDs: childIDs,
    runtimeTokens,
    parallelismLimit: childIDs.length,
    mergeStrategy: "pick_one",
    phase: "queued",
    createdAt: now,
    updatedAt: now,
    schemaVersion: 1,
    source: "ios",
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID,
    sealedPayload: sealedPayload(GLOBAL_SEALED_PAYLOAD_AAD),
  };
}

function childMission(uid, groupID, childID, siblingIndex, siblingCount, extra = {}) {
  const now = Timestamp.fromMillis(Date.now());
  return {
    id: childID,
    missionKind: "diligence",
    requestedRuntime: `runtime-${siblingIndex}`,
    depth: "standard",
    approvalMode: "existing_policy",
    commandsAllowed: false,
    fileEditsAllowed: false,
    source: "ios",
    status: "pending",
    createdAt: now,
    updatedAt: now,
    schemaVersion: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID,
    sealedPayload: sealedPayload(payloadAad(uid, "cli_agent_mission_requests", childID)),
    groupID,
    siblingIndex,
    siblingCount,
    isGroupChild: true,
    ...extra,
  };
}

function singleMission(uid, requestID, extra = {}) {
  const now = Timestamp.fromMillis(Date.now());
  return {
    id: requestID,
    missionKind: "diligence",
    requestedRuntime: "codex",
    depth: "standard",
    approvalMode: "existing_policy",
    commandsAllowed: false,
    fileEditsAllowed: false,
    source: "ios",
    status: "pending",
    createdAt: now,
    updatedAt: now,
    schemaVersion: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID,
    sealedPayload: sealedPayload(payloadAad(uid, "cli_agent_mission_requests", requestID)),
    ...extra,
  };
}

function missionEventAad(uid, requestID, eventID) {
  return payloadAad(uid, "cli_agent_mission_requests/events", `${requestID}/${eventID}`);
}

function missionEvent(uid, requestID, eventID, extra = {}) {
  return {
    sequence: 1,
    timestamp: "2026-05-13T00:00:00.000Z",
    kind: "status",
    phase: "queued",
    source: "ios",
    deliveryMode: "action_only",
    eventImportance: "normal",
    skillStepID: "queued",
    isError: false,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID,
    sealedPayload: sealedPayload(missionEventAad(uid, requestID, eventID)),
    ...extra,
  };
}

function childIDsFor(groupID, count) {
  return Array.from({ length: count }, (_, index) => `${groupID}-child-${index + 1}`);
}

async function commitFanOut(db, uid, groupID, count, options = {}) {
  const childIDs = options.childIDs ?? childIDsFor(groupID, count);
  const parentChildIDs = options.parentChildIDs ?? childIDs;
  const batch = writeBatch(db);
  batch.set(doc(db, `users/${uid}/mission_groups/${groupID}`), missionGroup(groupID, parentChildIDs));
  childIDs.forEach((childID, index) => {
    batch.set(
      doc(db, `users/${uid}/cli_agent_mission_requests/${childID}`),
      childMission(uid, groupID, childID, index, childIDs.length, options.childExtra?.(childID, index) ?? {})
    );
  });
  await batch.commit();
}

let testEnv;
let runs = 0;
let failures = 0;

async function step(name, fn) {
  runs += 1;
  try {
    await fn();
    console.log(`PASS ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL ${name}`);
    console.error(error);
  }
}

async function main() {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(RULES_PATH, "utf8"),
      host: FIRESTORE_HOST,
      port: FIRESTORE_PORT,
    },
  });

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();

  await step("free tier allows the real 1-child batch shape", async () => {
    await seed(testEnv, aliceUid, "free");
    await assertSucceeds(commitFanOut(aliceDB, aliceUid, "free-allow-1", 1));
  });

  await step("free tier denies a 2-child batch", async () => {
    await seed(testEnv, aliceUid, "free");
    await assertFails(commitFanOut(aliceDB, aliceUid, "free-deny-2", 2));
  });

  await step("mission request body id must match the document path", async () => {
    await seed(testEnv, aliceUid, "free");
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/cli_agent_mission_requests/path-id`),
        singleMission(aliceUid, "body-id")
      )
    );
  });

  await step("mission group must contain at least one child", async () => {
    await seed(testEnv, aliceUid, "free");
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/mission_groups/empty-group`), missionGroup("empty-group", []))
    );
  });

  await step("mission group runtime tokens must match child count", async () => {
    await seed(testEnv, aliceUid, "cloud");
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/mission_groups/runtime-mismatch`),
        missionGroup("runtime-mismatch", ["child-1", "child-2"], ["runtime-1"])
      )
    );
  });

  await step("mission group body id must match the document path", async () => {
    await seed(testEnv, aliceUid, "free");
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/mission_groups/path-group`),
        missionGroup("body-group", ["body-group-child-1"])
      )
    );
  });

  await step("mission group dispatch fields are immutable after create", async () => {
    await seed(testEnv, aliceUid, "free");
    const groupID = "immutable-group";
    const groupRef = doc(aliceDB, `users/${aliceUid}/mission_groups/${groupID}`);
    await assertSucceeds(setDoc(groupRef, missionGroup(groupID, [`${groupID}-child-1`])));
    await assertFails(setDoc(groupRef, missionGroup(groupID, [`${groupID}-child-2`])));
  });

  await step("cloud tier allows 3 and denies 4", async () => {
    await seed(testEnv, aliceUid, "cloud");
    await assertSucceeds(commitFanOut(aliceDB, aliceUid, "cloud-allow-3", 3));
    await seed(testEnv, aliceUid, "cloud");
    await assertFails(commitFanOut(aliceDB, aliceUid, "cloud-deny-4", 4));
  });

  await step("legacy cloud entitlement doc maps only to the Cloud cap", async () => {
    await seed(testEnv, aliceUid, "legacyCloud");
    await assertSucceeds(commitFanOut(aliceDB, aliceUid, "legacy-cloud-allow-3", 3));
    await seed(testEnv, aliceUid, "legacyCloud");
    await assertFails(commitFanOut(aliceDB, aliceUid, "legacy-cloud-deny-4", 4));
  });

  await step("cloud pro tier allows 8 and denies 9", async () => {
    await seed(testEnv, aliceUid, "proMax");
    await assertSucceeds(commitFanOut(aliceDB, aliceUid, "pro-allow-8", 8));
    await seed(testEnv, aliceUid, "proMax");
    await assertFails(commitFanOut(aliceDB, aliceUid, "pro-deny-9", 9));
  });

  await step("ultra tier allows 16", async () => {
    await seed(testEnv, aliceUid, "ultra");
    await assertSucceeds(commitFanOut(aliceDB, aliceUid, "ultra-allow-16", 16));
  });

  await step("Mac Wand dispatcher can seed the first queued event", async () => {
    await seed(testEnv, aliceUid, "free");
    const requestID = "mac-wand-seed";
    const requestPath = `users/${aliceUid}/cli_agent_mission_requests/${requestID}`;
    await assertSucceeds(
      setDoc(
        doc(aliceDB, requestPath),
        singleMission(aliceUid, requestID, {
          approvalMode: "manual_all",
          source: "mac",
          sourceSurface: "mac-wand",
        })
      )
    );
    await assertSucceeds(
      setDoc(
        doc(aliceDB, `${requestPath}/events/000001`),
        missionEvent(aliceUid, requestID, "000001", {
          source: "mac",
          sourceSurface: "mac-wand",
        })
      )
    );
    await assertFails(
      setDoc(
        doc(aliceDB, `${requestPath}/events/000002`),
        missionEvent(aliceUid, requestID, "000002", {
          source: "mac",
          sourceSurface: "mac-wand",
        })
      )
    );
  });

  await step("miswritten ultra entitlement doc with a non-ultra product does not grant Ultra", async () => {
    await seed(testEnv, aliceUid, "free", {
      docID: "burnbar_ultra",
      productID: "com.openburnbar.hostedQuotaSync.cloud.monthly",
    });
    await assertFails(commitFanOut(aliceDB, aliceUid, "miswritten-ultra", 16));
  });

  await testEnv.cleanup();
  console.log(`\n${runs - failures}/${runs} cases passed`);
  if (failures > 0) process.exit(1);
}

main().catch(async (error) => {
  console.error(error);
  if (testEnv) await testEnv.cleanup();
  process.exit(2);
});
