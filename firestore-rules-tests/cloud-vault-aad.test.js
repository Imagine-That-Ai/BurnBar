/**
 * Firestore rules tests for CloudVault path-bound AAD enforcement.
 *
 * These are regression tests for same-account ciphertext relocation: current
 * sealed usage/budget fields must carry the exact user/collection/doc/field AAD
 * string, not a generic CloudVault-shaped AAD and not the legacy no-AAD shape.
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

function aad(uid, collection, docID, field) {
  return `OpenBurnBar-CloudVault-aad-v2|${uid}|${collection}|${docID}|${field}|2|${field}`;
}

function sealedText(pathAad) {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    nonce: "QUJDREVGR0hJSktM",
    ciphertext: "Q2lwaGVydGV4dA==",
    tag: "VGFnVGFnVGFnVGFn",
    aad: pathAad,
  };
}

function legacySealedText() {
  return {
    schemaVersion: 1,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    nonce: "QUJDREVGR0hJSktM",
    ciphertext: "Q2lwaGVydGV4dA==",
    tag: "VGFnVGFnVGFnVGFn",
  };
}

async function main() {
  const testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(RULES_PATH, "utf8"),
      host: FIRESTORE_HOST,
      port: FIRESTORE_PORT,
    },
  });
  await testEnv.clearFirestore();

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();
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

  await step("usage sealedProjectName requires exact path-bound AAD", async () => {
    const usageId = "mac-1_usage-1";
    await assertSucceeds(
      setDoc(doc(aliceDB, `users/${aliceUid}/usage/${usageId}`), {
        id: "usage-1",
        deviceId: "mac-1",
        provider: "openai",
        sealedProjectName: sealedText(aad(aliceUid, "usage", usageId, "sealedProjectName")),
        updatedAt: Timestamp.fromMillis(Date.now()),
      })
    );
  });

  await step("usage rejects relocated or legacy sealedProjectName", async () => {
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/usage/mac-1_usage-wrong-aad`), {
        id: "usage-wrong-aad",
        sealedProjectName: sealedText(aad(aliceUid, "usage", "different-doc", "sealedProjectName")),
      })
    );
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/usage/mac-1_usage-legacy-aad`), {
        id: "usage-legacy-aad",
        sealedProjectName: legacySealedText(),
      })
    );
  });

  await step("budget rules require exact path-bound AAD for both private fields", async () => {
    const ruleId = "rule-1";
    await assertSucceeds(
      setDoc(doc(aliceDB, `users/${aliceUid}/budgetRules/${ruleId}`), {
        id: ruleId,
        sealedProjectName: sealedText(aad(aliceUid, "budgetRules", ruleId, "sealedProjectName")),
        sealedLabel: sealedText(aad(aliceUid, "budgetRules", ruleId, "sealedLabel")),
      })
    );
  });

  await step("budget rules reject relocated and legacy private sealed fields", async () => {
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/budgetRules/rule-wrong-aad`), {
        id: "rule-wrong-aad",
        sealedProjectName: sealedText(aad(aliceUid, "budgetRules", "other-rule", "sealedProjectName")),
      })
    );
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/budgetRules/rule-legacy-aad`), {
        id: "rule-legacy-aad",
        sealedLabel: legacySealedText(),
      })
    );
  });

  await step("text_snippets require exact path-bound AAD and valid escrow keys", async () => {
    // Seed valid escrow key
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const adminDb = context.firestore();
      await setDoc(doc(adminDb, `users/${aliceUid}/escrow_public_keys/mac-1_1`), {
        deviceId: "mac-1",
        publicKeyData: "A".repeat(88),
        publicKeyFingerprint: "F".repeat(44),
        keyVersion: 1,
        algorithm: "ECIES-P256-AESGCM",
      });
    });

    const snippetId = "snippet-1";
    await assertSucceeds(
      setDoc(doc(aliceDB, `users/${aliceUid}/text_snippets/${snippetId}`), {
        id: snippetId,
        uid: aliceUid,
        sourceDeviceID: "mac-1",
        triggerHash: "a".repeat(32),
        sealedTitle: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedTitle")),
        sealedTrigger: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedTrigger")),
        sealedBody: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedBody")),
        sealedScope: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedScope")),
        mode: "llm_rewrite",
        isEnabled: true,
        revision: 1,
        createdAt: Timestamp.fromMillis(Date.now()),
        updatedAt: Timestamp.fromMillis(Date.now()),
        deletedAt: null,
        schemaVersion: 2,
        encryption: {
          algorithm: "AES-256-GCM",
          keyVersion: 1,
          tokenHashVersion: 1,
        },
      })
    );
  });

  await step("text_snippets reject relocated, legacy, or unregistered keys", async () => {
    const snippetId = "snippet-2";
    // Relocated AAD
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/text_snippets/${snippetId}`), {
        id: snippetId,
        uid: aliceUid,
        sourceDeviceID: "mac-1",
        triggerHash: "a".repeat(32),
        sealedTitle: sealedText(aad(aliceUid, "text_snippets", "different-snippet", "sealedTitle")),
        sealedTrigger: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedTrigger")),
        sealedBody: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedBody")),
        sealedScope: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedScope")),
        mode: "static",
        isEnabled: true,
        revision: 1,
        schemaVersion: 2,
      })
    );

    // Legacy (schemaVersion <= 1)
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/text_snippets/${snippetId}`), {
        id: snippetId,
        uid: aliceUid,
        sourceDeviceID: "mac-1",
        triggerHash: "a".repeat(32),
        sealedTitle: legacySealedText(),
        sealedTrigger: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedTrigger")),
        sealedBody: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedBody")),
        sealedScope: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedScope")),
        mode: "static",
        isEnabled: true,
        revision: 1,
        schemaVersion: 2,
      })
    );

    // Unregistered keyVersion (99)
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/text_snippets/${snippetId}`), {
        id: snippetId,
        uid: aliceUid,
        sourceDeviceID: "mac-1",
        triggerHash: "a".repeat(32),
        sealedTitle: {
          ...sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedTitle")),
          keyVersion: 99,
        },
        sealedTrigger: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedTrigger")),
        sealedBody: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedBody")),
        sealedScope: sealedText(aad(aliceUid, "text_snippets", snippetId, "sealedScope")),
        mode: "static",
        isEnabled: true,
        revision: 1,
        schemaVersion: 2,
      })
    );
  });

  await testEnv.cleanup();
  console.log(`\n${runs - failures}/${runs} cases passed`);
  if (failures > 0) process.exit(1);
}

main().catch((error) => {
  console.error(error);
  process.exit(2);
});
