/**
 * Firestore rules tests for M-007 path-bound sealedPayload enforcement.
 *
 * Regression tests for same-account ciphertext relocation on the sealedPayload
 * surfaces whose WRITERS already emit a path-bound AAD:
 *   - conversations            (Mac: ConversationCloudVaultPayload)
 *   - mobile_assistant_chats   (iOS: MobileChatHistoryStore + Android)
 *
 * Each surface must now accept ONLY a sealedPayload whose `aad` equals
 *   OpenBurnBar-CloudVault-aad-v2|<uid>|<collection>|<docId>|sealedPayload|2|sealedPayload
 * and reject (a) a payload relocated from a different document (same shape, wrong
 * docId in the AAD) and (b) the legacy/global `OpenBurnBar-CloudVaultSealedPayload-v2`
 * AAD that `validCloudSealedPayload` still tolerates structurally.
 *
 * chat_threads and cli_sessions are intentionally NOT covered here: their writers
 * still seal with the global AAD, so they remain on the lenient validator (see
 * `validPathBoundSealedPayloadForUser` comment in firestore.rules). Tightening
 * them would brick legitimate writes — that is a writer-migration prerequisite.
 *
 * Run with:
 *   cd firestore-rules-tests && npm run test:m007-path-bound-sealed-payload
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

// Path-bound sealedPayload AAD: mirrors `cloudVaultAADContext(uid, collection,
// docID, "sealedPayload")` in firestore.rules and `CloudVaultAADContext.stringValue`
// in CloudVaultCrypto.swift.
function payloadAad(uid, collection, docId) {
  return `OpenBurnBar-CloudVault-aad-v2|${uid}|${collection}|${docId}|sealedPayload|2|sealedPayload`;
}

// The legacy/global AAD that sealPayload emits when called WITHOUT an aadContext
// (still emitted by the chat_threads / cli_sessions writers).
const GLOBAL_SEALED_PAYLOAD_AAD = "OpenBurnBar-CloudVaultSealedPayload-v2";

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

function entitlementGranted(productID = "com.openburnbar.pro.monthly") {
  return {
    active: true,
    productID,
    expireAt: futureTimestamp,
  };
}

function conversationDoc(conversationId, aad) {
  return {
    id: conversationId,
    deviceId: "mac-device",
    provider: "openai",
    sessionId: "session-1",
    messageCount: 3,
    userWordCount: 10,
    assistantWordCount: 20,
    updatedAt: Timestamp.fromMillis(Date.now()),
    sourceType: "providerLog",
    version: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID,
    sealedPayload: sealedPayload(aad),
  };
}

function mobileChatDoc(threadId, aad) {
  return {
    id: threadId,
    runtime: "hermes",
    createdAt: Timestamp.fromMillis(Date.now() - 1000),
    updatedAt: Timestamp.fromMillis(Date.now()),
    messageCount: 4,
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
    await setDoc(doc(db, `users/${uid}/cloud_vault_state/current`), {
      vaultKeyID,
      status: "active",
    });
    await setDoc(doc(db, `users/${uid}/entitlements/burnbar_pro`), entitlementGranted());
  });
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
  await seed(aliceUid);

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();

  // ---- conversations -------------------------------------------------------
  await step("conversations accepts a sealedPayload with the exact path-bound AAD", async () => {
    const conversationId = "mac-device_conv-1";
    await assertSucceeds(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/conversations/${conversationId}`),
        conversationDoc(conversationId, payloadAad(aliceUid, "conversations", conversationId))
      )
    );
  });

  await step("conversations rejects a sealedPayload relocated from another document", async () => {
    const conversationId = "mac-device_conv-relocated";
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/conversations/${conversationId}`),
        // AAD pins a DIFFERENT docId — same-account relocation attempt.
        conversationDoc(conversationId, payloadAad(aliceUid, "conversations", "mac-device_conv-other"))
      )
    );
  });

  await step("conversations rejects a sealedPayload carrying the legacy global AAD", async () => {
    const conversationId = "mac-device_conv-global";
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/conversations/${conversationId}`),
        conversationDoc(conversationId, GLOBAL_SEALED_PAYLOAD_AAD)
      )
    );
  });

  // ---- mobile_assistant_chats ---------------------------------------------
  await step("mobile_assistant_chats accepts a sealedPayload with the exact path-bound AAD", async () => {
    const threadId = "thread-1";
    await assertSucceeds(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/mobile_assistant_chats/${threadId}`),
        mobileChatDoc(threadId, payloadAad(aliceUid, "mobile_assistant_chats", threadId))
      )
    );
  });

  await step("mobile_assistant_chats rejects a sealedPayload relocated from another document", async () => {
    const threadId = "thread-relocated";
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/mobile_assistant_chats/${threadId}`),
        mobileChatDoc(threadId, payloadAad(aliceUid, "mobile_assistant_chats", "thread-other"))
      )
    );
  });

  await step("mobile_assistant_chats rejects a sealedPayload carrying the legacy global AAD", async () => {
    const threadId = "thread-global";
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/mobile_assistant_chats/${threadId}`),
        mobileChatDoc(threadId, GLOBAL_SEALED_PAYLOAD_AAD)
      )
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
