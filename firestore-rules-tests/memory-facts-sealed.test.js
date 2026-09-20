/**
 * Firestore rules tests for sealed memory-fact and forget-receipt boundaries.
 *
 * Clients may mirror approved local memories only as CloudVault-sealed blobs
 * with opaque source HMACs. Plaintext fact bodies, raw citations, and vector
 * material stay device-local or server-owned.
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import {
  collection,
  doc,
  documentId,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  serverTimestamp,
  setDoc,
  updateDoc,
  Timestamp,
} from "firebase/firestore";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);
const aliceUid = "alice-uid";
const bobUid = "bob-uid";
const now = Timestamp.fromMillis(Date.now());
const opaqueDigits = "0123456789abcdef";

function opaqueId(index) {
  return opaqueDigits[index % opaqueDigits.length].repeat(64);
}

// A second opaque-id family for the agent-sourced (blind sync) cases. The
// trailing 32 hex chars are never uniform, so these can never collide with
// an `opaqueId` above while still matching `^[a-f0-9]{64}$`.
function agentOpaqueId(index) {
  return opaqueDigits[index % opaqueDigits.length].repeat(32) + opaqueDigits.repeat(2);
}

function memoryAad(uid, docID) {
  return `OpenBurnBar-CloudVault-aad-v2|${uid}|memory_facts|${docID}|sealedMemory|2|sealedMemory`;
}

function sealedBlob(aad) {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    plaintextHMAC: "d".repeat(64),
    integrityHashVersion: 1,
    sealedBoxBase64: "Q2lwaGVydGV4dA==",
    createdAt: now,
    aad,
  };
}

function memoryFact(uid, docID, overrides = {}) {
  return {
    uid,
    docID,
    schemaVersion: 1,
    sourceKind: "chat",
    kind: "fact",
    reviewStatus: "approved",
    sealedMemory: sealedBlob(memoryAad(uid, docID)),
    sourceRefHmacs: ["a".repeat(64)],
    citationCount: 1,
    validFrom: now,
    updatedAt: now,
    replicatedAt: now,
    ...overrides,
  };
}

function forgetReceipt(uid, receiptID, overrides = {}) {
  return {
    uid,
    receiptID,
    schemaVersion: 1,
    memoryIdHmac: "b".repeat(64),
    sourceRefHmacs: ["c".repeat(64)],
    reason: "user_delete",
    createdAt: now,
    replicatedAt: now,
    ...overrides,
  };
}

async function seedEntitlement(uid, entitlementID, productID) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/${uid}/entitlements/${entitlementID}`), {
      id: entitlementID,
      active: true,
      productID,
      expireAt: Timestamp.fromDate(new Date("2099-01-01T00:00:00.000Z")),
      schemaVersion: 2,
    });
  });
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
  await testEnv.clearFirestore();

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();
  const bobDB = testEnv.authenticatedContext(bobUid).firestore();
  const cloudOnlyUid = "cloud-only-uid";
  const cloudOnlyDB = testEnv.authenticatedContext(cloudOnlyUid).firestore();
  const ultraUid = "ultra-uid";
  const ultraDB = testEnv.authenticatedContext(ultraUid).firestore();
  const googlePlayCloudProUid = "play-cloud-pro-uid";
  const googlePlayCloudProDB = testEnv.authenticatedContext(googlePlayCloudProUid).firestore();

  await step("memory facts require the Data Vault entitlement", async () => {
    const noEntitlementDocID = opaqueId(15);
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/memory_facts/${noEntitlementDocID}`),
        memoryFact(aliceUid, noEntitlementDocID)
      )
    );

    await seedEntitlement(cloudOnlyUid, "hosted_quota_sync", "com.openburnbar.hostedQuotaSync.cloud.monthly");
    const cloudOnlyDocID = opaqueId(0);
    await assertFails(
      setDoc(
        doc(cloudOnlyDB, `users/${cloudOnlyUid}/memory_facts/${cloudOnlyDocID}`),
        memoryFact(cloudOnlyUid, cloudOnlyDocID)
      )
    );
  });

  await step("Cloud Pro owner can write and read a path-bound sealed memory fact", async () => {
    await seedEntitlement(aliceUid, "burnbar_pro_max", "com.openburnbar.proMax.v2.monthly");
    const docID = opaqueId(1);
    await assertSucceeds(
      setDoc(doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`), memoryFact(aliceUid, docID))
    );
    await assertSucceeds(getDoc(doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`)));
  });

  await step("Google Play Cloud Pro owner can write a path-bound sealed memory fact", async () => {
    await seedEntitlement(
      googlePlayCloudProUid,
      "burnbar_pro_max",
      "com.openburnbar.promax.v2.monthly"
    );
    const docID = opaqueId(2);
    await assertSucceeds(
      setDoc(
        doc(googlePlayCloudProDB, `users/${googlePlayCloudProUid}/memory_facts/${docID}`),
        memoryFact(googlePlayCloudProUid, docID)
      )
    );
  });

  await step("Ultra owner can write a path-bound sealed memory fact", async () => {
    await seedEntitlement(ultraUid, "burnbar_ultra", "com.openburnbar.ultra.monthly");
    const docID = opaqueId(3);
    await assertSucceeds(
      setDoc(doc(ultraDB, `users/${ultraUid}/memory_facts/${docID}`), memoryFact(ultraUid, docID))
    );
  });

  await step("cross-user memory fact access fails", async () => {
    const docID = opaqueId(4);
    await assertFails(getDoc(doc(bobDB, `users/${aliceUid}/memory_facts/${docID}`)));
    await assertFails(
      setDoc(doc(bobDB, `users/${aliceUid}/memory_facts/${docID}`), memoryFact(aliceUid, docID))
    );
  });

  await step("memory facts require opaque path and payload ids", async () => {
    const docID = "memory-cleartext";
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`), memoryFact(aliceUid, docID))
    );
  });

  await step("memory facts reject plaintext and vector material", async () => {
    const fields = ["text", "body", "citations", "vector", "cloakedVector", "embedding"];
    for (const [index, field] of fields.entries()) {
      const docID = opaqueId(index + 5);
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`),
          memoryFact(aliceUid, docID, { [field]: field === "citations" ? ["raw"] : "raw" })
        )
      );
    }
  });

  await step("memory facts require path-bound sealed memory", async () => {
    const wrongAadDocID = opaqueId(11);
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/memory_facts/${wrongAadDocID}`),
        memoryFact(aliceUid, wrongAadDocID, { sealedMemory: sealedBlob(memoryAad(aliceUid, opaqueId(12))) })
      )
    );
    const legacySealDocID = opaqueId(13);
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/memory_facts/${legacySealDocID}`),
        memoryFact(aliceUid, legacySealDocID, {
          sealedMemory: {
            schemaVersion: 1,
            algorithm: "AES-256-GCM",
            keyVersion: 1,
            plaintextSHA256: "e".repeat(64),
            sealedBoxBase64: "Q2lwaGVydGV4dA==",
            createdAt: now,
          },
        })
      )
    );
  });

  // ---- Memory blind sync: agent-sourced engine memories -------------------
  // The Memory MCP engine mirrors approved, non-secret rows into the control
  // plane as `source_kind = 'agent'`; the app seals them through the same
  // envelope chat memories already use. The rules therefore admit the `agent`
  // partition and the engine's kind vocabulary — and nothing else.

  await step("agent-sourced engine memories are accepted", async () => {
    for (const [index, kind] of [
      "decision",
      "architecture",
      "procedure",
      "gotcha",
      "todo"
    ].entries()) {
      const docID = agentOpaqueId(index);
      await assertSucceeds(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`),
          memoryFact(aliceUid, docID, { sourceKind: "agent", kind })
        )
      );
    }
  });

  await step("chat memories keep the widened kind vocabulary", async () => {
    const docID = agentOpaqueId(5);
    await assertSucceeds(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`),
        memoryFact(aliceUid, docID, { sourceKind: "chat", kind: "preference" })
      )
    );
  });

  await step("memory facts reject source kinds outside chat and agent", async () => {
    for (const [index, sourceKind] of ["code", "safari_ask", "agent_session", ""].entries()) {
      const docID = agentOpaqueId(index + 6);
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`),
          memoryFact(aliceUid, docID, { sourceKind })
        )
      );
    }
  });

  await step("agent memory facts reject kinds outside the allowlist", async () => {
    const docID = agentOpaqueId(10);
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`),
        memoryFact(aliceUid, docID, { sourceKind: "agent", kind: "secret" })
      )
    );
  });

  await step("agent memory facts reject plaintext and vector material", async () => {
    const fields = ["text", "body", "citations", "vector", "cloakedVector", "embedding"];
    for (const [index, field] of fields.entries()) {
      const docID = agentOpaqueId(index + 11);
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`),
          memoryFact(aliceUid, docID, {
            sourceKind: "agent",
            kind: "decision",
            [field]: field === "citations" ? ["raw"] : "raw"
          })
        )
      );
    }
  });

  await step("agent memory facts still require the Data Vault entitlement", async () => {
    // `cloudOnlyUid` holds a hosted-quota entitlement, not Data Vault.
    const cloudOnlyDocID = agentOpaqueId(0);
    await assertFails(
      setDoc(
        doc(cloudOnlyDB, `users/${cloudOnlyUid}/memory_facts/${cloudOnlyDocID}`),
        memoryFact(cloudOnlyUid, cloudOnlyDocID, { sourceKind: "agent", kind: "decision" })
      )
    );
    // `bobUid` holds no entitlement at all.
    const bobDocID = agentOpaqueId(1);
    await assertFails(
      setDoc(
        doc(bobDB, `users/${bobUid}/memory_facts/${bobDocID}`),
        memoryFact(bobUid, bobDocID, { sourceKind: "agent", kind: "decision" })
      )
    );
  });

  await step("a CloudVault rotation can rewrap a memory fact in place", async () => {
    // Mirrors what CloudVaultRotationRewrapWorker writes: the resealed
    // envelope plus the rotation bookkeeping companions.
    const docID = agentOpaqueId(2);
    await assertSucceeds(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`),
        memoryFact(aliceUid, docID, { sourceKind: "agent", kind: "decision" })
      )
    );
    // The worker paginates `orderBy(documentId()).limit(batch)` before it can
    // reseal anything, so the list query is part of the rotation contract.
    await assertSucceeds(
      getDocs(
        query(
          collection(aliceDB, `users/${aliceUid}/memory_facts`),
          orderBy(documentId()),
          limit(50)
        )
      )
    );
    await assertSucceeds(
      updateDoc(doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`), {
        sealedMemory: sealedBlob(memoryAad(aliceUid, docID)),
        vaultGeneration: 2,
        rewrapJobId: "rotation-job-1",
        updatedAt: serverTimestamp()
      })
    );
  });

  await step("owner can write opaque forget receipts only", async () => {
    const receiptID = opaqueId(14);
    await assertSucceeds(
      setDoc(doc(aliceDB, `users/${aliceUid}/memory_forget_receipts/${receiptID}`), forgetReceipt(aliceUid, receiptID))
    );

    const clearReceiptID = "forget-cleartext";
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/memory_forget_receipts/${clearReceiptID}`),
        forgetReceipt(aliceUid, clearReceiptID)
      )
    );

    for (const [index, field] of ["threadLogicalID", "messageID", "contentHash", "text", "body"].entries()) {
      const fieldReceiptID = opaqueId(index + 15);
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/memory_forget_receipts/${fieldReceiptID}`),
          forgetReceipt(aliceUid, fieldReceiptID, { [field]: "raw" })
        )
      );
    }
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
