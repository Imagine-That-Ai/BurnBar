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
import { doc, getDoc, setDoc, Timestamp } from "firebase/firestore";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);
const aliceUid = "alice-uid";
const bobUid = "bob-uid";
const now = Timestamp.fromMillis(Date.now());

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

  await step("owner can write and read a path-bound sealed memory fact", async () => {
    const docID = "memory-1";
    await assertSucceeds(setDoc(doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`), memoryFact(aliceUid, docID)));
    await assertSucceeds(getDoc(doc(aliceDB, `users/${aliceUid}/memory_facts/${docID}`)));
  });

  await step("cross-user memory fact access fails", async () => {
    await assertFails(getDoc(doc(bobDB, `users/${aliceUid}/memory_facts/memory-1`)));
    await assertFails(
      setDoc(doc(bobDB, `users/${aliceUid}/memory_facts/memory-bob`), memoryFact(aliceUid, "memory-bob"))
    );
  });

  await step("memory facts reject plaintext and vector material", async () => {
    const fields = ["text", "body", "citations", "vector", "cloakedVector", "embedding"];
    for (const field of fields) {
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/memory_facts/memory-${field}`),
          memoryFact(aliceUid, `memory-${field}`, { [field]: field === "citations" ? ["raw"] : "raw" })
        )
      );
    }
  });

  await step("memory facts require path-bound sealed memory", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/memory_facts/memory-wrong-aad`),
        memoryFact(aliceUid, "memory-wrong-aad", { sealedMemory: sealedBlob(memoryAad(aliceUid, "other-memory")) })
      )
    );
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/memory_facts/memory-legacy-seal`),
        memoryFact(aliceUid, "memory-legacy-seal", {
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

  await step("owner can write opaque forget receipts only", async () => {
    const receiptID = "forget-1";
    await assertSucceeds(
      setDoc(doc(aliceDB, `users/${aliceUid}/memory_forget_receipts/${receiptID}`), forgetReceipt(aliceUid, receiptID))
    );

    for (const field of ["threadLogicalID", "messageID", "contentHash", "text", "body"]) {
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/memory_forget_receipts/forget-${field}`),
          forgetReceipt(aliceUid, `forget-${field}`, { [field]: "raw" })
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
