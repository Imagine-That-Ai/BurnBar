/**
 * Firestore rules tests for the roaming profile CloudVault mirror.
 *
 * The roaming profile is a Mac-authored sealed payload. Rules must accept only
 * the owner-scoped `roaming_profile/current` document and only when its
 * CloudVault envelope is AAD-bound to the roaming-profile domain.
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

const aliceUid = "alice-roaming-profile-uid";
const bobUid = "bob-roaming-profile-uid";
const aliceVaultKeyID = `v1_${"a".repeat(32)}`;
const staleVaultKeyID = `v1_${"b".repeat(32)}`;

function roamingAAD(uid) {
  return `OpenBurnBar-CloudVault-aad-v2|${uid}|roaming_profile|current|sealedPayload|2|OpenBurnBar-RoamingProfile-v1`;
}

function sealedPayload(overrides = {}) {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    vaultKeyID: aliceVaultKeyID,
    sealedBoxBase64: "Q2lwaGVydGV4dA==",
    aad: roamingAAD(aliceUid),
    ...overrides,
  };
}

function roamingProfileDoc(overrides = {}) {
  return {
    uid: aliceUid,
    schemaVersion: 1,
    payloadSchemaVersion: 1,
    sourceDeviceID: "mac-roaming-device",
    updatedAt: Timestamp.fromMillis(Date.now()),
    sealedPayload: sealedPayload(),
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
  const profilePath = `users/${aliceUid}/roaming_profile/current`;

  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), `users/${aliceUid}/cloud_vault_state/current`), {
      uid: aliceUid,
      vaultKeyID: aliceVaultKeyID,
      vaultGeneration: 1,
      status: "active",
      createdAt: Timestamp.fromMillis(Date.now()),
      updatedAt: Timestamp.fromMillis(Date.now()),
    });
  });

  await step("owner can write roaming profile current with roaming AAD", async () => {
    await assertSucceeds(setDoc(doc(aliceDB, profilePath), roamingProfileDoc()));
  });

  await step("owner can read roaming profile current", async () => {
    await assertSucceeds(getDoc(doc(aliceDB, profilePath)));
  });

  await step("other users cannot read or write roaming profile", async () => {
    await assertFails(getDoc(doc(bobDB, profilePath)));
    await assertFails(setDoc(doc(bobDB, profilePath), roamingProfileDoc()));
  });

  await step("rules reject generic sealed-payload aad", async () => {
    await assertFails(
      setDoc(doc(aliceDB, profilePath), roamingProfileDoc({
        sealedPayload: sealedPayload({ aad: "OpenBurnBar-CloudVaultSealedPayload-v2" }),
      }))
    );
  });

  await step("rules reject wrong user aad", async () => {
    await assertFails(
      setDoc(doc(aliceDB, profilePath), roamingProfileDoc({
        sealedPayload: sealedPayload({ aad: roamingAAD(bobUid) }),
      }))
    );
  });

  await step("rules reject stale vault key ids", async () => {
    await assertFails(
      setDoc(doc(aliceDB, profilePath), roamingProfileDoc({
        sealedPayload: sealedPayload({ vaultKeyID: staleVaultKeyID }),
      }))
    );
  });

  await step("rules reject non-current roaming profile document ids", async () => {
    await assertFails(setDoc(doc(aliceDB, `users/${aliceUid}/roaming_profile/legacy`), roamingProfileDoc()));
  });

  await step("rules reject plaintext profile fields", async () => {
    await assertFails(
      setDoc(doc(aliceDB, profilePath), roamingProfileDoc({
        providerAccounts: [{ id: "anthropic-primary", credentialKind: "bearer" }],
      }))
    );
    await assertFails(
      setDoc(doc(aliceDB, profilePath), roamingProfileDoc({
        apiKey: "sk-plaintext-secret",
      }))
    );
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
