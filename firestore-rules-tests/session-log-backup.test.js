/**
 * Firestore rules emulator test for encrypted session-log backup manifests.
 *
 * Run with:
 *   cd firestore-rules-tests && npm run test:session-log-backup
 */
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import {
  deleteDoc,
  doc,
  deleteField,
  setDoc,
  Timestamp,
  serverTimestamp,
} from "firebase/firestore";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);
const aliceUid = "alice-uid";
const bobUid = "bob-uid";
const futureTimestamp = Timestamp.fromMillis(Date.now() + 30 * 24 * 60 * 60 * 1000);

function entitlementGranted(productID = "com.openburnbar.pro.monthly") {
  return {
    active: true,
    productID,
    expireAt: futureTimestamp,
    features: {
      encryptedSessionLogBackup: true,
      cloudConversationSearch: true,
    },
  };
}

function cloudVaultAADContext(uid, collection, docID, field) {
  return `OpenBurnBar-CloudVault-aad-v2|${uid}|${collection}|${docID}|${field}|2|${field}`;
}

function sealedText(aad) {
  const value = {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    nonce: "A".repeat(16),
    ciphertext: "B".repeat(64),
    tag: "C".repeat(24),
  };
  if (aad !== undefined) value.aad = aad;
  return value;
}

function validManifest(uid = aliceUid) {
  const documentID = "mac-device_Factory_8adc9f4f-cfce-4856-9537-6feaa5e8ae8e";
  const bodyHash = "a".repeat(64);
  return {
    path: `users/${uid}/session_logs/${documentID}`,
    data: {
      id: "Factory:8adc9f4f-cfce-4856-9537-6feaa5e8ae8e",
      deviceId: "mac-device",
      provider: "Factory",
      sessionId: "8adc9f4f-cfce-4856-9537-6feaa5e8ae8e",
      sourceType: "provider_log",
      inferredTaskTitle: "Encrypted session",
      bodyStorage: "firebase_storage_encrypted",
      storagePath: `users/${uid}/session_logs/${documentID}/bodies/${bodyHash}.json.aesgcm`,
      sealedTitle: sealedText(cloudVaultAADContext(uid, "session_logs", documentID, "sealedTitle")),
      sealedBodyPreview: sealedText(cloudVaultAADContext(uid, "session_logs", documentID, "sealedBodyPreview")),
      encryption: {
        algorithm: "AES-GCM",
        keyVersion: 1,
        tokenHashVersion: 1,
        semanticHashVersion: 1,
      },
      chunkCount: 0,
      searchChunkCount: 1,
      byteCount: 1024,
      encryptedByteCount: 1400,
      bodyHash,
      chunkSize: 0,
      chunkHashes: [bodyHash],
      chunkMetadataVersion: 4,
      cloudSearchIndexVersion: 4,
      cloudSearchIndexedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      facetSchemaVersion: 3,
      model: "Droid",
      messageCount: 1,
      userWordCount: 4,
      assistantWordCount: 6,
      inputTokens: 10,
      outputTokens: 12,
      cacheCreationTokens: 0,
      cacheReadTokens: 0,
      totalTokens: 22,
      costUSD: 0.01,
      durationSeconds: 120,
      toolTags: ["other"],
      startTime: Timestamp.fromMillis(Date.now() - 120_000),
      endTime: Timestamp.fromMillis(Date.now()),
    },
  };
}

function legacyEncryptedManifest(uid = aliceUid) {
  const manifest = validManifest(uid);
  const data = { ...manifest.data };
  delete data.facetSchemaVersion;
  delete data.userWordCount;
  delete data.assistantWordCount;
  delete data.inputTokens;
  delete data.outputTokens;
  delete data.cacheCreationTokens;
  delete data.cacheReadTokens;
  delete data.totalTokens;
  delete data.costUSD;
  delete data.durationSeconds;
  delete data.toolTags;
  data.projectName = "Legacy plaintext project";
  data.workingDirectory = "/Users/alice/LegacyPlaintextProject";
  data.chunkSize = 900000;
  data.chunkCount = 1;
  data.model = "unknown";
  return { path: manifest.path, data };
}

function validFacetRefresh() {
  return {
    body: deleteField(),
    payloadCiphertext: deleteField(),
    ciphertext: deleteField(),
    data: deleteField(),
    text: deleteField(),
    title: deleteField(),
    snippet: deleteField(),
    terms: deleteField(),
    projectName: deleteField(),
    workingDirectory: deleteField(),
    facetSchemaVersion: 3,
    model: "Droid",
    messageCount: 1,
    userWordCount: 4,
    assistantWordCount: 6,
    inputTokens: 10,
    outputTokens: 12,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
    totalTokens: 22,
    costUSD: 0.01,
    durationSeconds: 120,
    toolTags: ["other"],
    updatedAt: serverTimestamp(),
  };
}

