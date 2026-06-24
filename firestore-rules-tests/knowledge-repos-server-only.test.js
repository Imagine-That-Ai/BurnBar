/**
 * Firestore rules tests for the server-owned knowledge repo registry.
 *
 * Connected repo rows route webhook and manual resync work through opaque
 * server-keyed tokens. Clients may read their own rows for UI display, but
 * registration and deletion must go through Cloud Functions so clients cannot
 * mint arbitrary source-manifest routing keys.
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import {
  doc,
  getDoc,
  setDoc,
  updateDoc,
  deleteDoc,
  Timestamp,
} from "firebase/firestore";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "firestore.rules",
);
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(
  process.env.FIRESTORE_TEST_PORT || "8080",
  10,
);

const aliceUid = "alice-knowledge-uid";
const bobUid = "bob-knowledge-uid";
const repoId = "a".repeat(64);
const sourceManifestId = "b".repeat(64);
const repoPath = `users/${aliceUid}/knowledge_repos/${repoId}`;

function sealedRepoName() {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    plaintextHMAC: "c".repeat(64),
    integrityHashVersion: 1,
    sealedBoxBase64: "Q2lwaGVydGV4dA==",
    aad: `OpenBurnBar-CloudVault-aad-v2|${aliceUid}|knowledge_repos|${repoId}|sealedRepoFullName|2|sealedRepoFullName`,
    createdAt: Timestamp.fromMillis(Date.now()),
  };
}

function knowledgeRepoDoc(overrides = {}) {
  return {
    uid: aliceUid,
    repoId,
    repoMatchToken: repoId,
    sourceManifestId,
    sealedRepoFullName: sealedRepoName(),
    installId: "install-123",
    connectedAt: Timestamp.fromMillis(Date.now()),
    schemaVersion: 1,
    ...overrides,
  };
}

let passed = 0;
let failed = 0;

async function step(label, fn) {
  try {
    await fn();
    console.log(`PASS ${label}`);
    passed += 1;
  } catch (error) {
    console.error(`FAIL ${label}: ${error.message ?? error}`);
    failed += 1;
  }
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
  const bobDB = testEnv.authenticatedContext(bobUid).firestore();
  const unauthDB = testEnv.unauthenticatedContext().firestore();

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), repoPath), knowledgeRepoDoc());
  });

  await step("owner can read server-owned knowledge repo rows", async () => {
    await assertSucceeds(getDoc(doc(aliceDB, repoPath)));
  });

  await step("other users cannot read knowledge repo rows", async () => {
    await assertFails(getDoc(doc(bobDB, repoPath)));
  });

  await step(
    "unauthenticated users cannot read knowledge repo rows",
    async () => {
      await assertFails(getDoc(doc(unauthDB, repoPath)));
    },
  );

  await step("owner cannot create knowledge repo rows directly", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/knowledge_repos/${"d".repeat(64)}`),
        knowledgeRepoDoc(),
      ),
    );
  });

  await step(
    "owner cannot update source manifest routing keys directly",
    async () => {
      await assertFails(
        updateDoc(doc(aliceDB, repoPath), { sourceManifestId: "e".repeat(64) }),
      );
    },
  );

  await step("owner cannot delete knowledge repo rows directly", async () => {
    await assertFails(deleteDoc(doc(aliceDB, repoPath)));
  });

  await testEnv.cleanup();

  const total = passed + failed;
  console.log(`\n${passed}/${total} cases passed`);
  if (failed > 0) process.exit(1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
