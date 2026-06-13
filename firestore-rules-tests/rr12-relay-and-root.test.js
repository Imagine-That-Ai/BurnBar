/**
 * Firestore rules emulator test for the RR-12 remediation surfaces.
 *
 * Validates that:
 *   - The owner CANNOT delete a `cloud_vault_key_wrappers` doc (rotation/
 *     revocation are server-owned; `allow delete: if false`).
 *   - A `users/{uid}` root-profile write carrying a disallowed/secret field is
 *     rejected, while an allowlisted profile write is accepted
 *     (`validRootUserProfileWrite`).
 *   - A `pi_agent_relay_requests` write WITHOUT the sender-authentication
 *     fields (`senderPublicKey`/`senderDeviceId`/`senderPeerNodeId`/
 *     `senderCounter`) is rejected, while a sender-bound write is accepted —
 *     sender-auth parity with the Hermes `relayRequestWrite` lane.
 *
 * Run with:
 *   cd firestore-rules-tests && npm test
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import {
  deleteDoc,
  doc,
  setDoc,
  Timestamp,
} from "firebase/firestore";

const PROJECT_ID = "burnbar-test";
const RULES_PATH = "../firestore.rules";

const aliceUid = "alice-uid";

const futureTimestamp = Timestamp.fromMillis(Date.now() + 30 * 24 * 60 * 60 * 1000);

function entitlementGranted(productID = "com.openburnbar.hostedQuotaSync.monthly") {
  return {
    active: true,
    productID,
    expireAt: futureTimestamp,
    features: {
      hostedQuotaSync: true,
      hostedCloudBackup: true,
    },
  };
}

// A sender-bound Pi relay request mirroring the Hermes lane's sender-auth
// fields. `senderPublicKey` must be 80..128 chars to clear the size check.
const validPiRelayRequest = {
  id: "pi-relay-request-1",
  connectionId: "pi-connection-1",
  operation: "chatCompletions",
  status: "pending",
  method: "POST",
  payloadCiphertext: "B".repeat(256),
  wrappedKey: "C".repeat(128),
  relayEncryption: "p256-hkdf-sha256-aesgcm",
  relayKeyVersion: 1,
  senderPublicKey: "A".repeat(88),
  senderDeviceId: "ios-phone-1",
  senderPeerNodeId: "pi-peer-node-1",
  senderCounter: 0,
  chunkCount: 0,
  schemaVersion: 2,
  createdAt: Timestamp.fromMillis(Date.now()),
};

// A privileged-path fixture for an existing key-wrapper doc. We never need the
// create validator to pass — the test only asserts the owner cannot DELETE.
const seededKeyWrapper = {
  uid: aliceUid,
  targetDeviceId: "iphone-1",
  sourceDeviceId: "mac-1",
  publicKeyFingerprint: "a".repeat(64),
  keyVersion: 1,
  wrappedVaultKey: "D".repeat(128),
  vaultKeyID: "v1_" + "a".repeat(32),
  algorithm: "ECIES-P256-AESGCM",
  status: "active",
  schemaVersion: 3,
  createdAt: Timestamp.fromMillis(Date.now()),
  updatedAt: Timestamp.fromMillis(Date.now()),
};

async function withEntitlement(testEnv, uid, body) {
  // Seed the entitlement via the privileged path so we don't need to
  // write a separate rule for the test fixture.
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const dbAdmin = ctx.firestore();
    await setDoc(
      doc(dbAdmin, `users/${uid}/entitlements/hosted_quota_sync`),
      entitlementGranted()
    );
  });
  return body();
}

async function seedKeyWrapper(testEnv, uid, wrapperId) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const dbAdmin = ctx.firestore();
    await setDoc(
      doc(dbAdmin, `users/${uid}/cloud_vault_key_wrappers/${wrapperId}`),
      seededKeyWrapper
    );
  });
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

async function main() {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(RULES_PATH, "utf8"),
      host: "127.0.0.1",
      port: 8080,
    },
  });

  console.log("RR-12 relay + root-profile Firestore rules emulator tests");

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();

  // --- cloud_vault_key_wrappers: owner DELETE is server-denied ---
  await step("owner cannot delete a cloud_vault_key_wrappers doc", async () => {
    await seedKeyWrapper(testEnv, aliceUid, "wrapper-1");
    await assertFails(
      deleteDoc(doc(aliceDB, `users/${aliceUid}/cloud_vault_key_wrappers/wrapper-1`))
    );
  });

  // --- users/{uid} root profile: allowlist enforcement ---
  await step("root user-profile write with an allowlisted shape is accepted", async () => {
    await assertSucceeds(
      setDoc(doc(aliceDB, `users/${aliceUid}`), {
        uid: aliceUid,
        displayName: "Alice",
        email: "alice@example.com",
        platform: "iOS",
        appVersion: "1.0.0",
        schemaVersion: 1,
        updatedAt: Timestamp.fromMillis(Date.now()),
      })
    );
  });

  await step("root user-profile write with a disallowed field is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}`), {
        uid: aliceUid,
        displayName: "Alice",
        schemaVersion: 1,
        // Not on the allowlist — a writer must not be able to graft arbitrary
        // state onto the root profile doc.
        isAdmin: true,
      })
    );
  });

  await step("root user-profile write with a secret-looking field is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}`), {
        uid: aliceUid,
        displayName: "Alice",
        schemaVersion: 1,
        apiKey: "sk-should-never-land-here",
      })
    );
  });

  // --- pi_agent_relay_requests: sender-auth parity with the Hermes lane ---
  await withEntitlement(testEnv, aliceUid, async () => {
    await step("pi relay request WITHOUT sender-auth fields is rejected", async () => {
      const { senderPublicKey, senderDeviceId, senderPeerNodeId, senderCounter, ...unbound } =
        validPiRelayRequest;
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/pi_agent_relay_requests/${validPiRelayRequest.id}`),
          unbound
        )
      );
    });

    await step("pi relay request with a too-short senderPublicKey is rejected", async () => {
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/pi_agent_relay_requests/${validPiRelayRequest.id}`),
          { ...validPiRelayRequest, senderPublicKey: "A".repeat(40) }
        )
      );
    });

    await step("pi relay request WITH sender-auth fields is accepted", async () => {
      await assertSucceeds(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/pi_agent_relay_requests/${validPiRelayRequest.id}`),
          validPiRelayRequest
        )
      );
    });
  });

  await testEnv.cleanup();
  console.log(`\n${runs - failures}/${runs} cases passed`);
  if (failures > 0) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(2);
});
