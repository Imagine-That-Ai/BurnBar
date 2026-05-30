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
  doc,
  setDoc,
  Timestamp,
  serverTimestamp,
} from "firebase/firestore";

const PROJECT_ID = "burnbar-test";
const RULES_PATH = "../firestore.rules";
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

function sealedText() {
  return {
    algorithm: "AES-GCM",
    keyVersion: 1,
    nonce: "A".repeat(16),
    ciphertext: "B".repeat(64),
  };
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
      projectName: "~/Documents/Windsurf/ImagineThatAiApp/Imagine/That.Ai/App/2.0",
      inferredTaskTitle: "Encrypted session",
      bodyStorage: "firebase_storage_encrypted",
      storagePath: `users/${uid}/session_logs/${documentID}/bodies/${bodyHash}.json.aesgcm`,
      sealedTitle: sealedText(),
      sealedBodyPreview: sealedText(),
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
      facetSchemaVersion: 2,
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
      workingDirectory: "~/Documents/Windsurf/ImagineThatAiApp/Imagine/That.Ai/App/2.0",
      durationSeconds: 120,
      toolTags: ["run"],
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
  delete data.workingDirectory;
  delete data.durationSeconds;
  delete data.toolTags;
  data.chunkSize = 900000;
  data.chunkCount = 1;
  data.model = "unknown";
  return { path: manifest.path, data };
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
      projectName: manifest.data.projectName,
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
      host: "127.0.0.1",
      port: 8080,
    },
  });

  console.log("Encrypted session-log backup Firestore rules tests");

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();
  const aliceManifest = validManifest();

  await step("session-log manifest is rejected without entitlement", async () => {
    await assertFails(setDoc(doc(aliceDB, aliceManifest.path), aliceManifest.data, { merge: true }));
  });

  await seedEntitlement(aliceUid);

  await step("session-log manifest is accepted with BurnBar Pro entitlement", async () => {
    await assertSucceeds(setDoc(doc(aliceDB, aliceManifest.path), aliceManifest.data, { merge: true }));
  });

  await step("existing encrypted manifest can be refreshed with searchable facets", async () => {
    const legacy = legacyEncryptedManifest();
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), legacy.path), legacy.data);
    });
    await assertSucceeds(setDoc(doc(aliceDB, aliceManifest.path), aliceManifest.data, { merge: true }));
  });

  await step("legacy plaintext chunk must be overwritten, not merged", async () => {
    const legacy = legacyPlaintextChunk();
    const clean = validChunk();
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), legacy.path), legacy.data);
    });
    await assertFails(setDoc(doc(aliceDB, clean.path), clean.data, { merge: true }));
    await assertSucceeds(setDoc(doc(aliceDB, clean.path), clean.data));
  });

  await step("session-log manifest cannot be written into another user namespace", async () => {
    const bobManifest = validManifest(bobUid);
    await assertFails(setDoc(doc(aliceDB, bobManifest.path), bobManifest.data, { merge: true }));
  });

  await step("session-log manifest rejects plaintext body fields", async () => {
    await assertFails(
      setDoc(doc(aliceDB, aliceManifest.path), { ...aliceManifest.data, body: "plaintext" }, { merge: true })
    );
  });

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
