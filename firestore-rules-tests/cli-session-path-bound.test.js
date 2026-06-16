/**
 * Firestore rules tests for cli_sessions path-bound sealedPayload enforcement.
 *
 * A valid cli_sessions write must bind the sealed transcript envelope to the
 * exact Firestore document path:
 *   users/{uid}/cli_sessions/{sessionId}.sealedPayload
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
const GLOBAL_SEALED_PAYLOAD_AAD = "OpenBurnBar-CloudVaultSealedPayload-v2";

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

function cliSessionDoc(sessionId, aad) {
  const now = Timestamp.fromMillis(Date.now());
  return {
    id: sessionId,
    agent: "codex",
    sourceKind: "live_chat",
    createdAt: now,
    updatedAt: now,
    schemaVersion: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID,
    sealedPayload: sealedPayload(aad),
    messageCount: 2,
    lastMessageRole: "assistant",
    lastAssistantMessageID: "message-2",
    encryptedTranscriptAvailable: false,
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

  await step("cli_sessions accepts a sealedPayload with the exact path-bound AAD", async () => {
    const sessionId = "session-1";
    await assertSucceeds(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/cli_sessions/${sessionId}`),
        cliSessionDoc(sessionId, payloadAad(aliceUid, "cli_sessions", sessionId))
      )
    );
  });

  await step("cli_sessions rejects a sealedPayload relocated from another document", async () => {
    const sessionId = "session-relocated";
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/cli_sessions/${sessionId}`),
        cliSessionDoc(sessionId, payloadAad(aliceUid, "cli_sessions", "session-other"))
      )
    );
  });

  await step("cli_sessions rejects a sealedPayload carrying the legacy global AAD", async () => {
    const sessionId = "session-global";
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/cli_sessions/${sessionId}`),
        cliSessionDoc(sessionId, GLOBAL_SEALED_PAYLOAD_AAD)
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
