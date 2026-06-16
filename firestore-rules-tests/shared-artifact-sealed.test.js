/**
 * Firestore rules tests for V-10 — shared/team artifacts must seal their content.
 *
 * Before this change, `workspaces/workspace-{uid}/teams/{teamId}/artifacts/{id}`
 * (and its `versions/{revisionId}` history) accepted the full source `body`,
 * `title`, and `relativePath` as CLEARTEXT, plus a keyless `contentHash`
 * confirmation oracle — the one CloudVault surface that did NOT seal before
 * Firestore. `sharedArtifactSealedOwnerWrite` now requires:
 *   - contentSealed == true
 *   - a path-bound sealedPayload whose AAD equals
 *       OpenBurnBar-CloudVault-aad-v2|<uid>|<collection>|<docId>|sealedPayload|2|sealedPayload
 *     where collection/docId identify THIS document (head → "artifacts"+artifactId;
 *     version → "artifact_versions"+revisionId), and
 *   - NO cleartext content field (body/title/relativePath/contentHash/…).
 *
 * These tests prove a plaintext write fails, a correctly-sealed write succeeds,
 * and a sealed payload cannot be relocated to another document or downgraded to
 * the legacy global AAD. Mirrors m007-path-bound-sealed-payload.test.js.
 *
 * Run with:
 *   cd firestore-rules-tests && npm run test:shared-artifact-sealed
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
const workspaceId = `workspace-${aliceUid}`;
const teamId = "team-default";
const vaultKeyID = "v1_0123456789abcdef0123456789abcdef";

// Mirrors `cloudVaultAADContext(uid, collection, docID, "sealedPayload")` in
// firestore.rules and `CloudVaultAADContext.stringValue` in CloudVaultCrypto.swift.
function payloadAad(uid, collection, docId) {
  return `OpenBurnBar-CloudVault-aad-v2|${uid}|${collection}|${docId}|sealedPayload|2|sealedPayload`;
}

// The legacy/global AAD `sealPayload` emits without an aadContext.
const GLOBAL_SEALED_PAYLOAD_AAD = "OpenBurnBar-CloudVaultSealedPayload-v2";

function sealedPayload(aad) {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    vaultKeyID,
    sealedBoxBase64: "U2VhbGVkU2hhcmVkQXJ0aWZhY3RDaXBoZXJ0ZXh0Qm9keQ==",
    aad,
  };
}

// A correctly-sealed shared-artifact document: only non-content routing metadata
// is top-level; title/body/relativePath/contentHash live inside the envelope.
function sealedArtifactDoc(artifactId, revisionId, aad) {
  return {
    artifactID: artifactId,
    workspaceID: workspaceId,
    teamID: teamId,
    ownerUserID: aliceUid,
    visibility: "team",
    revisionID: revisionId,
    isDeleted: false,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID,
    updatedByUserID: aliceUid,
    updatedByDeviceID: "mac-device",
    updatedAt: Timestamp.fromMillis(Date.now()),
    sealedPayload: sealedPayload(aad),
  };
}

// The OLD cleartext shape the codec used to write — the V-10 vulnerability.
function plaintextArtifactDoc(artifactId, revisionId) {
  return {
    artifactID: artifactId,
    workspaceID: workspaceId,
    teamID: teamId,
    ownerUserID: aliceUid,
    visibility: "team",
    revisionID: revisionId,
    title: "secret-design.md",
    body: "private source content the cloud must never see",
    contentHash: "a".repeat(64),
    relativePath: "src/secret/design.md",
    isDeleted: false,
    updatedByUserID: aliceUid,
    updatedByDeviceID: "mac-device",
    updatedAt: Timestamp.fromMillis(Date.now()),
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

function artifactPath(artifactId) {
  return `workspaces/${workspaceId}/teams/${teamId}/artifacts/${artifactId}`;
}

function versionPath(artifactId, revisionId) {
  return `${artifactPath(artifactId)}/versions/${revisionId}`;
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

  // ---- head document -------------------------------------------------------
  await step("HEAD rejects a CLEARTEXT artifact write (the V-10 regression)", async () => {
    const artifactId = "artifact-plaintext";
    await assertFails(
      setDoc(doc(aliceDB, artifactPath(artifactId)), plaintextArtifactDoc(artifactId, "rev-1"))
    );
  });

  await step("HEAD accepts a sealed artifact with the exact path-bound AAD", async () => {
    const artifactId = "artifact-sealed";
    await assertSucceeds(
      setDoc(
        doc(aliceDB, artifactPath(artifactId)),
        sealedArtifactDoc(artifactId, "rev-1", payloadAad(aliceUid, "artifacts", artifactId))
      )
    );
  });

  await step("HEAD rejects a sealed payload relocated from another document", async () => {
    const artifactId = "artifact-relocated";
    await assertFails(
      setDoc(
        doc(aliceDB, artifactPath(artifactId)),
        sealedArtifactDoc(artifactId, "rev-1", payloadAad(aliceUid, "artifacts", "artifact-other"))
      )
    );
  });

  await step("HEAD rejects a sealed payload carrying the legacy global AAD", async () => {
    const artifactId = "artifact-global";
    await assertFails(
      setDoc(
        doc(aliceDB, artifactPath(artifactId)),
        sealedArtifactDoc(artifactId, "rev-1", GLOBAL_SEALED_PAYLOAD_AAD)
      )
    );
  });

  await step("HEAD rejects a sealed doc that also smuggles a cleartext body", async () => {
    const artifactId = "artifact-smuggle";
    const smuggled = sealedArtifactDoc(artifactId, "rev-1", payloadAad(aliceUid, "artifacts", artifactId));
    smuggled.body = "private source content the cloud must never see";
    await assertFails(setDoc(doc(aliceDB, artifactPath(artifactId)), smuggled));
  });

  await step("HEAD rejects contentSealed=true with no sealedPayload", async () => {
    const artifactId = "artifact-missing-envelope";
    const doced = sealedArtifactDoc(artifactId, "rev-1", payloadAad(aliceUid, "artifacts", artifactId));
    delete doced.sealedPayload;
    await assertFails(setDoc(doc(aliceDB, artifactPath(artifactId)), doced));
  });

  // ---- version history subdocument ----------------------------------------
  await step("VERSION accepts a sealed revision with the artifact_versions AAD", async () => {
    const artifactId = "artifact-sealed";
    const revisionId = "rev-2";
    await assertSucceeds(
      setDoc(
        doc(aliceDB, versionPath(artifactId, revisionId)),
        sealedArtifactDoc(artifactId, revisionId, payloadAad(aliceUid, "artifact_versions", revisionId))
      )
    );
  });

  await step("VERSION rejects a CLEARTEXT revision write", async () => {
    const artifactId = "artifact-sealed";
    const revisionId = "rev-plaintext";
    await assertFails(
      setDoc(doc(aliceDB, versionPath(artifactId, revisionId)), plaintextArtifactDoc(artifactId, revisionId))
    );
  });

  await step("VERSION rejects a head-bound AAD reused on a version doc", async () => {
    const artifactId = "artifact-sealed";
    const revisionId = "rev-wrongaad";
    await assertFails(
      setDoc(
        doc(aliceDB, versionPath(artifactId, revisionId)),
        // AAD pins collection "artifacts" instead of "artifact_versions".
        sealedArtifactDoc(artifactId, revisionId, payloadAad(aliceUid, "artifacts", revisionId))
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
