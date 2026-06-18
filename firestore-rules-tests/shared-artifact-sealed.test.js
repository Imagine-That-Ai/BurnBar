/**
 * Firestore rules tests for shared/team artifact owner and sealed-content boundaries.
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
const bobUid = "bob-uid";
const teamId = "team-default";
const vaultKeyID = "v1_0123456789abcdef0123456789abcdef";
const sealedPayload = {
  schemaVersion: 2,
  algorithm: "AES-256-GCM",
  keyVersion: 1,
  vaultKeyID,
  sealedBoxBase64: "U2VhbGVkQXJ0aWZhY3RQYXlsb2Fk",
  aad: "OpenBurnBar-CloudVaultSealedPayload-v2",
};

function workspaceId(uid) {
  return `workspace-${uid}`;
}

function artifactPath(uid, artifactId) {
  return `workspaces/${workspaceId(uid)}/teams/${teamId}/artifacts/${artifactId}`;
}

function versionPath(uid, artifactId, revisionId) {
  return `${artifactPath(uid, artifactId)}/versions/${revisionId}`;
}

function artifactDoc(uid, artifactId, revisionId, overrides = {}) {
  return {
    artifactID: artifactId,
    workspaceID: workspaceId(uid),
    teamID: teamId,
    ownerUserID: uid,
    visibility: "team",
    revisionID: revisionId,
    isDeleted: false,
    updatedByUserID: uid,
    updatedByDeviceID: "mac-device",
    updatedAt: Timestamp.fromMillis(Date.now()),
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID,
    sealedPayload,
    ...overrides,
  };
}

async function seedVaultState() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), `users/${aliceUid}/cloud_vault_state/current`), {
      vaultKeyID,
      status: "active",
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
  await seedVaultState();

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();
  const bobDB = testEnv.authenticatedContext(bobUid).firestore();

  await step("owner can write a head artifact in their own workspace", async () => {
    const artifactId = "artifact-owned";
    await assertSucceeds(
      setDoc(doc(aliceDB, artifactPath(aliceUid, artifactId)), artifactDoc(aliceUid, artifactId, "rev-1"))
    );
  });

  await step("owner can write an artifact version in their own workspace", async () => {
    const artifactId = "artifact-owned";
    const revisionId = "rev-2";
    await assertSucceeds(
      setDoc(
        doc(aliceDB, versionPath(aliceUid, artifactId, revisionId)),
        artifactDoc(aliceUid, artifactId, revisionId)
      )
    );
  });

  await step("another user cannot write into the owner's workspace path", async () => {
    const artifactId = "artifact-cross-user";
    await assertFails(
      setDoc(doc(bobDB, artifactPath(aliceUid, artifactId)), artifactDoc(aliceUid, artifactId, "rev-1"))
    );
  });

  await step("owner cannot forge ownerUserID for a different user", async () => {
    const artifactId = "artifact-forged-owner";
    await assertFails(
      setDoc(
        doc(aliceDB, artifactPath(aliceUid, artifactId)),
        artifactDoc(aliceUid, artifactId, "rev-1", { ownerUserID: bobUid })
      )
    );
  });

  await step("owner cannot forge workspaceID away from the path workspace", async () => {
    const artifactId = "artifact-forged-workspace";
    await assertFails(
      setDoc(
        doc(aliceDB, artifactPath(aliceUid, artifactId)),
        artifactDoc(aliceUid, artifactId, "rev-1", { workspaceID: workspaceId(bobUid) })
      )
    );
  });

  await step("owner cannot forge teamID away from the path team", async () => {
    const artifactId = "artifact-forged-team";
    await assertFails(
      setDoc(
        doc(aliceDB, artifactPath(aliceUid, artifactId)),
        artifactDoc(aliceUid, artifactId, "rev-1", { teamID: "team-other" })
      )
    );
  });

  await step("owner cannot write plaintext artifact content fields", async () => {
    const artifactId = "artifact-plaintext";
    await assertFails(
      setDoc(
        doc(aliceDB, artifactPath(aliceUid, artifactId)),
        artifactDoc(aliceUid, artifactId, artifactId, {
          title: "design.md",
          body: "plaintext body",
          relativePath: "plans/design.md",
          contentHash: "sha256:plaintext",
        })
      )
    );
  });

  await step("artifact head body must match the artifact path id", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, artifactPath(aliceUid, "artifact-path")),
        artifactDoc(aliceUid, "artifact-body", "artifact-body")
      )
    );
  });

  await step("artifact version body must match artifact and revision path ids", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, versionPath(aliceUid, "artifact-owned", "rev-path")),
        artifactDoc(aliceUid, "artifact-other", "rev-body")
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
