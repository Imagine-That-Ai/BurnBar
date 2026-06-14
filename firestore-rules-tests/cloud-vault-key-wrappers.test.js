/**
 * Firestore rules tests for CloudVault key-wrapper identity pinning.
 *
 * The wrapper document id is part of the security boundary: direct owner writes
 * may create/refresh only active wrappers whose id is bound to
 * vaultKeyID_targetDeviceId_keyVersion. Identity-bearing fields are immutable
 * after create; rotation/revocation status changes are server/Admin-owned.
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { doc, setDoc, Timestamp, updateDoc } from "firebase/firestore";

const PROJECT_ID = "burnbar-test";
const RULES_PATH = "../firestore.rules";
const aliceUid = "alice-uid";
const vaultKeyID = "v1_" + "a".repeat(32);
const wrapperId = `${vaultKeyID}_iphone-1_1`;
const futureTimestamp = Timestamp.fromMillis(Date.now() + 30 * 24 * 60 * 60 * 1000);

function entitlementGranted() {
  return {
    active: true,
    productID: "com.openburnbar.hostedQuotaSync.monthly",
    expireAt: futureTimestamp,
    features: {
      hostedQuotaSync: true,
      hostedCloudBackup: true,
    },
  };
}

function wrapper(overrides = {}) {
  return {
    uid: aliceUid,
    targetDeviceId: "iphone-1",
    sourceDeviceId: "mac-1",
    publicKeyFingerprint: "fpr-iphone-1",
    keyVersion: 1,
    wrappedVaultKey: "Q2lwaGVydGV4dA==",
    vaultKeyID,
    algorithm: "ECIES-P256-AESGCM",
    status: "active",
    createdAt: Timestamp.fromMillis(Date.now()),
    updatedAt: Timestamp.fromMillis(Date.now()),
    schemaVersion: 3,
    ...overrides,
  };
}

async function seed(testEnv) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const dbAdmin = ctx.firestore();
    await setDoc(doc(dbAdmin, `users/${aliceUid}/entitlements/hosted_quota_sync`), entitlementGranted());
    await setDoc(doc(dbAdmin, `users/${aliceUid}/cloud_vault_state/current`), {
      uid: aliceUid,
      vaultKeyID,
      status: "active",
      updatedAt: Timestamp.fromMillis(Date.now()),
    });
    for (const [deviceId, platform] of [["iphone-1", "iOS"], ["mac-1", "macOS"]]) {
      await setDoc(doc(dbAdmin, `users/${aliceUid}/escrow_devices/${deviceId}`), {
        deviceId,
        platform,
        trustState: "trusted",
        keyVersion: 1,
        updatedAt: Timestamp.fromMillis(Date.now()),
      });
    }
  });
}

async function main() {
  const testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(RULES_PATH, "utf8"),
      host: "127.0.0.1",
      port: 8080,
    },
  });
  await testEnv.clearFirestore();
  await seed(testEnv);

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

  await step("owner can create a deterministic active wrapper for trusted devices", async () => {
    await assertSucceeds(
      setDoc(doc(aliceDB, `users/${aliceUid}/cloud_vault_key_wrappers/${wrapperId}`), wrapper())
    );
  });

  await step("wrapper create rejects arbitrary document ids", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/cloud_vault_key_wrappers/attacker-wrapper`),
        wrapper({ wrapperId: "attacker-wrapper" })
      )
    );
  });

  await step("wrapper create rejects ids not bound to the target device", async () => {
    const shadowId = `${vaultKeyID}_mac-1_1`;
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/cloud_vault_key_wrappers/${shadowId}`),
        wrapper({ wrapperId: shadowId, targetDeviceId: "iphone-1" })
      )
    );
  });

  await step("active wrapper refresh may update only wrapped key material and timestamps", async () => {
    await assertSucceeds(
      updateDoc(doc(aliceDB, `users/${aliceUid}/cloud_vault_key_wrappers/${wrapperId}`), {
        wrappedVaultKey: "UmVmcmVzaGVkQ2lwaGVydGV4dA==",
        updatedAt: Timestamp.fromMillis(Date.now()),
      })
    );
  });

  await step("wrapper update rejects identity-bearing rewrites", async () => {
    await assertFails(
      updateDoc(doc(aliceDB, `users/${aliceUid}/cloud_vault_key_wrappers/${wrapperId}`), {
        targetDeviceId: "mac-1",
        updatedAt: Timestamp.fromMillis(Date.now()),
      })
    );
    await assertFails(
      updateDoc(doc(aliceDB, `users/${aliceUid}/cloud_vault_key_wrappers/${wrapperId}`), {
        publicKeyFingerprint: "fpr-attacker",
        updatedAt: Timestamp.fromMillis(Date.now()),
      })
    );
    await assertFails(
      updateDoc(doc(aliceDB, `users/${aliceUid}/cloud_vault_key_wrappers/${wrapperId}`), {
        status: "revoked",
        updatedAt: Timestamp.fromMillis(Date.now()),
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