function validChunk(uid = aliceUid, index = 0) {
  const manifest = validManifest(uid);
  return {
    path: `${manifest.path}/chunks/${index}`,
    data: {
      index,
      uid,
      docId: manifest.path.split("/").pop(),
      conversationId: manifest.data.id,
      sessionId: manifest.data.sessionId,
      deviceId: manifest.data.deviceId,
      provider: manifest.data.provider,
      model: manifest.data.model,
      sealedSnippet: sealedText(),
      tokenHashes: ["a".repeat(32)],
      semanticHashes: ["b".repeat(32)],
      semanticHashVersion: 1,
      bodyStorage: "firebase_storage_encrypted",
      storagePath: manifest.data.storagePath,
      bodyHash: manifest.data.bodyHash,
      schemaVersion: 1,
      updatedAt: serverTimestamp(),
    },
  };
}

function legacyPlaintextChunk(uid = aliceUid) {
  const chunk = validChunk(uid);
  return {
    path: chunk.path,
    data: {
      ...chunk.data,
      body: "legacy plaintext body",
      title: "legacy title",
      snippet: "legacy snippet",
      terms: ["legacy", "plaintext"],
    },
  };
}

const OFF_ALLOWLIST_PLAINTEXT_FIELDS = {
  body: "plaintext body",
  userPrompt: "summarize the repository",
  summary: "plaintext session summary",
  command: "cat ~/.ssh/id_rsa",
  keystrokes: "cmd+space terminal",
  clipboard: "copied sensitive text",
  transcript: "full plaintext transcript",
  messages: [{ role: "user", text: "plaintext" }],
  lastAssistantMessage: "plaintext assistant output",
  keyCommands: ["npm test"],
  keyFiles: ["src/secrets.ts"],
  url: "https://example.test/private",
  selector: "#password",
  projectName: "~/Documents/Windsurf/SecretProject",
  workingDirectory: "~/Documents/Windsurf/SecretProject",
};

let testEnv;
let failures = 0;
let runs = 0;

async function step(name, fn) {
  runs += 1;
  try {
    await fn();
    console.log(`  ✓ ${name}`);
  } catch (e) {
    failures += 1;
    console.error(`  ✕ ${name}\n    ${e && e.message ? e.message : e}`);
  }
}

async function seedEntitlement(uid) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const dbAdmin = ctx.firestore();
    await setDoc(
      doc(dbAdmin, `users/${uid}/entitlements/burnbar_pro`),
      entitlementGranted()
    );
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

  console.log("Encrypted session-log backup Firestore rules tests");

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();
  const aliceManifest = validManifest();

  await step("session-log manifest is rejected without entitlement", async () => {
    await assertFails(setDoc(doc(aliceDB, aliceManifest.path), aliceManifest.data));
  });

  await seedEntitlement(aliceUid);

  await step("session-log manifest is accepted with BurnBar Pro entitlement", async () => {
    await assertSucceeds(setDoc(doc(aliceDB, aliceManifest.path), aliceManifest.data));
  });

  await step("existing session-log manifest can be tombstoned with typed lifecycle fields", async () => {
    await assertSucceeds(setDoc(
      doc(aliceDB, aliceManifest.path),
      {
        deletedAt: serverTimestamp(),
        version: 2,
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    ));
  });

  await step("existing session-log manifest rejects malformed lifecycle fields", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, aliceManifest.path),
        { deletedAt: "2026-06-24T00:00:00.000Z", updatedAt: serverTimestamp() },
        { merge: true }
      )
    );
    await assertFails(
      setDoc(
        doc(aliceDB, aliceManifest.path),
        { version: "2", updatedAt: serverTimestamp() },
        { merge: true }
      )
    );
  });

  await step("existing encrypted manifest can be refreshed with searchable facets", async () => {
    const legacy = legacyEncryptedManifest();
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), legacy.path), legacy.data);
    });
    await assertSucceeds(setDoc(doc(aliceDB, aliceManifest.path), validFacetRefresh(), { merge: true }));
  });

  await step("session-log chunks are server-owned and reject legacy plaintext merges", async () => {
    const legacy = legacyPlaintextChunk();
    const clean = validChunk();
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), legacy.path), legacy.data);
    });
    await assertFails(setDoc(doc(aliceDB, clean.path), clean.data, { merge: true }));
    await assertFails(setDoc(doc(aliceDB, clean.path), clean.data));
    await assertSucceeds(deleteDoc(doc(aliceDB, legacy.path)));
  });

  await step("session-log manifest cannot be written into another user namespace", async () => {
    const bobManifest = validManifest(bobUid);
    await assertFails(setDoc(doc(aliceDB, bobManifest.path), bobManifest.data, { merge: true }));
  });

  for (const [field, value] of Object.entries(OFF_ALLOWLIST_PLAINTEXT_FIELDS)) {
    await step(`session-log manifest rejects off-allowlist plaintext field '${field}'`, async () => {
      await assertFails(
        setDoc(doc(aliceDB, aliceManifest.path), { ...aliceManifest.data, [field]: value }, { merge: true })
      );
    });
  }

  await testEnv.cleanup();
  if (failures > 0) {
    console.error(`\n${failures}/${runs} session-log backup rules tests failed.`);
    process.exit(1);
  }
  console.log(`\n${runs} session-log backup rules tests passed.`);
}

main().catch(async (e) => {
  failures += 1;
  console.error(e);
  if (testEnv) await testEnv.cleanup();
  process.exit(1);
});
