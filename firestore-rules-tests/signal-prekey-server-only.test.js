/**
 * Firestore rules tests for C.2 / FINDING-011.
 *
 * Signal identity public keys remain owner-published, but all prekey/session
 * directory child collections are server-only. Existing Admin SDK/callable
 * records remain owner-readable; direct client writes and claims fail.
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { doc, getDoc, setDoc, updateDoc, deleteDoc, Timestamp } from "firebase/firestore";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);
const aliceUid = "alice-uid";
const bobUid = "bob-uid";
const identityKeyId = "device-1_1";
const deviceId = "device-1";
const now = Timestamp.fromMillis(Date.now());
const future = Timestamp.fromMillis(Date.now() + 30 * 24 * 60 * 60 * 1000);

const baseChild = {
  identityKeyId,
  deviceId,
  keyVersion: 1,
  createdAt: now,
  updatedAt: now,
};

const signedPreKey = {
  ...baseChild,
  signedPreKeyId: "spk-1",
  signedPreKeyNumericId: 11,
  publicKeyB64: "A".repeat(44),
  signatureB64: "B".repeat(88),
  algorithm: "signal-pqxdh-signed-prekey-v1",
  status: "active",
  expiresAt: future,
};

const oneTimePreKey = {
  ...baseChild,
  oneTimePreKeyId: "opk-1",
  oneTimePreKeyNumericId: 101,
  publicKeyB64: "D".repeat(44),
  algorithm: "signal-pqxdh-one-time-prekey-v1",
  status: "available",
  expiresAt: future,
};

const kyberPreKey = {
  ...baseChild,
  kyberPreKeyId: "kpk-1",
  kyberPreKeyNumericId: 201,
  publicKeyB64: "E".repeat(1600),
  signatureB64: "G".repeat(88),
  algorithm: "signal-pqxdh-kyber-prekey-v1",
  status: "available",
  expiresAt: future,
};

const sessionDirectoryDoc = {
  ...baseChild,
  sessionId: "session-1",
  peerUid: aliceUid,
  peerDeviceId: "device-2",
  peerIdentityKeyId: "device-2_1",
  mode: "same-user-device",
  stateStorage: "device-local-only",
  status: "active",
  lastMessageAt: now,
};

const rotationEvent = {
  ...baseChild,
  rotationId: "rotation-1",
  fromKeyVersion: 1,
  toKeyVersion: 2,
  reason: "manual",
  status: "planned",
  rewrapRequired: true,
  rewrapJobId: "rewrap-1",
};

function identityDocument(overrides = {}) {
  return {
    deviceId,
    platform: "iOS",
    identityKeyId,
    publicKeyData: "S".repeat(44),
    publicKeyFingerprint: "H".repeat(44),
    keyVersion: 1,
    algorithm: "signal-hpke-identity-seal-v1",
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}

let testEnv;
let runs = 0;
let failures = 0;

function path(child) {
  return `users/${aliceUid}/signal_identity_public_keys/${identityKeyId}/${child}`;
}

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

async function seedServerDirectory() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `users/${aliceUid}/escrow_devices/${deviceId}`), {
      deviceId,
      deviceName: "iPhone",
      platform: "iOS",
      trustState: "trusted",
      publicKeyFingerprint: "F".repeat(44),
      keyVersion: 1,
      createdAt: now,
      updatedAt: now,
    });
    await setDoc(doc(db, `users/${aliceUid}/signal_identity_public_keys/${identityKeyId}`), identityDocument());
    await setDoc(doc(db, path("signed_prekeys/spk-1")), signedPreKey);
    await setDoc(doc(db, path("one_time_prekeys/opk-1")), oneTimePreKey);
    await setDoc(doc(db, path("kyber_prekeys/kpk-1")), kyberPreKey);
    await setDoc(doc(db, path("sessions/session-1")), sessionDirectoryDoc);
    await setDoc(doc(db, path("rotation_events/rotation-1")), rotationEvent);
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
  await seedServerDirectory();

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();
  const bobDB = testEnv.authenticatedContext(bobUid).firestore();

  await step("server-seeded Signal directory entries remain owner-readable", async () => {
    await assertSucceeds(getDoc(doc(aliceDB, path("signed_prekeys/spk-1"))));
    await assertSucceeds(getDoc(doc(aliceDB, path("one_time_prekeys/opk-1"))));
    await assertSucceeds(getDoc(doc(aliceDB, path("kyber_prekeys/kpk-1"))));
    await assertSucceeds(getDoc(doc(aliceDB, path("sessions/session-1"))));
    await assertSucceeds(getDoc(doc(aliceDB, path("rotation_events/rotation-1"))));
  });

  await step("cross-user Signal directory reads still fail", async () => {
    await assertFails(getDoc(doc(bobDB, path("signed_prekeys/spk-1"))));
  });

  await step("direct owner Signal identity create is path-bound to a known device version", async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await setDoc(doc(db, `users/${aliceUid}/escrow_devices/device-2`), {
        deviceId: "device-2",
        deviceName: "iPad",
        platform: "iPadOS",
        trustState: "pending",
        publicKeyFingerprint: "G".repeat(44),
        keyVersion: 2,
        createdAt: now,
        updatedAt: now,
      });
      await setDoc(doc(db, `users/${aliceUid}/escrow_devices/device-3`), {
        deviceId: "device-3",
        deviceName: "MacBook",
        platform: "macOS",
        trustState: "pending",
        publicKeyFingerprint: "R".repeat(44),
        keyVersion: 3,
        createdAt: now,
        updatedAt: now,
      });
    });

    await assertSucceeds(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/signal_identity_public_keys/device-2_2`),
        identityDocument({
          deviceId: "device-2",
          platform: "iPadOS",
          identityKeyId: "device-2_2",
          keyVersion: 2,
          keyVersionLabel: "2",
          publicKeyData: "T".repeat(44),
        })
      )
    );

    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/signal_identity_public_keys/device-2_3`),
        identityDocument({
          deviceId: "device-2",
          identityKeyId: "device-2_3",
          keyVersion: 3,
          keyVersionLabel: "3",
        })
      )
    );

    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/signal_identity_public_keys/device-2_2_wrong`),
        identityDocument({
          deviceId: "device-2",
          identityKeyId: "device-2_2",
          keyVersion: 2,
          keyVersionLabel: "2",
        })
      )
    );

    await assertFails(
      setDoc(
        doc(bobDB, `users/${aliceUid}/signal_identity_public_keys/device-3_3`),
        identityDocument({
          deviceId: "device-3",
          identityKeyId: "device-3_3",
          keyVersion: 3,
          keyVersionLabel: "3",
        })
      )
    );
  });

  await step("direct client Signal identity rewrites and deletes fail", async () => {
    await assertFails(updateDoc(doc(aliceDB, `users/${aliceUid}/signal_identity_public_keys/${identityKeyId}`), {
      publicKeyData: "Z".repeat(44),
      publicKeyFingerprint: "Q".repeat(44),
      updatedAt: now,
    }));
    await assertFails(deleteDoc(doc(aliceDB, `users/${aliceUid}/signal_identity_public_keys/${identityKeyId}`)));
  });

  await step("direct client prekey publishes fail", async () => {
    await assertFails(setDoc(doc(aliceDB, path("signed_prekeys/spk-client")), { ...signedPreKey, signedPreKeyId: "spk-client" }));
    await assertFails(setDoc(doc(aliceDB, path("one_time_prekeys/opk-client")), { ...oneTimePreKey, oneTimePreKeyId: "opk-client" }));
    await assertFails(setDoc(doc(aliceDB, path("kyber_prekeys/kpk-client")), { ...kyberPreKey, kyberPreKeyId: "kpk-client" }));
  });

  await step("direct client prekey claims and status changes fail", async () => {
    await assertFails(updateDoc(doc(aliceDB, path("signed_prekeys/spk-1")), { status: "retired", updatedAt: now }));
    await assertFails(updateDoc(doc(aliceDB, path("one_time_prekeys/opk-1")), {
      status: "claimed",
      claimedBySessionId: "session-2",
      claimedAt: now,
      updatedAt: now,
    }));
    await assertFails(updateDoc(doc(aliceDB, path("kyber_prekeys/kpk-1")), {
      status: "claimed",
      claimedBySessionId: "session-2",
      claimedAt: now,
      updatedAt: now,
    }));
  });

  await step("direct client session and rotation directory writes fail", async () => {
    await assertFails(setDoc(doc(aliceDB, path("sessions/session-client")), { ...sessionDirectoryDoc, sessionId: "session-client" }));
    await assertFails(updateDoc(doc(aliceDB, path("sessions/session-1")), { status: "archived", archivedAt: now, updatedAt: now }));
    await assertFails(setDoc(doc(aliceDB, path("rotation_events/rotation-client")), { ...rotationEvent, rotationId: "rotation-client" }));
  });

  await step("direct client Signal directory deletes fail", async () => {
    await assertFails(deleteDoc(doc(aliceDB, path("one_time_prekeys/opk-1"))));
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
