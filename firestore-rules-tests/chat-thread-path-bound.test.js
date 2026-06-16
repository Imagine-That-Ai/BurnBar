/**
 * Firestore rules tests for V-11 — chat_threads path-bound sealedPayload.
 *
 * chat_threads was the last Mac-only sealed surface still on the global
 * `validSealedPayloadForUser` validator. Its writer (ChatThreadSyncService) now
 * emits a path-bound AAD (uid|chat_threads|<deviceId>_<threadId>|sealedPayload),
 * and the rule requires it — closing same-account ciphertext relocation for this
 * surface. (cli_sessions stays on the global validator: its sealed content is
 * opened cross-platform by iOS + Android readers, so it needs a coordinated
 * reader migration first — see the m007 note.)
 *
 * Run with:
 *   cd firestore-rules-tests && npm run test:chat-thread-path-bound
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { doc, setDoc, Timestamp } from "firebase/firestore";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);

const aliceUid = "alice-uid";
const vaultKeyID = "v1_0123456789abcdef0123456789abcdef";
const futureTimestamp = Timestamp.fromMillis(Date.now() + 30 * 24 * 60 * 60 * 1000);

function payloadAad(uid, collection, docId) {
  return `OpenBurnBar-CloudVault-aad-v2|${uid}|${collection}|${docId}|sealedPayload|2|sealedPayload`;
}

const GLOBAL_SEALED_PAYLOAD_AAD = "OpenBurnBar-CloudVaultSealedPayload-v2";

function sealedPayload(aad) {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    vaultKeyID,
    sealedBoxBase64: "U2VhbGVkQ2hhdFRocmVhZENpcGhlcnRleHRCb2R5",
    aad,
  };
}

// A backed-up chat-thread doc (the exact key set `validChatThreadKeys` allows).
function chatThreadDoc(threadId, deviceId, aad) {
  return {
    threadId,
    messageCount: 3,
    createdAt: Timestamp.fromMillis(Date.now() - 1000),
    updatedAt: Timestamp.fromMillis(Date.now()),
    deviceId,
    contentIncluded: true,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID,
    sealedPayload: sealedPayload(aad),
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

async function seed(uid) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `users/${uid}/cloud_vault_state/current`), { vaultKeyID, status: "active" });
    await setDoc(doc(db, `users/${uid}/entitlements/burnbar_pro`), {
      active: true,
      productID: "com.openburnbar.pro.monthly",
      expireAt: futureTimestamp,
    });
  });
}

async function main() {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules: readFileSync(RULES_PATH, "utf8"), host: FIRESTORE_HOST, port: FIRESTORE_PORT },
  });
  await testEnv.clearFirestore();
  await seed(aliceUid);

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();
  const deviceId = "mac-device";

  await step("chat_threads accepts a sealedPayload with the exact path-bound AAD", async () => {
    const docId = `${deviceId}_thread-1`;
    await assertSucceeds(
      setDoc(doc(aliceDB, `users/${aliceUid}/chat_threads/${docId}`),
        chatThreadDoc("thread-1", deviceId, payloadAad(aliceUid, "chat_threads", docId)))
    );
  });

  await step("chat_threads rejects a sealedPayload relocated from another document", async () => {
    const docId = `${deviceId}_thread-relocated`;
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/chat_threads/${docId}`),
        chatThreadDoc("thread-relocated", deviceId, payloadAad(aliceUid, "chat_threads", `${deviceId}_thread-other`)))
    );
  });

  await step("chat_threads rejects a sealedPayload carrying the legacy global AAD", async () => {
    const docId = `${deviceId}_thread-global`;
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/chat_threads/${docId}`),
        chatThreadDoc("thread-global", deviceId, GLOBAL_SEALED_PAYLOAD_AAD))
    );
  });

  await step("chat_threads still accepts a metadata-only (unsealed) write", async () => {
    const docId = `${deviceId}_thread-meta`;
    await assertSucceeds(
      setDoc(doc(aliceDB, `users/${aliceUid}/chat_threads/${docId}`), {
        threadId: "thread-meta",
        messageCount: 0,
        createdAt: Timestamp.fromMillis(Date.now()),
        updatedAt: Timestamp.fromMillis(Date.now()),
        deviceId,
        contentIncluded: false,
      })
    );
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
