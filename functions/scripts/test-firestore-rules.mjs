/**
 * Firestore rules regression tests for OpenBurnBar Cloud's paid backup gate.
 *
 * These tests run against the Firestore emulator. They prove that owner-scoped
 * free sync still works, while hosted cloud backup payloads require a
 * server-written premium entitlement document. Legacy hosted quota and the
 * bundled BurnBar Pro entitlement both unlock the paid backup/search paths.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  Timestamp,
  updateDoc,
} from "firebase/firestore";

const [host = "127.0.0.1", rawPort = "8080"] = (
  process.env.FIRESTORE_EMULATOR_HOST ?? "127.0.0.1:8080"
).split(":");
const port = Number.parseInt(rawPort, 10);
const rules = readFileSync(new URL("../../firestore.rules", import.meta.url), "utf8");

const testEnv = await initializeTestEnvironment({
  projectId: `openburnbar-rules-${Date.now()}`,
  firestore: {
    host,
    port,
    rules,
  },
});

test.after(async () => {
  await testEnv.cleanup();
});

async function seedHostedCloudEntitlement(uid) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), `users/${uid}/entitlements/hosted_quota_sync`),
      {
        id: "hosted_quota_sync",
        active: true,
        productID: "com.openburnbar.hostedQuotaSync.cloud.monthly",
        expiresAt: "2099-01-01T00:00:00.000Z",
        expireAt: Timestamp.fromDate(new Date("2099-01-01T00:00:00.000Z")),
        schemaVersion: 2,
      }
    );
  });
}

async function seedBurnBarProEntitlement(uid) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/${uid}/entitlements/burnbar_pro`), {
      id: "burnbar_pro",
      active: true,
      productID: "com.openburnbar.pro.monthly",
      expiresAt: "2099-01-01T00:00:00.000Z",
      expireAt: Timestamp.fromDate(new Date("2099-01-01T00:00:00.000Z")),
      features: {
        hostedQuota: true,
        hostedLLM: true,
        encryptedSessionLogBackup: true,
        cloudConversationSearch: true,
      },
      schemaVersion: 2,
    });
  });
}

async function seedBurnBarProMaxEntitlement(
  uid,
  productID = "com.openburnbar.proMax.v2.monthly"
) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/${uid}/entitlements/burnbar_pro_max`), {
      id: "burnbar_pro_max",
      active: true,
      productID,
      expiresAt: "2099-01-01T00:00:00.000Z",
      expireAt: Timestamp.fromDate(new Date("2099-01-01T00:00:00.000Z")),
      schemaVersion: 2,
    });
  });
}

async function seedHostedComputerUseEntitlement(
  uid,
  entitlementId = "hosted_computer_use_sync",
  productID = "com.openburnbar.hostedComputerUseSync.monthly"
) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), `users/${uid}/entitlements/${entitlementId}`),
      {
        id: entitlementId,
        active: true,
        productID,
        expiresAt: "2099-01-01T00:00:00.000Z",
        expireAt: Timestamp.fromDate(new Date("2099-01-01T00:00:00.000Z")),
        schemaVersion: 1,
      }
    );
  });
}

const TEST_VAULT_KEY_ID = `v1_${"a".repeat(32)}`;

function sealedPayload(vaultKeyID = TEST_VAULT_KEY_ID, sealedBoxBase64 = "c2VhbGVk") {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    vaultKeyID,
    sealedBoxBase64,
    aad: "OpenBurnBar-CloudVaultSealedPayload-v2",
  };
}

// Canonical CloudVaultSealedText envelope (validCloudSealedText shape):
// algorithm/keyVersion/nonce/ciphertext/tag, base64-charset strings only.
function sealedText(overrides = {}) {
  return {
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    nonce: "bm9uY2U=",
    ciphertext: "Y2lwaGVydGV4dA==",
    tag: "dGFn",
    ...overrides,
  };
}

function cloudVaultAAD(uid, collection, docID, field) {
  return `OpenBurnBar-CloudVault-aad-v2|${uid}|${collection}|${docID}|${field}|2|${field}`;
}

function sealedTextAt(uid, collection, docID, field, overrides = {}) {
  return sealedText({
    schemaVersion: 2,
    aad: cloudVaultAAD(uid, collection, docID, field),
    ...overrides,
  });
}

// Canonical CloudVaultBlobEnvelope v2 (validCloudSealedBlob shape):
// schemaVersion/algorithm/keyVersion/plaintextHMAC/integrityHashVersion/sealedBoxBase64/createdAt/aad.
function sealedBlob(overrides = {}) {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    plaintextHMAC: "a".repeat(64),
    integrityHashVersion: 1,
    sealedBoxBase64: "c2VhbGVkLWJsb2I=",
    createdAt: "2026-06-02T00:00:00.000Z",
    aad: "OpenBurnBar-CloudVault-aad-v2|pms-owner|project_memory_snapshots|pm_aaaaaaaaaaaaaaaa|sealedSnapshot|2|sealedSnapshot",
    ...overrides,
  };
}

async function seedCloudVaultState(uid, vaultKeyID = TEST_VAULT_KEY_ID) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/${uid}/cloud_vault_state/current`), {
      uid,
      vaultKeyID,
      keyVersion: 1,
      algorithm: "AES-256-GCM",
      status: "active",
      createdByDeviceId: "test-device",
      createdAt: Timestamp.fromDate(new Date("2026-06-01T00:00:00.000Z")),
      updatedAt: Timestamp.fromDate(new Date("2026-06-01T00:00:00.000Z")),
      schemaVersion: 1,
    });
  });
}

function sealedChatThreadPatch(overrides = {}) {
  return {
    contentIncluded: true,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(),
    ...overrides,
  };
}

function sealedMissionBase(id, overrides = {}) {
  return {
    id,
    missionKind: "debt",
    requestedRuntime: "auto",
    depth: "standard",
    approvalMode: "existing_policy",
    commandsAllowed: false,
    fileEditsAllowed: false,
    source: "ios-insights",
    status: "pending",
    createdAt: "2026-05-13T00:00:00.000Z",
    updatedAt: serverTimestamp(),
    schemaVersion: 2,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(),
    ...overrides,
  };
}

function sealedMissionEvent(overrides = {}) {
  return {
    sequence: 1,
    timestamp: "2026-05-13T00:00:00.000Z",
    kind: "status",
    phase: "queued",
    source: "ios",
    isError: false,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(),
    ...overrides,
  };
}

function sealedMissionStatePatch(overrides = {}) {
  return {
    contentSealed: true,
    sealedStatePayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVkLXN0YXRl"),
    sealedStateSchemaVersion: 1,
    sealedStateVaultKeyID: TEST_VAULT_KEY_ID,
    ...overrides,
  };
}

// Canonical at-rest CloudVault Signal envelope (validSignalAtRestEnvelope shape),
// mirroring packages/signal-envelope-contracts at-rest wire shape. base64 fields are
// length %4 == 0 so the rules base64 guard passes. The `binding` is path-bound by the
// caller; per-coordinate overrides let a test relocate or pollute exactly one field.
function signalAtRestEnvelope({
  uid,
  collection,
  docId,
  field = "signalEnvelope",
  envelope = {},
  ciphertextLayer = {},
  keyDelivery = {},
  binding = {},
  senderAuth = {},
} = {}) {
  return {
    signalEnvelopeFormatVersion: 1,
    mode: "at-rest",
    relayEncryption: "signal-hpke-identity-seal-v1",
    ciphertextLayer: {
      payloadCiphertextB64: "c2VhbGVkLXBheWxvYWQ=",
      payloadAADLabel: "bindingToAAD-sha256:0123456789abcdef0123456789abcdef",
      schemaVersion: 1,
      ...ciphertextLayer,
    },
    keyDelivery: {
      scheme: "signal-hpke-identity-seal-v1",
      contentKeyLength: 32,
      wraps: [
        {
          recipientKind: "device",
          recipientIdentityKeyId: "device-key-1",
          recipientIdentityKeyB64: "cHVibGljLWtleQ==",
          sealedContentKeyB64: "c2VhbGVkLWtleQ==",
        },
      ],
      ...keyDelivery,
    },
    binding: {
      uid,
      scope: "cloudvault",
      collection,
      docId,
      field,
      mode: "at-rest",
      formatVersion: 1,
      ...binding,
    },
    senderAuth: senderAuth === null ? undefined : {
      senderIdentityKeyId: "device-key-1",
      senderIdentityKeyB64: "cHVibGljLWtleQ==",
      signatureB64: "c2lnbmF0dXJlLWZpeHR1cmU=",
      signatureVersion: 1,
      ...senderAuth,
    },
    ...envelope,
  };
}

function authedDb(uid) {
  return testEnv.authenticatedContext(uid, { email: `${uid}@example.test` }).firestore();
}

test("credential transfers are encrypted, owner-scoped, expiring one-time codes", async () => {
  const ownerDb = authedDb("credential-owner");
  const otherDb = authedDb("credential-attacker");
  const validCode = "ABCDEFGHJKM2";
  const validPath = `credential_transfers/${validCode}`;
  const now = Date.now();
  const baseTransfer = {
    ownerUid: "credential-owner",
    payload: "v1.c2FsdC1maXh0dXJl.aXYtZml4dHVyZQ.Y2lwaGVydGV4dC1maXh0dXJl",
    createdAt: Timestamp.fromMillis(now - 1_000),
    expiresAt: Timestamp.fromMillis(now + 23 * 60 * 60 * 1000),
    consumed: false,
  };

  await assertSucceeds(setDoc(doc(ownerDb, validPath), baseTransfer));
  await assertFails(getDoc(doc(ownerDb, validPath)));
  await assertFails(getDoc(doc(otherDb, validPath)));

  await assertFails(
    setDoc(doc(ownerDb, "credential_transfers/ABCDEFGHJKM3"), {
      ...baseTransfer,
      payload: JSON.stringify({ token: "plaintext-fixture" }),
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "credential_transfers/too-short"), {
      ...baseTransfer,
      ownerUid: "credential-owner",
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "credential_transfers/ABCDEFGHJKM4"), {
      ...baseTransfer,
      ownerUid: "credential-attacker",
    })
  );

  await assertFails(
    updateDoc(doc(ownerDb, validPath), {
      consumed: true,
      consumedAt: Timestamp.fromDate(new Date("2026-06-01T00:05:00.000Z")),
    })
  );
  await assertFails(getDoc(doc(ownerDb, validPath)));
  await assertFails(
    updateDoc(doc(ownerDb, validPath), {
      consumed: true,
      consumedAt: Timestamp.fromDate(new Date("2026-06-01T00:06:00.000Z")),
    })
  );

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "credential_transfers/ABCDEFGHJKM5"), {
      ...baseTransfer,
      expiresAt: Timestamp.fromDate(new Date("2000-01-01T00:00:00.000Z")),
    });
  });
  await assertFails(getDoc(doc(ownerDb, "credential_transfers/ABCDEFGHJKM5")));
  await assertFails(
    setDoc(doc(ownerDb, "credential_transfers/ABCDEFGHJKM6"), {
      ...baseTransfer,
      expiresAt: Timestamp.fromMillis(now + 25 * 60 * 60 * 1000),
    })
  );
});

test("provider accounts reject plaintext or unknown credential containers", async () => {
  const ownerDb = authedDb("provider-owner");
  const basePath = "users/provider-owner/provider_accounts/account-1";
  const canonical = {
    id: "account-1",
    providerID: "codex",
    label: "Codex",
    status: "connected",
    credentialKind: "token",
    storageScope: "server_private",
    redactedLabel: "sk_...1234",
    isDefault: true,
    sortKey: 0,
    schemaVersion: 2,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  await assertSucceeds(setDoc(doc(ownerDb, basePath), canonical));
  await assertFails(
    setDoc(doc(ownerDb, "users/provider-owner/provider_accounts/account-2"), {
      ...canonical,
      id: "account-2",
      credentials: { apiKey: "plaintext" },
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/provider-owner/provider_accounts/account-3"), {
      ...canonical,
      id: "account-3",
      secretVersionName: "projects/x/secrets/y/versions/1",
    })
  );
});

test("escrow public keys and envelopes are schema-constrained encrypted docs", async () => {
  const ownerDb = authedDb("escrow-owner");
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/escrow_public_keys/device-1_1"), {
      deviceId: "device-1",
      publicKeyData: "A".repeat(88),
      publicKeyFingerprint: "F".repeat(44),
      keyVersion: 1,
      algorithm: "ECIES-P256-AESGCM",
      createdAt: Timestamp.fromMillis(Date.now()),
    })
  );
  await assertSucceeds(
    setDoc(doc(ownerDb, "users/escrow-owner/escrow_devices/device-1"), {
      deviceId: "device-1",
      deviceName: "iPhone",
      platform: "iOS",
      trustState: "pending",
      publicKeyFingerprint: "F".repeat(44),
      keyVersion: 1,
      createdAt: Timestamp.fromMillis(Date.now()),
      updatedAt: Timestamp.fromMillis(Date.now()),
    })
  );
  const publicKey = {
    deviceId: "device-1",
    publicKeyData: "A".repeat(88),
    publicKeyFingerprint: "F".repeat(44),
    keyVersion: 1,
    algorithm: "ECIES-P256-AESGCM",
    createdAt: Timestamp.fromMillis(Date.now()),
  };
  await assertSucceeds(setDoc(doc(ownerDb, "users/escrow-owner/escrow_public_keys/device-1_1"), publicKey));
  await assertFails(updateDoc(doc(ownerDb, "users/escrow-owner/escrow_public_keys/device-1_1"), { publicKeyData: "B".repeat(88) }));
  await assertFails(setDoc(doc(ownerDb, "users/escrow-owner/escrow_public_keys/device-1_duplicate"), publicKey));
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/escrow_public_keys/device-1_1_alt"), {
      ...publicKey,
      publicKeyFingerprint: "G".repeat(44),
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/escrow_public_keys/device-2_1"), {
      ...publicKey,
      deviceId: "device-2",
      publicKeyJwk: { kty: "EC", crv: "P-256", x: "A", y: "B", d: "PRIVATE" },
    })
  );
  const signalIdentityPublicKey = {
    deviceId: "device-1",
    platform: "iOS",
    identityKeyId: "device-1_1",
    publicKeyData: "S".repeat(44),
    publicKeyFingerprint: "H".repeat(44),
    keyVersion: 1,
    algorithm: "signal-hpke-identity-seal-v1",
    createdAt: Timestamp.fromMillis(Date.now()),
  };
  await assertSucceeds(
    setDoc(
      doc(ownerDb, "users/escrow-owner/signal_identity_public_keys/device-1_1"),
      signalIdentityPublicKey
    )
  );
  await assertFails(
    updateDoc(doc(ownerDb, "users/escrow-owner/signal_identity_public_keys/device-1_1"), {
      publicKeyData: "T".repeat(44),
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/signal_identity_public_keys/device-1_wrong"), signalIdentityPublicKey)
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/signal_identity_public_keys/device-1_2"), {
      ...signalIdentityPublicKey,
      identityKeyId: "device-1_2",
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/signal_identity_public_keys/device-1_2"), {
      ...signalIdentityPublicKey,
      identityKeyId: "device-1_2",
      keyVersion: 2,
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/signal_identity_public_keys/device-2_1"), {
      ...signalIdentityPublicKey,
      deviceId: "device-2",
      identityKeyId: "device-2_1",
      privateKeyData: "PRIVATE",
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/signal_identity_public_keys/device-3_1"), {
      ...signalIdentityPublicKey,
      deviceId: "device-3",
      identityKeyId: "device-3_1",
      algorithm: "ECIES-P256-AESGCM",
    })
  );

  const envelope = {
    id: "envelope-1",
    grantId: "grant-1",
    sourceDeviceId: "device-1",
    targetDeviceId: "device-2",
    providerId: "codex",
    credentialKind: "api_key",
    ciphertext: "Q".repeat(64),
    keyVersion: 1,
    envelopeVersion: 1,
    createdAt: Timestamp.fromMillis(Date.now()),
  };
  await assertSucceeds(setDoc(doc(ownerDb, "users/escrow-owner/escrow_envelopes/envelope-1"), envelope));
  const { targetDeviceId: _targetDeviceId, ...missingTargetEnvelope } = envelope;
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/escrow_envelopes/envelope-2"), {
      ...missingTargetEnvelope,
      id: "envelope-2",
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/escrow_envelopes/envelope-3"), {
      ...envelope,
      id: "envelope-3",
      credentials: { apiKey: "plaintext" },
    })
  );
});

test("L41 Signal prekey/session directory is path-bound, public-only, and rotation-aware", async () => {
  const ownerDb = authedDb("signal-dir-owner");
  const now = Timestamp.fromDate(new Date("2026-06-05T12:00:00.000Z"));
  const soon = Timestamp.fromDate(new Date("2030-01-01T00:00:00.000Z"));

  await assertSucceeds(
    setDoc(doc(ownerDb, "users/signal-dir-owner/escrow_devices/device-1"), {
      deviceId: "device-1",
      deviceName: "iPhone",
      platform: "iOS",
      trustState: "pending",
      publicKeyFingerprint: "F".repeat(44),
      keyVersion: 1,
      createdAt: now,
      updatedAt: now,
    })
  );
  await assertSucceeds(
    setDoc(doc(ownerDb, "users/signal-dir-owner/signal_identity_public_keys/device-1_1"), {
      deviceId: "device-1",
      platform: "iOS",
      identityKeyId: "device-1_1",
      publicKeyData: "S".repeat(44),
      publicKeyFingerprint: "H".repeat(44),
      keyVersion: 1,
      algorithm: "signal-hpke-identity-seal-v1",
      createdAt: now,
    })
  );

  // Rotation support: Firestore rules cannot stringify ints, so v2+ identity
  // docs must carry keyVersionLabel and the label must map back to keyVersion.
  await assertSucceeds(
    setDoc(doc(ownerDb, "users/signal-dir-owner/escrow_devices/device-r"), {
      deviceId: "device-r",
      deviceName: "Rotating Mac",
      platform: "macOS",
      trustState: "pending",
      publicKeyFingerprint: "R".repeat(44),
      keyVersion: 2,
      createdAt: now,
      updatedAt: now,
    })
  );
  await assertSucceeds(
    setDoc(doc(ownerDb, "users/signal-dir-owner/signal_identity_public_keys/device-r_2"), {
      deviceId: "device-r",
      platform: "macOS",
      identityKeyId: "device-r_2",
      keyVersionLabel: "2",
      publicKeyData: "V".repeat(44),
      publicKeyFingerprint: "W".repeat(44),
      keyVersion: 2,
      algorithm: "signal-hpke-identity-seal-v1",
      createdAt: now,
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/signal-dir-owner/signal_identity_public_keys/device-r_3"), {
      deviceId: "device-r",
      platform: "macOS",
      identityKeyId: "device-r_3",
      keyVersionLabel: "3",
      publicKeyData: "X".repeat(44),
      publicKeyFingerprint: "Y".repeat(44),
      keyVersion: 2,
      algorithm: "signal-hpke-identity-seal-v1",
      createdAt: now,
    })
  );

  const baseChild = {
    identityKeyId: "device-1_1",
    deviceId: "device-1",
    keyVersion: 1,
    createdAt: now,
  };

  const signedPreKeyPath =
    "users/signal-dir-owner/signal_identity_public_keys/device-1_1/signed_prekeys/spk-1";
  const signedPreKey = {
    ...baseChild,
    signedPreKeyId: "spk-1",
    signedPreKeyNumericId: 11,
    publicKeyB64: "A".repeat(44),
    signatureB64: "B".repeat(88),
    algorithm: "signal-pqxdh-signed-prekey-v1",
    status: "active",
    expiresAt: soon,
  };
  await assertSucceeds(setDoc(doc(ownerDb, signedPreKeyPath), signedPreKey));
  await assertSucceeds(
    updateDoc(doc(ownerDb, signedPreKeyPath), {
      status: "retired",
      updatedAt: now,
    })
  );
  await assertFails(
    updateDoc(doc(ownerDb, signedPreKeyPath), {
      publicKeyB64: "C".repeat(44),
    })
  );
  await assertFails(deleteDoc(doc(ownerDb, signedPreKeyPath)));

  const oneTimePreKeyPath =
    "users/signal-dir-owner/signal_identity_public_keys/device-1_1/one_time_prekeys/opk-1";
  const oneTimePreKey = {
    ...baseChild,
    oneTimePreKeyId: "opk-1",
    oneTimePreKeyNumericId: 101,
    publicKeyB64: "D".repeat(44),
    algorithm: "signal-pqxdh-one-time-prekey-v1",
    status: "available",
    expiresAt: soon,
  };
  await assertSucceeds(setDoc(doc(ownerDb, oneTimePreKeyPath), oneTimePreKey));
  await assertSucceeds(
    updateDoc(doc(ownerDb, oneTimePreKeyPath), {
      status: "claimed",
      claimedBySessionId: "session-1",
      claimedAt: now,
      updatedAt: now,
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/signal-dir-owner/signal_identity_public_keys/device-1_1/one_time_prekeys/opk-private"), {
      ...oneTimePreKey,
      oneTimePreKeyId: "opk-private",
      privateKeyData: "PRIVATE",
    })
  );

  const kyberPreKeyPath =
    "users/signal-dir-owner/signal_identity_public_keys/device-1_1/kyber_prekeys/kpk-1";
  const kyberPreKey = {
    ...baseChild,
    kyberPreKeyId: "kpk-1",
    kyberPreKeyNumericId: 201,
    publicKeyB64: "E".repeat(1600),
    signatureB64: "G".repeat(88),
    algorithm: "signal-pqxdh-kyber-prekey-v1",
    status: "available",
    expiresAt: soon,
  };
  await assertSucceeds(setDoc(doc(ownerDb, kyberPreKeyPath), kyberPreKey));
  await assertFails(
    setDoc(doc(ownerDb, "users/signal-dir-owner/signal_identity_public_keys/device-1_1/kyber_prekeys/kpk-nosig"), {
      ...kyberPreKey,
      kyberPreKeyId: "kpk-nosig",
      signatureB64: "",
    })
  );
  await assertSucceeds(
    updateDoc(doc(ownerDb, kyberPreKeyPath), {
      status: "exhausted",
      claimedBySessionId: "session-1",
      claimedAt: now,
      updatedAt: now,
    })
  );

  const sessionPath =
    "users/signal-dir-owner/signal_identity_public_keys/device-1_1/sessions/session-1";
  const sessionDirectoryDoc = {
    ...baseChild,
    sessionId: "session-1",
    peerUid: "signal-dir-owner",
    peerDeviceId: "device-r",
    peerIdentityKeyId: "device-r_2",
    mode: "same-user-device",
    stateStorage: "device-local-only",
    status: "active",
    lastMessageAt: now,
  };
  await assertSucceeds(setDoc(doc(ownerDb, sessionPath), sessionDirectoryDoc));
  await assertFails(
    setDoc(doc(ownerDb, "users/signal-dir-owner/signal_identity_public_keys/device-1_1/sessions/session-private"), {
      ...sessionDirectoryDoc,
      sessionId: "session-private",
      sessionStateB64: "SERIALIZED_SIGNAL_SESSION_MUST_STAY_ON_DEVICE",
    })
  );
  await assertSucceeds(
    updateDoc(doc(ownerDb, sessionPath), {
      status: "archived",
      archivedAt: now,
      updatedAt: now,
    })
  );
  await assertFails(
    updateDoc(doc(ownerDb, sessionPath), {
      peerIdentityKeyId: "attacker-key",
    })
  );

  const rotationPath =
    "users/signal-dir-owner/signal_identity_public_keys/device-1_1/rotation_events/rotation-1";
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
  await assertSucceeds(setDoc(doc(ownerDb, rotationPath), rotationEvent));
  await assertFails(updateDoc(doc(ownerDb, rotationPath), { status: "running", updatedAt: now }));
  await assertFails(deleteDoc(doc(ownerDb, rotationPath)));
  await assertFails(
    setDoc(doc(ownerDb, "users/signal-dir-owner/signal_identity_public_keys/device-1_1/rotation_events/bad-rotation"), {
      ...rotationEvent,
      rotationId: "bad-rotation",
      fromKeyVersion: 2,
      toKeyVersion: 1,
    })
  );
});

test("iroh pairing trust roots are server-owned while audit events remain metadata-only", async () => {
  const ownerDb = authedDb("iroh-owner");
  const otherDb = authedDb("mallory");
  const publicKeyPath = "users/iroh-owner/iroh_pairing_keys/host";
  const pairingPath = "users/iroh-owner/iroh_pairing/relay-1";
  const auditPath = "users/iroh-owner/iroh_audit_events/event-1";

  await assertFails(
    setDoc(doc(ownerDb, publicKeyPath), {
      id: "host",
      publicKeyBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      publishedAtMillis: 1778860800000,
      protocolVersion: 1,
      schemaVersion: 2,
    })
  );
  await assertSucceeds(getDoc(doc(ownerDb, publicKeyPath)));
  await assertFails(getDoc(doc(otherDb, publicKeyPath)));

  await assertFails(
    setDoc(doc(ownerDb, pairingPath), {
      id: "relay-1",
      nodeId: "z".repeat(52),
      publishedAtMillis: 1778860800000,
      protocolVersion: 1,
      signature: "A".repeat(88),
      createdAt: "2026-05-15T00:00:00.000Z",
      updatedAt: "2026-05-15T00:00:00.000Z",
      schemaVersion: 2,
    })
  );
  await assertFails(
    setDoc(doc(otherDb, "users/iroh-owner/iroh_pairing/relay-2"), {
      id: "relay-2",
      nodeId: "z".repeat(52),
      publishedAtMillis: 1778860800000,
      protocolVersion: 1,
      signature: "A".repeat(88),
      schemaVersion: 1,
    })
  );

  await assertSucceeds(
    setDoc(doc(ownerDb, auditPath), {
      id: "event-1",
      connectionId: "relay-1",
      eventType: "iroh_pairing_published",
      transport: "iroh-relay",
      observedAt: "2026-05-15T00:00:00.000Z",
      detail: { relayUrl: "https://use1-1.relay.alberto8793.burnbar.iroh.link/" },
      schemaVersion: 1,
    })
  );
  await assertFails(
    setDoc(
      doc(ownerDb, auditPath),
      {
        eventType: "iroh_stream_closed",
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/iroh-owner/iroh_audit_events/event-secret"), {
      id: "event-secret",
      eventType: "iroh_stream_failed",
      secret: "must-not-pass",
      schemaVersion: 1,
    })
  );
});

test("mobile agent grant trust roots and queue creates are server-owned while receipts remain metadata-only", async () => {
  const db = authedDb("grant-user");
  const otherDb = authedDb("mallory");
  const authorityPath = "users/grant-user/agent_grant_authorities/phone-1";
  const requestPath = "users/grant-user/agent_capability_grant_requests/grant-1";
  const authorityDoc = {
    sourceDeviceId: "phone-1",
    peerNodeId: "ios-phone-" + "a".repeat(24),
    publicKeyBase64: "A".repeat(44),
    updatedAt: serverTimestamp(),
  };

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "users/grant-user/escrow_devices/phone-1"), {
      deviceId: "phone-1",
      platform: "iOS",
      deviceName: "Grant Phone",
      trustState: "trusted",
      updatedAt: serverTimestamp(),
    });
  });

  await assertFails(setDoc(doc(db, authorityPath), authorityDoc));
  await seedHostedComputerUseEntitlement("grant-user");
  await assertFails(setDoc(doc(db, authorityPath), authorityDoc));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), authorityPath), {
      ...authorityDoc,
      publishedAtMillis: Date.now(),
      schemaVersion: 2,
    });
  });
  await assertFails(getDoc(doc(otherDb, authorityPath)));
  await assertFails(
    setDoc(doc(db, "users/grant-user/agent_grant_authorities/phone-2"), {
      ...authorityDoc,
      sourceDeviceId: "phone-2",
    })
  );
  await assertFails(
    setDoc(doc(db, authorityPath), {
      ...authorityDoc,
      prompt: "do desktop work",
    })
  );

  const baseRequest = {
    requestId: "grant-1",
    runtime: "hermes",
    threadId: "thread-1",
    preset: "desktop",
    capabilities: ["desktop_browser", "desktop_screenshot", "workspace_read", "desktop_file_export"],
    trustMode: "manual",
    deliveryMode: "live_then_queued",
    requestedAt: 804934232,
    expiresAt: 804936032,
    grantDurationSeconds: 1800,
    sourceDeviceId: "phone-1",
    clientIntentId: "intent-1",
    localAuthenticationSatisfied: true,
    authority: {
      peerNodeId: authorityDoc.peerNodeId,
      counter: 1,
      timestamp: 804934232,
      intentHashBlake3: "a".repeat(64),
      signatureEd25519: "B".repeat(88),
    },
    status: "queued",
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  };

  await assertFails(setDoc(doc(db, requestPath), baseRequest));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), requestPath), baseRequest);
  });
  await assertFails(getDoc(doc(otherDb, requestPath)));
  await assertFails(
    setDoc(doc(db, "users/grant-user/agent_capability_grant_requests/grant-with-prompt"), {
      ...baseRequest,
      requestId: "grant-with-prompt",
      prompt: "create an svg on my desktop",
    })
  );
  await assertFails(
    setDoc(doc(db, "users/grant-user/agent_capability_grant_requests/grant-bad-capability"), {
      ...baseRequest,
      requestId: "grant-bad-capability",
      capabilities: ["desktop_browser", "messages"],
    })
  );
  await assertSucceeds(
    setDoc(
      doc(db, requestPath),
      {
        status: "applied",
        receipt: {
          receiptId: "receipt-1",
          requestId: "grant-1",
          runtime: "hermes",
          threadId: "thread-1",
          status: "applied",
          appliedGrantId: "agent-grant-1",
          capabilities: ["desktop_browser", "desktop_screenshot", "workspace_read", "desktop_file_export"],
          trustMode: "manual",
          receivedAt: 804934233,
          grantExpiresAt: 804936033,
          sourceDeviceId: "phone-1",
          message: "Grant applied.",
        },
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(db, requestPath),
      {
        threadId: "other-thread",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
});

test("current and legacy computer use subscription product ids do not bypass server-owned authority writes", async () => {
  const cases = [
    ["computer-use-current", "hosted_computer_use_sync", "com.openburnbar.computerUse.monthly"],
    ["computer-use-legacy", "hosted_computer_use_sync", "com.openburnbar.hostedComputerUseSync.monthly"],
    ["pro-max-monthly", "burnbar_pro_max", "com.openburnbar.proMax.v2.monthly"],
    ["pro-max-annual", "burnbar_pro_max", "com.openburnbar.proMax.annual"],
    ["pro-max-legacy", "burnbar_pro_max", "com.openburnbar.proMax.bundle.monthly"],
  ];

  for (const [uid, entitlementId, productID] of cases) {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), `users/${uid}/escrow_devices/phone-1`), {
        deviceId: "phone-1",
        platform: "iOS",
        deviceName: "Grant Phone",
        trustState: "trusted",
        updatedAt: serverTimestamp(),
      });
    });
    await seedHostedComputerUseEntitlement(uid, entitlementId, productID);

    await assertFails(
      setDoc(doc(authedDb(uid), `users/${uid}/agent_grant_authorities/phone-1`), {
        sourceDeviceId: "phone-1",
        peerNodeId: `${uid}-peer-${"a".repeat(24)}`,
        publicKeyBase64: "A".repeat(44),
        updatedAt: serverTimestamp(),
      })
    );
  }
});

test("BurnBar Cloud does not unlock media metadata but Cloud Pro does", async () => {
  const cloudDb = authedDb("cloud-only-media");
  await seedBurnBarProEntitlement("cloud-only-media");
  await assertFails(
    setDoc(doc(cloudDb, "users/cloud-only-media/media_attachment_manifests/manifest-1"), {
      id: "manifest-1",
      blobHash: "b".repeat(64),
      sealedFilename: sealedText(),
      mime: "image/png",
      size: 1234,
      peerDeviceIdHash: "peer-hash",
      direction: "macToIos",
      schemaVersion: 1,
    })
  );

  const proDb = authedDb("cloud-pro-media");
  await seedBurnBarProMaxEntitlement("cloud-pro-media");
  await assertSucceeds(
    setDoc(doc(proDb, "users/cloud-pro-media/media_attachment_manifests/manifest-1"), {
      id: "manifest-1",
      blobHash: "b".repeat(64),
      sealedFilename: sealedText(),
      mime: "image/png",
      size: 1234,
      peerDeviceIdHash: "peer-hash",
      direction: "macToIos",
      schemaVersion: 1,
    })
  );
});

test("no subscription tier bypasses server-owned computer-use authority writes", async () => {
  const cloudUid = "cloud-only-control";
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/${cloudUid}/escrow_devices/phone-1`), {
      deviceId: "phone-1",
      platform: "iOS",
      deviceName: "Grant Phone",
      trustState: "trusted",
      updatedAt: serverTimestamp(),
    });
  });
  await seedBurnBarProEntitlement(cloudUid);
  await assertFails(
    setDoc(doc(authedDb(cloudUid), `users/${cloudUid}/agent_grant_authorities/phone-1`), {
      sourceDeviceId: "phone-1",
      peerNodeId: `${cloudUid}-peer-${"a".repeat(24)}`,
      publicKeyBase64: "A".repeat(44),
      updatedAt: serverTimestamp(),
    })
  );

  const proUid = "cloud-pro-control";
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/${proUid}/escrow_devices/phone-1`), {
      deviceId: "phone-1",
      platform: "iOS",
      deviceName: "Grant Phone",
      trustState: "trusted",
      updatedAt: serverTimestamp(),
    });
  });
  await seedBurnBarProMaxEntitlement(proUid, "com.openburnbar.proMax.annual");
  await assertFails(
    setDoc(doc(authedDb(proUid), `users/${proUid}/agent_grant_authorities/phone-1`), {
      sourceDeviceId: "phone-1",
      peerNodeId: `${proUid}-peer-${"a".repeat(24)}`,
      publicKeyBase64: "A".repeat(44),
      updatedAt: serverTimestamp(),
    })
  );
});

test("owner can write free usage rows without hosted cloud entitlement", async () => {
  const db = authedDb("alice");
  await assertSucceeds(
    setDoc(doc(db, "users/alice/usage/u1"), {
      provider: "codex",
      model: "gpt-5",
      totalCost: 1.25,
      updatedAt: serverTimestamp(),
    })
  );
});

test("clients cannot self-mint hosted cloud entitlement docs", async () => {
  const db = authedDb("alice");
  await assertFails(
    setDoc(doc(db, "users/alice/entitlements/hosted_quota_sync"), {
      id: "hosted_quota_sync",
      active: true,
    })
  );
});

test("chat metadata stays free, but chat content backup requires entitlement", async () => {
  const freeDb = authedDb("alice");
  const threadPath = "users/alice/chat_threads/device_thread";

  await assertSucceeds(
    setDoc(doc(freeDb, threadPath), {
      threadId: "thread",
      deviceId: "device",
      messageCount: 2,
      contentIncluded: false,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    })
  );

  await assertFails(
    setDoc(
      doc(freeDb, threadPath),
      {
        threadId: "thread",
        deviceId: "device",
        messageCount: 2,
        contentIncluded: true,
        title: "private plan",
        preview: "private preview",
        messages: [{ id: "m1", role: "user", content: "secret prompt" }],
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );

  await seedHostedCloudEntitlement("alice");
  await seedCloudVaultState("alice");

  await assertSucceeds(
    setDoc(
      doc(freeDb, threadPath),
      sealedChatThreadPatch({
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );

  await assertFails(
    setDoc(
      doc(freeDb, threadPath),
      {
        ...sealedChatThreadPatch(),
        title: "private plan",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
});

test("owners can sync encrypted text expansion snippets without plaintext fields", async () => {
  const db = authedDb("alice");
  const snippetPath = "users/alice/text_snippets/snippet-1";
  const snippetSealed = (snippetID, field) => sealedTextAt("alice", "text_snippets", snippetID, field);

  await assertSucceeds(
    setDoc(doc(db, snippetPath), {
      id: "snippet-1",
      uid: "alice",
      sourceDeviceID: "mac-1",
      triggerHash: "a".repeat(32),
      sealedTitle: snippetSealed("snippet-1", "sealedTitle"),
      sealedTrigger: snippetSealed("snippet-1", "sealedTrigger"),
      sealedBody: snippetSealed("snippet-1", "sealedBody"),
      sealedScope: snippetSealed("snippet-1", "sealedScope"),
      mode: "llm_rewrite",
      isEnabled: true,
      revision: 1,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      deletedAt: null,
      schemaVersion: 2,
      encryption: {
        algorithm: "AES-256-GCM",
        keyVersion: 1,
        tokenHashVersion: 1,
      },
    })
  );

  await assertFails(
    setDoc(doc(db, "users/alice/text_snippets/replay"), {
      id: "replay",
      uid: "alice",
      sourceDeviceID: "mac-1",
      triggerHash: "c".repeat(32),
      sealedTitle: snippetSealed("snippet-1", "sealedTitle"),
      sealedTrigger: snippetSealed("replay", "sealedTrigger"),
      sealedBody: snippetSealed("replay", "sealedBody"),
      sealedScope: snippetSealed("replay", "sealedScope"),
      mode: "static",
      isEnabled: true,
      revision: 1,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 2,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/alice/text_snippets/plaintext"), {
      id: "plaintext",
      uid: "alice",
      sourceDeviceID: "mac-1",
      triggerHash: "b".repeat(32),
      sealedTitle: snippetSealed("plaintext", "sealedTitle"),
      sealedTrigger: snippetSealed("plaintext", "sealedTrigger"),
      sealedBody: snippetSealed("plaintext", "sealedBody"),
      sealedScope: snippetSealed("plaintext", "sealedScope"),
      body: "plaintext snippet",
      mode: "static",
      isEnabled: true,
      revision: 1,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 2,
    })
  );
});

test("non-paying users can remove previously backed-up chat content", async () => {
  const db = authedDb("bob");
  const threadPath = "users/bob/chat_threads/device_thread";

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), threadPath), {
      threadId: "thread",
      deviceId: "device",
      messageCount: 1,
      contentIncluded: true,
      title: "private",
      preview: "private",
      messages: [{ id: "m1", role: "user", content: "private" }],
    });
  });

  await assertSucceeds(
    setDoc(
      doc(db, threadPath),
      {
        contentIncluded: false,
        title: deleteField(),
        preview: deleteField(),
        messages: deleteField(),
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
});

test("owners can dispatch mobile Insights missions and read Mac agent results", async () => {
  const phoneDb = authedDb("ivy");
  const otherDb = authedDb("mallory");
  const requestPath = "users/ivy/cli_agent_mission_requests/mission-1";
  await seedCloudVaultState("ivy");

  await assertSucceeds(
    setDoc(doc(phoneDb, requestPath), sealedMissionBase("mission-1"))
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${requestPath}/events/000001`), sealedMissionEvent())
  );
  const androidRequestPath = "users/ivy/cli_agent_mission_requests/mission-android";
  await assertSucceeds(
    setDoc(doc(phoneDb, androidRequestPath), sealedMissionBase("mission-android", {
      missionKind: "custom",
      requestedRuntime: "opencode",
      depth: "light",
      approvalMode: "read_only",
      source: "android-insights",
    }))
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${androidRequestPath}/events/000001`), sealedMissionEvent({
      source: "android",
    }))
  );
  const chatRequestPath = "users/ivy/cli_agent_mission_requests/chat-ios";
  await assertSucceeds(
    setDoc(doc(phoneDb, chatRequestPath), sealedMissionBase("chat-ios", {
      missionKind: "chat",
      requestedRuntime: "codex",
      requestedModelID: "gpt-5.5",
      source: "ios-chat",
      clientThreadID: "mobile-thread-1",
      resumeAction: "new",
    }))
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${chatRequestPath}/events/000001`), sealedMissionEvent({
      source: "ios-chat",
    }))
  );
  await assertFails(
    setDoc(doc(phoneDb, `${androidRequestPath}/events/000002`), {
      sequence: 2,
      timestamp: "2026-05-13T00:00:01.000Z",
      kind: "status",
      phase: "queued",
      title: "Queued again",
      message: "Mobile should not be able to append extra queued events after the initial dispatch marker.",
      source: "android",
      isError: false,
    })
  );
  await assertFails(
    setDoc(doc(phoneDb, `${androidRequestPath}/events/000099`), {
      sequence: 1,
      timestamp: "2026-05-13T00:00:01.000Z",
      kind: "status",
      phase: "queued",
      title: "Wrong event id",
      message: "The initial mobile event must be pinned to 000001.",
      source: "android",
      isError: false,
    })
  );
  await assertFails(
    setDoc(doc(phoneDb, "users/ivy/cli_agent_mission_requests/mission-parent-events"), {
      id: "mission-parent-events",
      title: "Parent event spoof",
      prompt: "This should not be able to seed mutable parent events.",
      missionKind: "debt",
      requestedRuntime: "codex",
      source: "ios-insights",
      status: "pending",
      liveSummary: "Mission queued from this device.",
      events: [
        {
          sequence: 1,
          timestamp: "2026-05-13T00:00:00.000Z",
          kind: "final_answer",
          phase: "completed",
          title: "Spoofed",
          message: "Mobile should not seed parent timeline history.",
          source: "ios",
          isError: false,
        },
      ],
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: serverTimestamp(),
      schemaVersion: 2,
    })
  );
  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      {
        status: "completed",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        sessionId: "thread-forged",
        liveSummary: "Forged completion should not be accepted without a trusted Mac claim.",
        resultPreview: "forged",
        completedAt: "2026-05-13T00:00:02.000Z",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      {
        status: "failed",
        errorMessage: "Mobile should not forge a pre-claim host failure.",
        liveSummary: "Mobile should not forge a pre-claim host failure.",
        completedAt: "2026-05-13T00:00:02.000Z",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      {
        status: "canceled",
        errorMessage: "Mobile should not cancel execution before the Mac has claimed the mission.",
        liveSummary: "Mobile should not cancel execution before the Mac has claimed the mission.",
        completedAt: "2026-05-13T00:00:02.000Z",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      {
        status: "unauthorized",
        errorMessage: "Mac is not trusted.",
        liveSummary: "Mac is not trusted.",
        completedAt: "2026-05-13T00:00:02.500Z",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(doc(phoneDb, `${requestPath}/events/000097`), {
      sequence: 97,
      timestamp: "2026-05-13T00:00:02.600Z",
      kind: "error",
      phase: "unauthorized",
      title: "Forged unauthorized event",
      message: "A mobile client must not be able to append mac-sourced events before a trusted Mac claim.",
      runtime: "codex",
      source: "mac",
      isError: true,
    })
  );
  await assertFails(
    setDoc(doc(phoneDb, "users/ivy/escrow_devices/forged-trusted-mac"), {
      deviceId: "forged-trusted-mac",
      platform: "macOS",
      deviceName: "Forged trusted Mac",
      trustState: "trusted",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    })
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, "users/ivy/escrow_devices/mac-1"), {
      deviceId: "mac-1",
      platform: "macOS",
      deviceName: "Ivy Mac",
      trustState: "pending",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    setDoc(
      doc(phoneDb, "users/ivy/escrow_devices/mac-1"),
      {
        trustState: "trusted",
        approvedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), "users/ivy/escrow_devices/mac-1"),
      {
        trustState: "trusted",
        approvedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    );
  });
  const importJobPath = "users/ivy/agent_import_jobs/import-1";
  await assertSucceeds(
    setDoc(doc(phoneDb, importJobPath), {
      id: "import-1",
      selectedHarnesses: ["codex", "claude", "openclaw"],
      status: "pending",
      source: "ios-import",
      progressMessage: "Waiting for a trusted Mac.",
      scannedCount: 0,
      importedCount: 0,
      mirroredSessionCount: 0,
      uploadedSessionLogCount: 0,
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );
  await assertFails(
    setDoc(
      doc(phoneDb, importJobPath),
      {
        status: "completed",
        importedCount: 3,
        completedAt: "2026-05-13T00:00:02.000Z",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(
      doc(phoneDb, importJobPath),
      {
        status: "scanning",
        claimedBy: "mac-1",
        progressMessage: "Scanning Codex, Claude Code, and OpenClaw history.",
        scannedCount: 2,
        startedAt: "2026-05-13T00:00:01.000Z",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(phoneDb, importJobPath),
      {
        status: "completed",
        claimedBy: "phone-1",
        importedCount: 99,
        completedAt: "2026-05-13T00:00:03.000Z",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  const lifecyclePath = "users/ivy/cli_agent_mission_requests/mission-lifecycle";
  await assertSucceeds(
    setDoc(doc(phoneDb, lifecyclePath), sealedMissionBase("mission-lifecycle", {
      missionKind: "custom",
      requestedRuntime: "codex",
      approvalMode: "read_only",
    }))
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000001`), sealedMissionEvent())
  );
  await assertSucceeds(
    setDoc(
      doc(phoneDb, lifecyclePath),
      sealedMissionStatePatch({
        status: "accepted",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        selectedModelID: "gpt-5.5",
        startedAt: "2026-05-13T00:00:01.000Z",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000002`), sealedMissionEvent({
      sequence: 2,
      timestamp: "2026-05-13T00:00:01.000Z",
      phase: "accepted",
      runtime: "codex",
      source: "mac",
    }))
  );
  await assertSucceeds(
    setDoc(
      doc(phoneDb, lifecyclePath),
      sealedMissionStatePatch({
        status: "starting",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000003`), sealedMissionEvent({
      sequence: 3,
      timestamp: "2026-05-13T00:00:02.000Z",
      phase: "starting",
      runtime: "codex",
      source: "mac",
    }))
  );
  await assertSucceeds(
    setDoc(
      doc(phoneDb, lifecyclePath),
      sealedMissionStatePatch({
        status: "running",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000004`), sealedMissionEvent({
      sequence: 4,
      timestamp: "2026-05-13T00:00:03.000Z",
      phase: "running",
      runtime: "codex",
      source: "mac",
    }))
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, "users/ivy/escrow_devices/mac-pending"), {
      deviceId: "mac-pending",
      platform: "macOS",
      deviceName: "Pending Mac",
      trustState: "pending",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    })
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, "users/ivy/escrow_devices/phone-1"), {
      deviceId: "phone-1",
      platform: "iOS",
      deviceName: "Ivy iPhone",
      trustState: "pending",
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    setDoc(
      doc(phoneDb, "users/ivy/escrow_devices/phone-1"),
      {
        trustState: "trusted",
        approvedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), "users/ivy/escrow_devices/phone-1"),
      {
        trustState: "trusted",
        approvedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    );
  });
  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      {
        status: "running",
        claimedBy: "mac-pending",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        liveSummary: "Pending Mac should not be able to claim.",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      {
        status: "running",
        claimedBy: "phone-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        liveSummary: "A trusted phone is not a Mac execution host.",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(doc(phoneDb, `${requestPath}/events/000098`), {
      sequence: 98,
      timestamp: "2026-05-13T00:00:03.000Z",
      kind: "tool_call",
      phase: "tool_use",
      title: "Shell",
      message: "A pending Mac cannot append execution events.",
      runtime: "codex",
      source: "mac",
      toolName: "exec_command",
      isError: false,
    })
  );
  await assertFails(
    setDoc(doc(phoneDb, "users/ivy/cli_agent_mission_requests/mission-forged-complete"), {
      id: "mission-forged-complete",
      title: "Forged completion",
      prompt: "This should not be creatable as an already-completed mission.",
      missionKind: "debt",
      requestedRuntime: "codex",
      source: "ios-insights",
      status: "completed",
      selectedRuntime: "codex",
      selectedRuntimeName: "Codex",
      resultPreview: "forged",
      createdAt: "2026-05-13T00:00:00.000Z",
      completedAt: "2026-05-13T00:00:01.000Z",
      updatedAt: serverTimestamp(),
      schemaVersion: 2,
    })
  );
  await assertFails(
    setDoc(doc(phoneDb, "users/ivy/cli_agent_mission_requests/mission-forged-approval"), {
      id: "mission-forged-approval",
      title: "Forged approval",
      prompt: "This should not be creatable as an already-approved mission.",
      missionKind: "debt",
      requestedRuntime: "codex",
      source: "ios-insights",
      status: "pending",
      approvalRequestId: "approval-1",
      approvalStatus: "approved",
      approvalRespondedAt: "2026-05-13T00:00:01.000Z",
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: serverTimestamp(),
      schemaVersion: 2,
    })
  );

  await assertFails(
    setDoc(doc(phoneDb, `${requestPath}/events/000002`), {
      sequence: 2,
      timestamp: "2026-05-13T00:00:03.000Z",
      kind: "tool_call",
      phase: "tool_use",
      title: "Read",
      message: "A mac-sourced event cannot be written before a trusted Mac claim.",
      runtime: "codex",
      source: "mac",
      toolName: "Read",
      isError: false,
    })
  );
  await assertSucceeds(
    setDoc(
      doc(phoneDb, requestPath),
      sealedMissionStatePatch({
        status: "waiting_for_approval",
        claimedBy: "mac-1",
        approvalRequestId: "approval-1",
        approvalStatus: "pending",
        approvalRequestedAt: "2026-05-13T00:00:03.500Z",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${requestPath}/events/000002`), sealedMissionEvent({
      sequence: 2,
      timestamp: "2026-05-13T00:00:03.000Z",
      kind: "tool_call",
      phase: "tool_use",
      messageLength: 96,
      messageTruncated: false,
      runtime: "codex",
      source: "mac",
    }))
  );
  await assertFails(
    setDoc(
      doc(phoneDb, `${requestPath}/events/000002`),
      {
        message: "Attempted rewrite of an already-written mission event.",
      },
      { merge: true }
    )
  );
  await assertFails(deleteDoc(doc(phoneDb, `${requestPath}/events/000002`)));
  await assertFails(deleteDoc(doc(phoneDb, requestPath)));
  // Blocker 2 — approval RESOLUTION is server-only. A direct client write cannot
  // approve a mission (with or without naming a trusted device); approve/reject
  // must flow through the App-Check + attestation enforced respondMissionApproval
  // callable (Admin SDK). Both the mobile and trusted-host rule branches refuse
  // to resolve approvalStatus to approved/rejected.
  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      sealedMissionStatePatch({
        approvalStatus: "approved",
        approvalRespondedAt: "2026-05-13T00:00:04.000Z",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      sealedMissionStatePatch({
        approvalStatus: "approved",
        approvalRespondedAt: "2026-05-13T00:00:04.000Z",
        approvedByDeviceId: "mac-1",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
  // The real resolution is performed server-side by the callable (Admin SDK,
  // which bypasses these rules), simulated here with security rules disabled —
  // it stamps a server-verified approvedByDeviceId.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), requestPath),
      sealedMissionStatePatch({
        approvalStatus: "approved",
        approvalRespondedAt: "2026-05-13T00:00:04.000Z",
        approvedByDeviceId: "mac-1",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    );
  });
  await assertFails(
    setDoc(doc(otherDb, `${requestPath}/events/000003`), {
      sequence: 3,
      timestamp: "2026-05-13T00:00:04.000Z",
      kind: "error",
      phase: "failed",
      title: "Injected",
      message: "Mallory should not be able to write Ivy mission events.",
      runtime: "opencode",
      source: "mac",
      isError: true,
    })
  );

  await assertSucceeds(
    setDoc(
      doc(phoneDb, requestPath),
      sealedMissionStatePatch({
        status: "completed",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        sessionId: "thread-1",
        completedAt: "2026-05-13T00:00:05.000Z",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${requestPath}/events/000003`), sealedMissionEvent({
      sequence: 3,
      timestamp: "2026-05-13T00:00:05.000Z",
      kind: "final_answer",
      phase: "completed",
      messageLength: 95,
      messageTruncated: false,
      runtime: "codex",
      source: "mac",
    }))
  );

  await assertFails(getDoc(doc(otherDb, requestPath)));
  await assertFails(
    setDoc(doc(phoneDb, "users/ivy/cli_agent_mission_requests/mission-2"), {
      id: "mission-2",
      title: "Bad Mission",
      prompt: "Run a mission with an unsupported runtime.",
      missionKind: "debt",
      requestedRuntime: "unknown",
      source: "ios-insights",
      status: "pending",
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );
});

test("owners can mirror CLI agent transcripts for mobile assistant tiles", async () => {
  const macDb = authedDb("jules");
  const otherDb = authedDb("mallory");
  const sessionPath = "users/jules/cli_sessions/thread-1";
  await seedCloudVaultState("jules");

  await assertSucceeds(
    setDoc(doc(macDb, sessionPath), {
      id: "thread-1",
      agent: "claude",
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: "2026-05-13T00:00:03.000Z",
      schemaVersion: 1,
      contentSealed: true,
      sealedSchemaVersion: 2,
      vaultKeyID: TEST_VAULT_KEY_ID,
      sealedPayload: sealedPayload(),
      messageCount: 1,
      lastMessageRole: "assistant",
      lastAssistantMessageID: "m1",
    })
  );

  await assertSucceeds(getDoc(doc(macDb, sessionPath)));
  await assertFails(getDoc(doc(otherDb, sessionPath)));
  await assertFails(
    setDoc(doc(macDb, "users/jules/cli_sessions/thread-2"), {
      id: "thread-2",
      agent: "unknown",
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: "2026-05-13T00:00:03.000Z",
      schemaVersion: 1,
      contentSealed: true,
      sealedSchemaVersion: 2,
      vaultKeyID: TEST_VAULT_KEY_ID,
      sealedPayload: sealedPayload(),
    })
  );
});

test("conversation and session-log backup require hosted cloud entitlement", async () => {
  const db = authedDb("carol");
  await seedCloudVaultState("carol");

  const sealedConversationDoc = {
    id: "conv",
    deviceId: "device",
    provider: "codex",
    sessionId: "session",
    messageCount: 1,
    userWordCount: 10,
    assistantWordCount: 20,
    updatedAt: serverTimestamp(),
    sourceType: "provider_log",
    version: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(),
  };

  await assertFails(
    setDoc(doc(db, "users/carol/conversations/device_conv"), sealedConversationDoc)
  );

  await assertFails(
    setDoc(doc(db, "users/carol/session_logs/device_log"), {
      id: "log",
      deviceId: "device",
      provider: "codex",
      sessionId: "session",
      chunkCount: 1,
      updatedAt: serverTimestamp(),
    })
  );

  await seedHostedCloudEntitlement("carol");

  await assertSucceeds(
    setDoc(doc(db, "users/carol/conversations/device_conv"), sealedConversationDoc)
  );

  await assertFails(
    setDoc(doc(db, "users/carol/conversations/device_plaintext"), {
      ...sealedConversationDoc,
      id: "device_plaintext",
      projectName: "BurnBar",
    })
  );

  await assertSucceeds(
    setDoc(doc(db, "users/carol/session_logs/device_log"), {
      id: "log",
      deviceId: "device",
      provider: "codex",
      sessionId: "session",
      chunkCount: 1,
      updatedAt: serverTimestamp(),
    })
  );

  await assertFails(
    setDoc(doc(db, "users/carol/session_logs/device_log/chunks/0"), {
      index: 0,
      hash: "hash",
      sealedSnippet: sealedText(),
      tokenHashes: ["a".repeat(32)],
      semanticHashes: ["b".repeat(32)],
      bodyStorage: "local_or_icloud",
      schemaVersion: 3,
      updatedAt: serverTimestamp(),
    })
  );

  await assertFails(
    setDoc(doc(db, "users/carol/session_logs/device_log/chunks/1"), {
      index: 1,
      body: "full private markdown",
      hash: "hash",
      schemaVersion: 3,
      updatedAt: serverTimestamp(),
    })
  );
});

test("session-log manifest accepts bounded cockpit facets but rejects malformed ones", async () => {
  const db = authedDb("facet-user");
  await seedHostedCloudEntitlement("facet-user");
  const facetBase = {
    id: "log",
    deviceId: "device",
    provider: "codex",
    sessionId: "session",
    chunkCount: 1,
    updatedAt: serverTimestamp(),
  };

  await assertSucceeds(
    setDoc(doc(db, "users/facet-user/session_logs/device_facets_ok"), {
      ...facetBase,
      facetSchemaVersion: 2,
      model: "gpt-5-codex",
      messageCount: 12,
      userWordCount: 340,
      assistantWordCount: 1820,
      inputTokens: 12000,
      outputTokens: 4200,
      cacheCreationTokens: 0,
      cacheReadTokens: 9000,
      totalTokens: 25200,
      costUSD: 0.42,
      toolTags: ["bash", "edit", "read"],
      durationSeconds: 540,
    })
  );

  // Negative cost is not a real facet value and must be rejected.
  await assertFails(
    setDoc(doc(db, "users/facet-user/session_logs/device_facets_negcost"), {
      ...facetBase,
      costUSD: -5,
    })
  );

  // Token counters must be integers, never smuggled strings (potential body leak vector).
  await assertFails(
    setDoc(doc(db, "users/facet-user/session_logs/device_facets_strtokens"), {
      ...facetBase,
      inputTokens: "full conversation transcript hidden here",
    })
  );

  // Tool tag lists are capped so they cannot become a content sidecar.
  await assertFails(
    setDoc(doc(db, "users/facet-user/session_logs/device_facets_bigtags"), {
      ...facetBase,
      toolTags: Array.from({ length: 64 }, (_, index) => `tag${index}`),
    })
  );

  // Project/path text is private and must never ride as a plaintext facet.
  await assertFails(
    setDoc(doc(db, "users/facet-user/session_logs/device_facets_bigproject"), {
      ...facetBase,
      projectName: "BurnBar",
    })
  );

  await assertFails(
    setDoc(doc(db, "users/facet-user/session_logs/device_facets_workingdir"), {
      ...facetBase,
      workingDirectory: "/Users/dev/Documents/Windsurf/BurnBar",
    })
  );

  await assertSucceeds(
    setDoc(doc(db, "users/facet-user/session_logs/device_facets_source"), {
      ...facetBase,
      sourceType: "cli_session",
    })
  );
});

test("owners can delete old paid-backup data after entitlement lapses", async () => {
  const db = authedDb("dana");
  const logPath = "users/dana/session_logs/device_log";

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), logPath), { id: "log" });
    await setDoc(doc(context.firestore(), `${logPath}/chunks/0`), { body: "private" });
  });

  await assertSucceeds(deleteDoc(doc(db, `${logPath}/chunks/0`)));
  await assertSucceeds(deleteDoc(doc(db, logPath)));
});

test("burnbar pro cloud search index writes are server-only while vault wrappers require trusted devices", async () => {
  const db = authedDb("pro-user");
  const documentPath = "users/pro-user/cloud_search_documents/device_session";
  const chunkPath = "users/pro-user/cloud_search_chunks/device_session_0";
  const indexStatePath = "users/pro-user/cloud_search_index_state/device";
  const wrapperPath = "users/pro-user/cloud_vault_key_wrappers/wrapper";
  const bodyHash = "a".repeat(64);
  const contentHash = "b".repeat(64);
  const storagePath = `users/pro-user/session_logs/device_session/bodies/${bodyHash}.json.aesgcm`;
  const sealedText = {
    algorithm: "AES-256-GCM",
    nonce: "base64nonce",
    ciphertext: "base64ciphertext",
    tag: "base64tag",
    keyVersion: 1,
  };

  await assertFails(
    setDoc(doc(db, documentPath), {
      uid: "pro-user",
      documentID: "device_session",
      deviceId: "device",
      sourceKind: "session_log",
      sourceID: "session",
      bodyHash,
      storagePath,
      sealedTitle: sealedText,
      sealedBodyPreview: sealedText,
      byteCount: 42,
      encryptedByteCount: 84,
      indexVersion: 1,
      tokenHashVersion: 1,
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await seedBurnBarProEntitlement("pro-user");
  await seedCloudVaultState("pro-user");

  await assertFails(
    setDoc(doc(db, documentPath), {
      uid: "pro-user",
      documentID: "device_session",
      deviceId: "device",
      sourceKind: "session_log",
      sourceID: "session",
      provider: "codex",
      projectName: "BurnBar",
      bodyHash,
      storagePath,
      sealedTitle: sealedText,
      sealedBodyPreview: sealedText,
      byteCount: 42,
      encryptedByteCount: 84,
      indexVersion: 1,
      tokenHashVersion: 1,
      commitID: "1".repeat(32),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, `${documentPath}_with_plaintext`), {
      uid: "pro-user",
      documentID: "device_session_with_plaintext",
      deviceId: "device",
      sourceKind: "session_log",
      sourceID: "session",
      bodyHash,
      storagePath: `users/pro-user/session_logs/device_session_with_plaintext/bodies/${bodyHash}.json.aesgcm`,
      sealedTitle: sealedText,
      sealedBodyPreview: sealedText,
      byteCount: 42,
      encryptedByteCount: 84,
      indexVersion: 1,
      tokenHashVersion: 1,
      title: "plaintext title",
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, chunkPath), {
      uid: "pro-user",
      chunkID: "device_session_0",
      documentID: "device_session",
      deviceId: "device",
      sourceKind: "session_log",
      sourceID: "session",
      provider: "codex",
      projectName: "BurnBar",
      ordinal: 0,
      startOffset: 0,
      endOffset: 42,
      contentHash,
      bodyHash,
      storagePath,
      sealedSnippet: sealedText,
      tokenHashes: ["c".repeat(32), "d".repeat(32)],
      semanticHashes: ["e".repeat(32), "f".repeat(32)],
      indexVersion: 1,
      tokenHashVersion: 1,
      semanticHashVersion: 1,
      commitID: "1".repeat(32),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/pro-user/cloud_search_chunks/device_session_1"), {
      uid: "pro-user",
      chunkID: "device_session_1",
      documentID: "device_session",
      deviceId: "device",
      sourceKind: "session_log",
      sourceID: "session",
      ordinal: 1,
      startOffset: 0,
      endOffset: 42,
      contentHash,
      bodyHash,
      storagePath,
      sealedSnippet: sealedText,
      tokenHashes: ["c".repeat(32)],
      semanticHashes: ["not-a-valid-hash"],
      indexVersion: 1,
      tokenHashVersion: 1,
      semanticHashVersion: 1,
      snippet: "plaintext preview",
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/pro-user/cloud_search_postings/semantic_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee_device_session_0"), {
      uid: "pro-user",
      postingKey: "semantic_" + "e".repeat(32),
      edgeID: "semantic_" + "e".repeat(32) + "_device_session_0",
      kind: "semantic",
      hash: "e".repeat(32),
      chunkID: "device_session_0",
      documentID: "device_session",
      provider: "codex",
      projectName: "BurnBar",
      updatedAt: serverTimestamp(),
      indexVersion: 1,
      commitID: "1".repeat(32),
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/pro-user/cloud_search_postings/semantic_plaintext"), {
      uid: "pro-user",
      postingKey: "semantic_" + "e".repeat(32),
      edgeID: "semantic_plaintext",
      kind: "semantic",
      hash: "e".repeat(32),
      chunkID: "device_session_0",
      documentID: "device_session",
      body: "plaintext should never be indexed",
      updatedAt: serverTimestamp(),
      indexVersion: 1,
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, indexStatePath), {
      uid: "pro-user",
      deviceId: "device",
      activeCommitID: "1".repeat(32),
      indexedThrough: "2026-05-14T00:00:00.000Z",
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await assertSucceeds(
    setDoc(doc(db, "users/pro-user/escrow_devices/device"), {
      deviceId: "device",
      platform: "iOS",
      deviceName: "Phone",
      trustState: "pending",
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    setDoc(
      doc(db, "users/pro-user/escrow_devices/device"),
      {
        trustState: "trusted",
        approvedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(doc(db, "users/pro-user/escrow_devices/mac"), {
      deviceId: "mac",
      platform: "macOS",
      deviceName: "Mac",
      trustState: "pending",
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    setDoc(
      doc(db, "users/pro-user/escrow_devices/mac"),
      {
        trustState: "trusted",
        approvedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );

  const wrapperPayload = {
    uid: "pro-user",
    targetDeviceId: "device",
    sourceDeviceId: "mac",
    publicKeyFingerprint: "fingerprint",
    keyVersion: 1,
    wrappedVaultKey: "c2VhbGVkLXZhdWx0LWtleQ==",
    vaultKeyID: TEST_VAULT_KEY_ID,
    algorithm: "ECIES-P256-AESGCM",
    status: "active",
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    schemaVersion: 2,
  };

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), "users/pro-user/escrow_devices/device"),
      {
        trustState: "trusted",
        approvedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    );
  });

  await assertSucceeds(
    setDoc(
      doc(db, "users/pro-user/escrow_devices/device"),
      {
        deviceName: "Phone renamed",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(db, "users/pro-user/escrow_devices/device"),
      {
        trustState: "pending",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );

  await assertFails(setDoc(doc(db, wrapperPath), wrapperPayload));

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), "users/pro-user/escrow_devices/mac"),
      {
        trustState: "trusted",
        approvedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    );
  });

  await assertFails(
    setDoc(
      doc(db, "users/pro-user/escrow_devices/mac"),
      {
        trustState: "revoked",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );

  await assertSucceeds(
    setDoc(doc(db, wrapperPath), wrapperPayload)
  );
});

test("remote MCP client grant audit and rate-limit docs are server-written only", async () => {
  const db = authedDb("mcp-user");

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "users/mcp-user/remote_mcp_clients/client-1"), {
      clientId: "client-1",
      displayName: "Codex",
      clientType: "codex",
      allowedScopes: ["search:read", "conversation:read"],
      grantMode: "local_decrypt_shim",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    });
    await setDoc(doc(context.firestore(), "users/mcp-user/remote_mcp_audit_events/event-1"), {
      eventKind: "tools_call",
      hashedClientID: "abc",
      createdAt: serverTimestamp(),
      schemaVersion: 1,
    });
  });

  await assertSucceeds(getDoc(doc(db, "users/mcp-user/remote_mcp_clients/client-1")));
  await assertSucceeds(getDoc(doc(db, "users/mcp-user/remote_mcp_audit_events/event-1")));

  await assertFails(
    setDoc(doc(db, "users/mcp-user/remote_mcp_clients/client-2"), {
      clientId: "client-2",
      displayName: "Self-written client",
      allowedScopes: ["search:read"],
      grantMode: "local_decrypt_shim",
    })
  );
  await assertFails(
    setDoc(doc(db, "users/mcp-user/remote_mcp_grants/grant-1"), {
      refreshTokenHash: "hash",
      clientId: "client-1",
    })
  );
  await assertFails(
    setDoc(doc(db, "users/mcp-user/remote_mcp_audit_events/event-2"), {
      eventKind: "client-written",
      query: "plaintext query should not be client logged",
    })
  );
  await assertFails(
    setDoc(doc(db, "users/mcp-user/remote_mcp_rate_limits/client-search-window"), {
      bucket: "search:standard",
      count: 1,
    })
  );
  await assertFails(getDoc(doc(authedDb("other-user"), "users/mcp-user/remote_mcp_clients/client-1")));
});

test("owners can read derived project summaries but clients cannot write them", async () => {
  const ownerDb = authedDb("erin");
  const otherDb = authedDb("mallory");
  const projectPath = "users/erin/projects/project-1";

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), projectPath), {
      id: "project-1",
      name: "Project One",
      total_cost: 42,
      updatedAt: serverTimestamp(),
    });
  });

  await assertSucceeds(getDoc(doc(ownerDb, projectPath)));
  await assertFails(getDoc(doc(otherDb, projectPath)));
  await assertFails(
    setDoc(doc(ownerDb, "users/erin/projects/project-2"), {
      id: "project-2",
      name: "Client-written project",
      total_cost: 1,
    })
  );
});

test("owners can publish smart display config and complete setup actions", async () => {
  const db = authedDb("erin");
  const configPath = "users/erin/smart_hub_config/mac-device";
  const actionPath = "users/erin/smart_display_actions/action-1";

  const displayConfig = {
    layout: "quotaCarousel",
    palette: "emberWhimsy",
    theme: "warmCharcoal",
    background: "dashboard",
    brightness: 0.85,
    scrollSpeedSeconds: 8,
    refreshCadenceSeconds: 5,
    providerIDs: [],
    audibleCue: false,
    identifyOnRefresh: false,
    updatedAt: "2026-05-10T00:00:00.000Z",
  };

  const pixelClock = {
    enabled: true,
    host: "192.168.68.92",
    port: 80,
    layout: "providerDashboard",
    palette: "emberWhimsy",
    timePeriod: "rolling5h",
    workingSpinnerStyle: "scan",
    workingSpinnerPrimaryHex: "#52D6FF",
    workingSpinnerSecondaryHex: "#FFFFFF",
    completionClockSoundEnabled: true,
    completionLocalNotificationsEnabled: true,
    pageDurationSeconds: 7,
    updateIntervalSeconds: 60,
    scrollSpeedPercent: 100,
    brightness: 160,
    providerIDs: [],
    updatedAt: "2026-05-10T00:00:00.000Z",
    lastProbeStatus: "unknown",
  };

  await assertSucceeds(
    setDoc(doc(db, configPath), {
      enabled: true,
      dashboardURL: "http://192.168.68.93:7000/",
      refreshURL: "http://192.168.68.93:7000/refresh",
      voiceRefreshURL: "http://192.168.68.93:7000/voice-refresh",
      sourceDeviceName: "OpenBurnBar Mac",
      publishedAt: "2026-05-10T00:00:00.000Z",
      timePeriod: "rolling5h",
      pixelClock,
      displayConfig,
      displayOrder: ["nestHub", "pixelClock"],
      schemaVersion: 3,
    })
  );

  await assertSucceeds(
    setDoc(doc(db, actionPath), {
      type: "pixel_clock_prepare",
      status: "pending",
      requestedAt: "2026-05-10T00:00:01.000Z",
      pixelClock,
    })
  );

  await assertSucceeds(
    setDoc(
      doc(db, actionPath),
      {
        status: "completed",
        completedAt: "2026-05-10T00:00:02.000Z",
        probeStatus: "stockUlanziFirmware",
        setupMode: "stockSimulatorConfigured",
        message: "Stock Ulanzi firmware was configured.",
        suggestedServerHost: "192.168.68.93",
        suggestedServerPort: 7001,
        flasherURL: "https://blueforcer.github.io/awtrix3/#/flasher",
      },
      { merge: true }
    )
  );

  await assertSucceeds(
    setDoc(doc(db, "users/erin/smart_display_actions/action-2"), {
      type: "nest_hub_update_order",
      status: "pending",
      requestedAt: "2026-05-10T00:00:03.000Z",
      displayOrder: ["pixelClock", "nestHub"],
    })
  );
});

test("owners can run Cast wizard actions and read discovery results", async () => {
  const db = authedDb("fran");

  await assertSucceeds(
    setDoc(doc(db, "users/fran/cast_actions/action-1"), {
      type: "test",
      status: "pending",
      requestedAt: "2026-05-10T00:00:00.000Z",
    })
  );

  await assertSucceeds(
    setDoc(
      doc(db, "users/fran/cast_actions/action-1"),
      {
        status: "completed",
        completedAt: "2026-05-10T00:00:01.000Z",
      },
      { merge: true }
    )
  );

  await assertSucceeds(
    setDoc(doc(db, "users/fran/cast_discovery_results/latest"), {
      devices: [
        {
          serviceName: "Google-Nest-Hub._googlecast._tcp.local.",
          friendlyName: "Kitchen Display",
          model: "Google Nest Hub",
          host: "192.168.68.50",
          port: 8009,
          identifier: "nest-hub",
          iconKind: "nestHub",
          supportsDisplay: true,
        },
      ],
      publishedAt: "2026-05-10T00:00:02.000Z",
    })
  );
});

test("Pi Agent relay requires hosted entitlement and encrypted v2 payloads", async () => {
  const db = authedDb("gina");
  const connectionPath = "users/gina/pi_agent_connections/relay-mac";
  const requestPath = "users/gina/pi_agent_relay_requests/req-1";

  const connectionDoc = {
    id: "relay-mac",
    displayName: "Mac Pi Relay",
    mode: "relayLink",
    status: "online",
    advertisedModel: "pi-default",
    selectedInstanceID: "default",
    capabilities: ["chat_completions", "remote_relay"],
    relayPublicKey: "pub",
    relayKeyVersion: 1,
    relayEncryption: "p256-hkdf-sha256-aesgcm",
    createdAt: "2026-05-12T00:00:00.000Z",
    updatedAt: "2026-05-12T00:00:00.000Z",
    schemaVersion: 2,
  };

  await assertFails(setDoc(doc(db, connectionPath), connectionDoc));
  await seedHostedCloudEntitlement("gina");
  await assertSucceeds(setDoc(doc(db, connectionPath), connectionDoc));

  await assertFails(
    setDoc(doc(db, requestPath), {
      id: "req-1",
      connectionId: "relay-mac",
      operation: "chatCompletions",
      status: "pending",
      method: "POST",
      body: "{\"messages\":[]}",
      chunkCount: 0,
      createdAt: "2026-05-12T00:00:01.000Z",
      updatedAt: "2026-05-12T00:00:01.000Z",
      expiresAt: "2026-05-12T00:01:01.000Z",
      expireAt: Timestamp.fromDate(new Date("2026-05-12T00:01:01.000Z")),
      schemaVersion: 1,
    })
  );

  await assertSucceeds(
    setDoc(doc(db, requestPath), {
      id: "req-1",
      connectionId: "relay-mac",
      operation: "chatCompletions",
      status: "pending",
      method: "POST",
      payloadCiphertext: "ciphertext",
      wrappedKey: "wrapped",
      relayEncryption: "p256-hkdf-sha256-aesgcm",
      relayKeyVersion: 1,
      chunkCount: 0,
      createdAt: "2026-05-12T00:00:01.000Z",
      updatedAt: "2026-05-12T00:00:01.000Z",
      expiresAt: "2026-05-12T00:01:01.000Z",
      expireAt: Timestamp.fromDate(new Date("2026-05-12T00:01:01.000Z")),
      schemaVersion: 2,
    })
  );

  await assertFails(
    setDoc(doc(db, `${requestPath}/chunks/00000000`), {
      id: "00000000",
      requestId: "req-1",
      sequence: 0,
      kind: "data",
      data: "plain text",
      createdAt: "2026-05-12T00:00:02.000Z",
      schemaVersion: 2,
    })
  );

  await assertSucceeds(
    setDoc(doc(db, `${requestPath}/chunks/00000000`), {
      id: "00000000",
      requestId: "req-1",
      sequence: 0,
      kind: "data",
      ciphertext: "encrypted chunk",
      createdAt: "2026-05-12T00:00:02.000Z",
      schemaVersion: 2,
    })
  );
});

test("runtime preferences are per device and provider device links are server-written", async () => {
  const db = authedDb("hank");

  await assertSucceeds(
    setDoc(doc(db, "users/hank/runtime_connection_preferences/mac-1_piAgent"), {
      id: "mac-1_piAgent",
      deviceID: "mac-1",
      runtimeKind: "piAgent",
      selectedConnectionID: "relay-mac",
      selectedInstanceID: "default",
      selectedModelID: "pi-default",
      createdAt: "2026-05-12T00:00:00.000Z",
      updatedAt: "2026-05-12T00:00:00.000Z",
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/hank/runtime_connection_preferences/mac-1_hermes"), {
      id: "mac-1_hermes",
      deviceID: "mac-1",
      runtimeKind: "piAgent",
      selectedConnectionID: "relay-mac",
      createdAt: "2026-05-12T00:00:00.000Z",
      updatedAt: "2026-05-12T00:00:00.000Z",
      schemaVersion: 1,
    })
  );

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "users/hank/provider_account_device_links/acct-1_mac-1"), {
      id: "acct-1_mac-1",
      accountID: "acct-1",
      deviceID: "mac-1",
      deviceDisplayName: "Mac",
      capability: "owner",
      status: "active",
      lastObservedAt: "2026-05-12T00:00:00.000Z",
      createdAt: "2026-05-12T00:00:00.000Z",
      updatedAt: "2026-05-12T00:00:00.000Z",
      schemaVersion: 1,
    });
  });

  await assertSucceeds(getDoc(doc(db, "users/hank/provider_account_device_links/acct-1_mac-1")));
  await assertFails(
    setDoc(doc(db, "users/hank/provider_account_device_links/acct-1_phone-1"), {
      id: "acct-1_phone-1",
      accountID: "acct-1",
      deviceID: "phone-1",
      deviceDisplayName: "Phone",
      capability: "use",
      status: "active",
      lastObservedAt: "2026-05-12T00:00:00.000Z",
      createdAt: "2026-05-12T00:00:00.000Z",
      updatedAt: "2026-05-12T00:00:00.000Z",
      schemaVersion: 1,
    })
  );
});

test("agent notification events are server-written and replies are queued by owner", async () => {
  const db = authedDb("nina");
  const otherDb = authedDb("mallory");
  const eventPath = "users/nina/agent_notification_events/event-1";
  const replyPath = "users/nina/agent_notification_replies/reply-1";
  await seedCloudVaultState("nina");

  await assertFails(
    setDoc(doc(db, eventPath), {
      id: "event-1",
      uid: "nina",
      threadId: "thread-1",
      messageId: "assistant-1",
      runtime: "codex",
      preview: "Done.",
    })
  );

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), eventPath), {
      id: "event-1",
      uid: "nina",
      sourceKind: "cli_session",
      sourcePath: "users/nina/cli_sessions/thread-1",
      threadId: "thread-1",
      messageId: "assistant-1",
      runtime: "codex",
      providerLabel: "Codex",
      title: "Codex replied",
      preview: "Done.",
      createdAt: serverTimestamp(),
      createdAtMillis: Date.now(),
      updatedAt: serverTimestamp(),
      updatedAtMillis: Date.now(),
      status: "pending",
      fanoutAttemptCount: 0,
      replyEnabled: true,
      schemaVersion: 1,
    });
  });

  await assertSucceeds(getDoc(doc(db, eventPath)));
  await assertFails(getDoc(doc(otherDb, eventPath)));

  await assertSucceeds(
    setDoc(doc(db, replyPath), {
      id: "reply-1",
      uid: "nina",
      eventId: "event-1",
      threadId: "thread-1",
      runtime: "codex",
      sourceKind: "cli_session",
      contentSealed: true,
      sealedSchemaVersion: 2,
      vaultKeyID: TEST_VAULT_KEY_ID,
      sealedReplyPayload: sealedPayload(),
      deviceId: "iphone",
      status: "queued",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );
  await assertSucceeds(
    updateDoc(doc(db, replyPath), {
      status: "processing",
      processorDeviceId: "mac-host",
      processedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    })
  );
  await assertSucceeds(
    updateDoc(doc(db, replyPath), {
      status: "sent",
      processedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    updateDoc(doc(db, replyPath), {
      replyText: "mutated",
      updatedAt: serverTimestamp(),
    })
  );

  await assertFails(
    setDoc(doc(otherDb, "users/nina/agent_notification_replies/reply-2"), {
      id: "reply-2",
      uid: "nina",
      eventId: "event-1",
      threadId: "thread-1",
      runtime: "codex",
      sourceKind: "cli_session",
      contentSealed: true,
      sealedSchemaVersion: 2,
      vaultKeyID: TEST_VAULT_KEY_ID,
      sealedReplyPayload: sealedPayload(),
      status: "queued",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/nina/agent_notification_replies/reply-3"), {
      id: "reply-3",
      uid: "nina",
      eventId: "event-1",
      threadId: "thread-1",
      runtime: "codex",
      sourceKind: "cli_session",
      replyText: "",
      contentSealed: true,
      sealedSchemaVersion: 2,
      vaultKeyID: TEST_VAULT_KEY_ID,
      sealedReplyPayload: sealedPayload(),
      status: "queued",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/nina/agent_notification_replies/reply-forged-thread"), {
      id: "reply-forged-thread",
      uid: "nina",
      eventId: "event-1",
      threadId: "different-thread",
      runtime: "codex",
      sourceKind: "cli_session",
      contentSealed: true,
      sealedSchemaVersion: 2,
      vaultKeyID: TEST_VAULT_KEY_ID,
      sealedReplyPayload: sealedPayload(),
      status: "queued",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/nina/agent_notification_replies/reply-missing-event"), {
      id: "reply-missing-event",
      uid: "nina",
      eventId: "missing-event",
      threadId: "thread-1",
      runtime: "codex",
      sourceKind: "cli_session",
      contentSealed: true,
      sealedSchemaVersion: 2,
      vaultKeyID: TEST_VAULT_KEY_ID,
      sealedReplyPayload: sealedPayload(),
      status: "queued",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );
});

test("Hermes Gateway state is server-owned and destinations are Cloud-gated", async () => {
  const ownerDb = authedDb("hgw-owner");
  const otherDb = authedDb("hgw-mallory");
  const serverOwnedDocs = [
    [
      "users/hgw-owner/hermes_gateway_clients/client-1",
      {
        id: "client-1",
        displayName: "Hermes",
        status: "active",
        tokenPreview: "obb_hgw_...abcd",
        scopes: ["hermes.gateway.read"],
        homeDestinationId: "burnbar:home",
        createdAt: "2026-06-01T00:00:00.000Z",
        updatedAt: "2026-06-01T00:00:00.000Z",
        schemaVersion: 1,
      },
    ],
    [
      "users/hgw-owner/hermes_gateway_events/event-1",
      {
        id: "event-1",
        sequence: 1,
        kind: "message",
        destinationId: "burnbar:home",
        senderId: "burnbar-user",
        text: "hello",
        attachmentIds: [],
        createdAt: "2026-06-01T00:00:00.000Z",
        schemaVersion: 1,
      },
    ],
    [
      "users/hgw-owner/hermes_gateway_messages/message-1",
      {
        id: "message-1",
        clientId: "client-1",
        kind: "agent_message",
        destinationId: "burnbar:home",
        text: "reply",
        attachmentIds: [],
        createdAt: "2026-06-01T00:00:00.000Z",
        schemaVersion: 1,
      },
    ],
    [
      "users/hgw-owner/hermes_gateway_typing/client-1",
      {
        id: "client-1",
        clientId: "client-1",
        kind: "typing",
        destinationId: "burnbar:home",
        createdAt: "2026-06-01T00:00:00.000Z",
        expiresAt: "2026-06-01T00:00:15.000Z",
        schemaVersion: 1,
      },
    ],
    [
      "users/hgw-owner/hermes_gateway_attachments/attachment-1",
      {
        id: "attachment-1",
        clientId: "client-1",
        destinationId: "burnbar:home",
        fileName: "image.png",
        contentType: "image/png",
        byteCount: 100,
        storagePath: "users/hgw-owner/hermes_gateway_attachments/client-1/attachment-1/image.png",
        status: "pending_upload",
        createdAt: "2026-06-01T00:00:00.000Z",
        expiresAt: "2026-06-01T00:10:00.000Z",
        schemaVersion: 1,
      },
    ],
    [
      "users/hgw-owner/hermes_gateway_state/cursors",
      {
        eventSequence: 1,
        updatedAt: "2026-06-01T00:00:00.000Z",
        schemaVersion: 1,
      },
    ],
    [
      // Oversight gate: the owner may READ it (the approval UI lights up) but can
      // never WRITE/self-approve — resolution is Admin-SDK-only via
      // respondHermesGatewayApproval (trusted native device + approvedByDeviceId).
      "users/hgw-owner/hermes_gateway_approvals/approval-1",
      {
        id: "approval-1",
        clientId: "client-1",
        destinationId: "burnbar:home",
        actionId: "run-shell-1",
        toolName: "shell",
        summary: "rm -rf /tmp/build-cache",
        status: "waiting_for_approval",
        requestedAt: "2026-06-01T00:00:00.000Z",
        expiresAt: "2026-06-01T00:05:00.000Z",
        schemaVersion: 1,
      },
    ],
  ];

  await testEnv.withSecurityRulesDisabled(async (context) => {
    for (const [path, payload] of serverOwnedDocs) {
      await setDoc(doc(context.firestore(), path), payload);
    }
    await setDoc(doc(context.firestore(), "hermes_gateway_device_sessions/session-1"), {
      deviceCode: "session-1",
      userCode: "ABCD-2345",
      status: "pending",
    });
    await setDoc(doc(context.firestore(), "hermes_gateway_token_index/" + "a".repeat(64)), {
      uid: "hgw-owner",
      clientId: "client-1",
      status: "active",
    });
  });

  for (const [path, payload] of serverOwnedDocs) {
    await assertSucceeds(getDoc(doc(ownerDb, path)));
    await assertFails(getDoc(doc(otherDb, path)));
    await assertFails(setDoc(doc(ownerDb, path), payload));
  }
  await assertFails(getDoc(doc(ownerDb, "hermes_gateway_device_sessions/session-1")));
  await assertFails(
    setDoc(doc(ownerDb, "hermes_gateway_device_sessions/session-2"), {
      deviceCode: "session-2",
      userCode: "WXYZ-2345",
      status: "pending",
    })
  );
  await assertFails(getDoc(doc(ownerDb, "hermes_gateway_token_index/" + "a".repeat(64))));
  await assertFails(
    setDoc(doc(ownerDb, "hermes_gateway_token_index/" + "b".repeat(64)), {
      uid: "hgw-owner",
      clientId: "client-1",
      status: "active",
    })
  );

  const destinationPath = "users/hgw-owner/hermes_gateway_destinations/ops";
  const destination = {
    id: "burnbar:ops",
    displayName: "Ops",
    kind: "chat",
    status: "active",
    isDefault: false,
    createdAt: "2026-06-01T00:00:00.000Z",
    updatedAt: "2026-06-01T00:00:00.000Z",
    schemaVersion: 1,
  };
  await assertFails(setDoc(doc(ownerDb, destinationPath), destination));
  await seedBurnBarProMaxEntitlement("hgw-owner");
  await assertFails(setDoc(doc(ownerDb, destinationPath), destination));
  await assertSucceeds(getDoc(doc(ownerDb, destinationPath)));
  await assertFails(getDoc(doc(otherDb, destinationPath)));
  await assertFails(
    setDoc(doc(ownerDb, "users/hgw-owner/hermes_gateway_destinations/leaky"), {
      ...destination,
      id: "burnbar:leaky",
      secret: "must-not-pass",
    })
  );
});

// ---------------------------------------------------------------------------
// privacy-leak-remediation-2026-06-02 — denylist -> hasOnly allowlist hardening.
// T1-T9: prove the sealed shapes are accepted, that arbitrary unlisted keys are
// rejected on BOTH the create and the merge-update paths, and that the gateway
// relay collection is already-sealed (ciphertext, never plaintext text/body).
// ---------------------------------------------------------------------------

// T1 — hermes_relay_requests (gateway) is already sealed on create AND update.
test("T1 hermes_relay_requests stays sealed across create and merge update", async () => {
  const db = authedDb("relay-owner");
  const requestPath = "users/relay-owner/hermes_relay_requests/req-1";
  const chunkPath = `${requestPath}/chunks/00000000`;
  await seedHostedCloudEntitlement("relay-owner");

  const sealedRequest = {
    id: "req-1",
    connectionId: "relay-mac",
    operation: "chatCompletions",
    status: "pending",
    method: "POST",
    payloadCiphertext: "ciphertext",
    enc: "encapsulated-key",
    wrappedKey: "wrapped",
    relayEncryption: "hpke-auth-p256-hkdfsha256-aes256gcm",
    relayKeyVersion: 3,
    senderPublicKey:
      "B".repeat(88),
    senderDeviceId: "ios-device-1",
    senderPeerNodeId: "ios-phone-abcdef123456",
    senderCounter: 1,
    keyId: `relay-v3-${"a".repeat(24)}`,
    chunkCount: 0,
    createdAt: "2026-06-02T00:00:01.000Z",
    updatedAt: "2026-06-02T00:00:01.000Z",
    schemaVersion: 2,
  };

  // Plaintext body / sessionId / path are denied outright.
  await assertFails(
    setDoc(doc(db, requestPath), { ...sealedRequest, body: "{\"messages\":[]}" })
  );
  await assertFails(
    setDoc(doc(db, requestPath), { ...sealedRequest, sessionId: "leak-session" })
  );
  // The sender-authenticated sealed v3 request succeeds.
  await assertSucceeds(setDoc(doc(db, requestPath), sealedRequest));

  // A merge update advancing the status stays sealed and is allowed.
  await assertSucceeds(
    setDoc(
      doc(db, requestPath),
      { ...sealedRequest, status: "streaming", updatedAt: "2026-06-02T00:00:02.000Z" },
      { merge: true }
    )
  );

  // A merge update smuggling a plaintext body is denied (catches the
  // merge-semantics regression where a later partial write re-introduces a
  // cleartext field past a create-only check).
  await assertFails(
    setDoc(doc(db, requestPath), { body: "leak" }, { merge: true })
  );

  // Chunk: plaintext text/data denied, sealed ciphertext chunk allowed.
  await assertFails(
    setDoc(doc(db, chunkPath), {
      id: "00000000",
      requestId: "req-1",
      sequence: 0,
      kind: "sse",
      text: "leaked token stream",
      createdAt: "2026-06-02T00:00:03.000Z",
      schemaVersion: 2,
    })
  );
  await assertSucceeds(
    setDoc(doc(db, chunkPath), {
      id: "00000000",
      requestId: "req-1",
      sequence: 0,
      kind: "sse",
      ciphertext: "encrypted-chunk",
      createdAt: "2026-06-02T00:00:03.000Z",
      schemaVersion: 2,
    })
  );
});

// T2 — mobile_assistant_chats rejects plaintext content and unlisted keys.
test("T2 mobile_assistant_chats denies plaintext content and unlisted keys", async () => {
  const db = authedDb("ma-owner");
  const threadPath = "users/ma-owner/mobile_assistant_chats/thread-1";
  await seedCloudVaultState("ma-owner");

  const sealedThread = {
    id: "thread-1",
    runtime: "hermes",
    createdAt: "2026-06-02T00:00:00.000Z",
    updatedAt: "2026-06-02T00:00:00.000Z",
    messageCount: 3,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(),
  };

  await assertSucceeds(setDoc(doc(db, threadPath), sealedThread));

  // Plaintext messages / title are denied.
  await assertFails(
    setDoc(doc(db, "users/ma-owner/mobile_assistant_chats/thread-2"), {
      ...sealedThread,
      id: "thread-2",
      messages: [{ role: "user", content: "secret prompt" }],
    })
  );
  await assertFails(
    setDoc(doc(db, "users/ma-owner/mobile_assistant_chats/thread-3"), {
      ...sealedThread,
      id: "thread-3",
      title: "private title",
    })
  );
  // An arbitrary unlisted key is denied by hasOnly.
  await assertFails(
    setDoc(doc(db, "users/ma-owner/mobile_assistant_chats/thread-4"), {
      ...sealedThread,
      id: "thread-4",
      summary: "smuggled plaintext summary",
    })
  );
});

// L37 (rules half) — the optional additive Signal at-rest `signalEnvelope` field is
// accepted ONLY when its binding matches the doc PATH, and every relocation / forgery /
// pollution / mode-confusion fails closed. This is the named "Current Live Blocker"
// (firestore.rules had CloudVault validators but no validSignalEnvelope path-binding
// validator) and the rules dimension of L31 + L37.
test("L37 signalEnvelope is path-bound on mobile_assistant_chats; relocation fails closed", async () => {
  const db = authedDb("sig-owner");
  await seedCloudVaultState("sig-owner");
  const threadPath = "users/sig-owner/mobile_assistant_chats/thread-1";

  const baseThread = {
    id: "thread-1",
    runtime: "hermes",
    createdAt: "2026-06-05T00:00:00.000Z",
    updatedAt: "2026-06-05T00:00:00.000Z",
    messageCount: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(),
  };

  const goodEnvelope = signalAtRestEnvelope({
    uid: "sig-owner",
    collection: "mobile_assistant_chats",
    docId: "thread-1",
  });

  // 1. Valid envelope bound to THIS exact path is accepted (alongside the legacy field).
  await assertSucceeds(setDoc(doc(db, threadPath), { ...baseThread, signalEnvelope: goodEnvelope }));

  // 2. The IDENTICAL envelope written at a DIFFERENT doc path fails closed (relocation):
  //    binding.docId="thread-1" no longer matches the path's threadId="thread-2".
  await assertFails(
    setDoc(doc(db, "users/sig-owner/mobile_assistant_chats/thread-2"), {
      ...baseThread,
      id: "thread-2",
      signalEnvelope: goodEnvelope,
    })
  );

  // 3. Per-coordinate relocation of the binding — each must fail closed.
  const relocations = [
    { binding: { uid: "attacker" } }, // wrong uid
    { binding: { collection: "cli_agent_mission_requests" } }, // wrong collection
    { binding: { docId: "thread-999" } }, // wrong docId
    { binding: { field: "sealedPayload" } }, // wrong field
    { binding: { scope: "gateway" } }, // wrong scope (gateway≠cloudvault)
    { binding: { mode: "transport" } }, // binding mode confusion
    { binding: { formatVersion: 2 } }, // wrong format version
    { binding: { clientId: "c1" } }, // gateway-only field on a cloudvault binding (hasOnly)
    { binding: { slotId: "s1" } }, // gateway-only field on a cloudvault binding (hasOnly)
  ];
  let n = 100;
  for (const reloc of relocations) {
    n += 1;
    await assertFails(
      setDoc(doc(db, `users/sig-owner/mobile_assistant_chats/thread-${n}`), {
        ...baseThread,
        id: `thread-${n}`,
        signalEnvelope: signalAtRestEnvelope({
          uid: "sig-owner",
          collection: "mobile_assistant_chats",
          docId: `thread-${n}`,
          ...reloc,
        }),
      })
    );
  }

  // 4. Envelope-level forgery / mode confusion / pollution — each must fail closed.
  const forgeries = [
    { envelope: { mode: "transport" } }, // top-level mode mismatch
    { envelope: { relayEncryption: "signal-doubleratchet-pqxdh-v1" } }, // transport scheme on at-rest
    { envelope: { signalEnvelopeFormatVersion: 2 } }, // wrong envelope version
    { envelope: { relayKeyVersion: 4 } }, // transport-only field present (hasOnly rejects on at-rest)
    { envelope: { extraTopLevel: "x" } }, // unlisted top-level key (hasOnly)
    { ciphertextLayer: { payloadCiphertextB64: "not_base64!!" } }, // bad base64 charset
    { ciphertextLayer: { payloadCiphertextB64: "abc" } }, // length not %4
    { ciphertextLayer: { payloadCiphertextB64: "" } }, // empty ciphertext
    { ciphertextLayer: { payloadAADLabel: "has a space" } }, // label charset (no spaces/pipe)
    { ciphertextLayer: { extra: "x" } }, // unlisted ciphertextLayer key (hasOnly)
    { keyDelivery: { contentKeyLength: 16 } }, // wrong content-key length
    { keyDelivery: { scheme: "signal-doubleratchet-pqxdh-v1" } }, // transport scheme in keyDelivery
    { keyDelivery: { wraps: [] } }, // empty wraps (< 1)
    { keyDelivery: { extra: "x" } }, // unlisted keyDelivery key (hasOnly)
  ];
  let m = 200;
  for (const forge of forgeries) {
    m += 1;
    await assertFails(
      setDoc(doc(db, `users/sig-owner/mobile_assistant_chats/thread-${m}`), {
        ...baseThread,
        id: `thread-${m}`,
        signalEnvelope: signalAtRestEnvelope({
          uid: "sig-owner",
          collection: "mobile_assistant_chats",
          docId: `thread-${m}`,
          ...forge,
        }),
      })
    );
  }

  // 5. A plaintext field smuggled INSIDE the envelope key slot (not the envelope shape)
  //    fails closed — the field must be a valid envelope, never arbitrary data.
  await assertFails(
    setDoc(doc(db, "users/sig-owner/mobile_assistant_chats/thread-plain"), {
      ...baseThread,
      id: "thread-plain",
      signalEnvelope: { plaintext: "secret message" },
    })
  );

  // 6. (Remediation R11) Type confusion — a NON-MAP signalEnvelope value (string,
  //    number, bool, list) fails closed; validSignalAtRestEnvelope opens with
  //    `value is map`, so a non-map can never substitute for an envelope.
  const nonMapValues = ["not-a-map", 123, true, ["array", "not", "map"]];
  for (let i = 0; i < nonMapValues.length; i += 1) {
    await assertFails(
      setDoc(doc(db, `users/sig-owner/mobile_assistant_chats/thread-nonmap-${i}`), {
        ...baseThread,
        id: `thread-nonmap-${i}`,
        signalEnvelope: nonMapValues[i],
      })
    );
  }
});

// L37 (rules half) — the same path-binding guard on the second client-writable at-rest
// body collection (cli_agent_mission_requests), proving the validator is wired
// per-collection, not just once.
test("L37 signalEnvelope is path-bound on cli_agent_mission_requests; cross-collection fails", async () => {
  const phoneDb = authedDb("ivy-sig");
  await seedCloudVaultState("ivy-sig");
  const requestPath = "users/ivy-sig/cli_agent_mission_requests/mission-1";

  const goodEnvelope = signalAtRestEnvelope({
    uid: "ivy-sig",
    collection: "cli_agent_mission_requests",
    docId: "mission-1",
  });

  // Valid envelope bound to this mission doc is accepted alongside the sealed payload.
  await assertSucceeds(
    setDoc(doc(phoneDb, requestPath), sealedMissionBase("mission-1", { signalEnvelope: goodEnvelope }))
  );

  // Cross-collection binding (envelope says it belongs to mobile_assistant_chats) fails.
  await assertFails(
    setDoc(
      doc(phoneDb, "users/ivy-sig/cli_agent_mission_requests/mission-2"),
      sealedMissionBase("mission-2", {
        signalEnvelope: signalAtRestEnvelope({
          uid: "ivy-sig",
          collection: "mobile_assistant_chats",
          docId: "mission-2",
        }),
      })
    )
  );

  // Same-collection wrong docId (relocation within the collection) fails.
  await assertFails(
    setDoc(
      doc(phoneDb, "users/ivy-sig/cli_agent_mission_requests/mission-3"),
      sealedMissionBase("mission-3", {
        signalEnvelope: signalAtRestEnvelope({
          uid: "ivy-sig",
          collection: "cli_agent_mission_requests",
          docId: "mission-DIFFERENT",
        }),
      })
    )
  );

  // Cross-user uid in the binding fails (the path owner is ivy-sig).
  await assertFails(
    setDoc(
      doc(phoneDb, "users/ivy-sig/cli_agent_mission_requests/mission-4"),
      sealedMissionBase("mission-4", {
        signalEnvelope: signalAtRestEnvelope({
          uid: "someone-else",
          collection: "cli_agent_mission_requests",
          docId: "mission-4",
        }),
      })
    )
  );
});

// L37 — a (well-formed) signalEnvelope on a collection that was NOT wired (cli_sessions)
// is rejected by that collection's hasOnly allowlist. Proves the optional field was added
// per-collection, fail-closed by default — not globally.
test("L37 signalEnvelope is rejected on a not-wired collection (cli_sessions hasOnly)", async () => {
  const db = authedDb("nw-owner");
  await seedCloudVaultState("nw-owner");
  const base = {
    id: "sess-1",
    agent: "codex",
    createdAt: "2026-06-05T00:00:00.000Z",
    updatedAt: "2026-06-05T00:00:00.000Z",
    schemaVersion: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(),
  };
  await assertSucceeds(setDoc(doc(db, "users/nw-owner/cli_sessions/sess-1"), base));
  await assertFails(
    setDoc(doc(db, "users/nw-owner/cli_sessions/sess-2"), {
      ...base,
      id: "sess-2",
      signalEnvelope: signalAtRestEnvelope({ uid: "nw-owner", collection: "cli_sessions", docId: "sess-2" }),
    })
  );
});

// T3 — session_logs manifest rejects an arbitrary unlisted key (hasOnly).
test("T3 session_logs manifest denies arbitrary unlisted keys", async () => {
  const db = authedDb("slm-owner");
  await seedHostedCloudEntitlement("slm-owner");
  const base = {
    id: "log",
    deviceId: "device",
    provider: "codex",
    sessionId: "session",
    chunkCount: 1,
    updatedAt: serverTimestamp(),
  };

  await assertSucceeds(
    setDoc(doc(db, "users/slm-owner/session_logs/ok"), base)
  );
  await assertSucceeds(
    setDoc(doc(db, "users/slm-owner/session_logs/generic-title"), {
      ...base,
      inferredTaskTitle: "Encrypted session",
    })
  );
  // Arbitrary unlisted key.
  await assertFails(
    setDoc(doc(db, "users/slm-owner/session_logs/smuggled"), {
      ...base,
      smuggled: "x",
    })
  );
  // Classic plaintext-content vectors stay denied.
  await assertFails(
    setDoc(doc(db, "users/slm-owner/session_logs/body"), { ...base, body: "leak" })
  );
  await assertFails(
    setDoc(doc(db, "users/slm-owner/session_logs/title"), { ...base, title: "leak" })
  );
  await assertFails(
    setDoc(doc(db, "users/slm-owner/session_logs/inferred-title"), {
      ...base,
      inferredTaskTitle: "Build BurnBar privacy hardening",
    })
  );
  await assertFails(
    setDoc(doc(db, "users/slm-owner/session_logs/proj"), { ...base, projectName: "BurnBar" })
  );
});

// T4 — session_logs chunk writes are server-only. Search chunks are committed
// through commitEncryptedSearchIndexBatch, where the callable validates every
// token/semantic hash before Admin SDK writes `cloud_search_chunks`.
test("T4 session_logs chunk denies all direct client writes", async () => {
  const db = authedDb("slc-owner");
  await seedHostedCloudEntitlement("slc-owner");
  const chunkBase = {
    index: 0,
    hash: "hash",
    sealedSnippet: sealedText(),
    tokenHashes: ["a".repeat(32)],
    semanticHashes: ["b".repeat(32)],
    bodyStorage: "local_or_icloud",
    schemaVersion: 3,
    updatedAt: serverTimestamp(),
  };

  await assertFails(
    setDoc(doc(db, "users/slc-owner/session_logs/log/chunks/0"), chunkBase)
  );
  await assertFails(
    setDoc(doc(db, "users/slc-owner/session_logs/log/chunks/1"), {
      ...chunkBase,
      smuggled: "x",
    })
  );
  await assertFails(
    setDoc(doc(db, "users/slc-owner/session_logs/log/chunks/2"), {
      ...chunkBase,
      text: "leak",
    })
  );
  await assertFails(
    setDoc(doc(db, "users/slc-owner/session_logs/log/chunks/3"), {
      ...chunkBase,
      tokenHashes: ["private prompt"],
    })
  );
  await assertFails(
    setDoc(doc(db, "users/slc-owner/session_logs/log/chunks/4"), {
      ...chunkBase,
      semanticHashes: ["not-a-valid-hash"],
    })
  );
});

// T5 — conversations: create sealed, then a merge update adding plaintext is denied.
test("T5 conversations deny plaintext smuggled on the merge-update path", async () => {
  const db = authedDb("conv-owner");
  await seedCloudVaultState("conv-owner");
  await seedHostedCloudEntitlement("conv-owner");
  const convPath = "users/conv-owner/conversations/conv-1";
  const sealedConversation = {
    id: "conv-1",
    deviceId: "device",
    provider: "codex",
    sessionId: "session",
    messageCount: 1,
    userWordCount: 10,
    assistantWordCount: 20,
    updatedAt: serverTimestamp(),
    sourceType: "provider_log",
    version: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(),
  };

  await assertSucceeds(setDoc(doc(db, convPath), sealedConversation));
  // Re-introducing a plaintext projectName via merge is denied.
  await assertFails(
    setDoc(doc(db, convPath), { projectName: "BurnBar" }, { merge: true })
  );
});

// L37b (rules half) — the Mac client-direct collections chat_threads + conversations
// accept the optional additive Signal at-rest `signalEnvelope` ONLY when its binding
// matches the doc PATH; relocation / wrong-collection forgery fails closed. These two
// were the collections missing from the hasOnly allowlists (P0-2): without the field in
// hasOnly the whole write (legacy sealedPayload included) was permission-denied.
test("L37b signalEnvelope is path-bound on chat_threads + conversations; relocation fails closed", async () => {
  const db = authedDb("sigb-owner");
  await seedCloudVaultState("sigb-owner");
  await seedHostedCloudEntitlement("sigb-owner");

  // ---- chat_threads ----
  const threadBase = {
    threadId: "ct-1",
    deviceId: "device",
    messageCount: 1,
    contentIncluded: true,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(),
    createdAt: "2026-06-05T00:00:00.000Z",
    updatedAt: "2026-06-05T00:00:00.000Z",
  };
  const goodThreadEnv = signalAtRestEnvelope({
    uid: "sigb-owner",
    collection: "chat_threads",
    docId: "ct-1",
  });
  // 1. Valid envelope bound to THIS exact path is accepted alongside the legacy field.
  await assertSucceeds(
    setDoc(doc(db, "users/sigb-owner/chat_threads/ct-1"), { ...threadBase, signalEnvelope: goodThreadEnv })
  );
  // 2. The SAME envelope at a different doc fails closed (binding.docId no longer matches).
  await assertFails(
    setDoc(doc(db, "users/sigb-owner/chat_threads/ct-2"), {
      ...threadBase,
      threadId: "ct-2",
      signalEnvelope: goodThreadEnv,
    })
  );
  // 3. An envelope bound to a DIFFERENT collection fails closed on chat_threads.
  await assertFails(
    setDoc(doc(db, "users/sigb-owner/chat_threads/ct-3"), {
      ...threadBase,
      threadId: "ct-3",
      signalEnvelope: signalAtRestEnvelope({ uid: "sigb-owner", collection: "mobile_assistant_chats", docId: "ct-3" }),
    })
  );

  // ---- conversations ----
  const convBase = {
    id: "conv-sig-1",
    deviceId: "device",
    provider: "codex",
    sessionId: "session",
    messageCount: 1,
    userWordCount: 10,
    assistantWordCount: 20,
    updatedAt: serverTimestamp(),
    sourceType: "provider_log",
    version: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(),
  };
  const goodConvEnv = signalAtRestEnvelope({
    uid: "sigb-owner",
    collection: "conversations",
    docId: "conv-sig-1",
  });
  // 1. Valid envelope bound to THIS exact path is accepted.
  await assertSucceeds(
    setDoc(doc(db, "users/sigb-owner/conversations/conv-sig-1"), { ...convBase, signalEnvelope: goodConvEnv })
  );
  // 2. Relocation to a different conversation doc fails closed.
  await assertFails(
    setDoc(doc(db, "users/sigb-owner/conversations/conv-sig-2"), {
      ...convBase,
      id: "conv-sig-2",
      signalEnvelope: goodConvEnv,
    })
  );
  // 3. Wrong-collection binding fails closed on conversations.
  await assertFails(
    setDoc(doc(db, "users/sigb-owner/conversations/conv-sig-3"), {
      ...convBase,
      id: "conv-sig-3",
      signalEnvelope: signalAtRestEnvelope({ uid: "sigb-owner", collection: "chat_threads", docId: "conv-sig-3" }),
    })
  );
});

// T6 — cli_sessions: create sealed, then a merge update adding plaintext is denied.
test("T6 cli_sessions deny plaintext smuggled on the merge-update path", async () => {
  const db = authedDb("cli-owner");
  await seedCloudVaultState("cli-owner");
  const sessionPath = "users/cli-owner/cli_sessions/thread-1";
  await assertSucceeds(
    setDoc(doc(db, sessionPath), {
      id: "thread-1",
      agent: "claude",
      createdAt: "2026-06-02T00:00:00.000Z",
      updatedAt: "2026-06-02T00:00:03.000Z",
      schemaVersion: 1,
      contentSealed: true,
      sealedSchemaVersion: 2,
      vaultKeyID: TEST_VAULT_KEY_ID,
      sealedPayload: sealedPayload(),
      messageCount: 1,
    })
  );
  await assertFails(
    setDoc(doc(db, sessionPath), { summary: "leak" }, { merge: true })
  );
  await assertFails(
    setDoc(doc(db, sessionPath), { title: "leak" }, { merge: true })
  );
});

// T7 — session_logs manifest: create sealed, then a merge update adding plaintext
// / an arbitrary key is denied (the merge-semantics regression guard).
test("T7 session_logs manifest denies plaintext on the merge-update path", async () => {
  const db = authedDb("slu-owner");
  await seedHostedCloudEntitlement("slu-owner");
  const logPath = "users/slu-owner/session_logs/log";
  await assertSucceeds(
    setDoc(doc(db, logPath), {
      id: "log",
      deviceId: "device",
      provider: "codex",
      sessionId: "session",
      chunkCount: 1,
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    setDoc(doc(db, logPath), { workingDirectory: "/Users/dev/BurnBar" }, { merge: true })
  );
  await assertFails(
    setDoc(doc(db, logPath), { smuggled: "x" }, { merge: true })
  );
});

// T8 — media_session_events rejects an arbitrary unlisted key (hasOnly).
test("T8 media_session_events denies unlisted keys", async () => {
  const db = authedDb("mse-owner");
  await seedBurnBarProMaxEntitlement("mse-owner");
  const base = {
    id: "evt-1",
    sessionId: "sess-1",
    feature: "screenShare",
    streamClass: "interactive",
    startedAt: "2026-06-02T00:00:00.000Z",
    endedAt: "2026-06-02T00:05:00.000Z",
    endReason: "completed",
    peerDeviceIdHash: "c".repeat(64),
    byteCountInbound: 1024,
    byteCountOutbound: 2048,
    freezeCount: 0,
    p95RoundTripMillisBucket: "50_150ms",
    p95BitsPerSecondBucket: "600kbps_1mbps",
    durationBucket: "2m_10m",
    schemaVersion: 1,
  };

  await assertSucceeds(
    setDoc(doc(db, "users/mse-owner/media_session_events/evt-1"), base)
  );
  await assertFails(
    setDoc(doc(db, "users/mse-owner/media_session_events/evt-2"), {
      ...base,
      id: "evt-2",
      filename: "screen.png",
    })
  );
  await assertFails(
    setDoc(doc(db, "users/mse-owner/media_session_events/evt-3"), {
      ...base,
      id: "evt-3",
      smuggled: "x",
    })
  );
});

// T9 — media_attachment_manifests sealed-filename FLAG-DAY (Fork F = SEAL).
// The sealing iOS writer of record ships clean, so the plaintext `filename`
// branch is hard-dropped: sealedFilename is mandatory; plaintext filename and
// a doc with neither field are both rejected (hermes-gateway-e2e-rearchitecture).
test("T9 media_attachment_manifests require sealedFilename and reject plaintext", async () => {
  const db = authedDb("mam-owner");
  await seedBurnBarProMaxEntitlement("mam-owner");
  const base = {
    blobHash: "b".repeat(64),
    mime: "image/png",
    size: 1234,
    peerDeviceIdHash: "peer-hash",
    direction: "macToIos",
    schemaVersion: 1,
  };

  // Sealed filename is accepted.
  await assertSucceeds(
    setDoc(doc(db, "users/mam-owner/media_attachment_manifests/sealed-1"), {
      ...base,
      id: "sealed-1",
      sealedFilename: sealedText(),
    })
  );
  // FLAG-DAY: a plaintext `filename` is no longer in the allowlist → rejected.
  await assertFails(
    setDoc(doc(db, "users/mam-owner/media_attachment_manifests/legacy-1"), {
      ...base,
      id: "legacy-1",
      filename: "screen.png",
    })
  );
  // A doc carrying neither the sealed nor the cleartext name is rejected
  // (sealedFilename is now mandatory).
  await assertFails(
    setDoc(doc(db, "users/mam-owner/media_attachment_manifests/neither-1"), {
      ...base,
      id: "neither-1",
    })
  );
  // A doc carrying BOTH the sealed and the cleartext name is rejected (the
  // plaintext key is no longer in the hasOnly allowlist).
  await assertFails(
    setDoc(doc(db, "users/mam-owner/media_attachment_manifests/both-1"), {
      ...base,
      id: "both-1",
      sealedFilename: sealedText(),
      filename: "screen.png",
    })
  );
  // An arbitrary unlisted key is rejected by hasOnly.
  await assertFails(
    setDoc(doc(db, "users/mam-owner/media_attachment_manifests/extra-1"), {
      ...base,
      id: "extra-1",
      sealedFilename: sealedText(),
      smuggled: "x",
    })
  );
});

// T10 — mobile mission cancel: the owner phone can cancel its own mission with
// only sealed state fields; a cancel smuggling a plaintext liveSummary is denied.
test("T10 cli_agent_mission_requests accept sealed mobile cancel, deny plaintext", async () => {
  const ownerUid = "cancel-owner";
  const phoneDb = authedDb(ownerUid);
  const requestPath = `users/${ownerUid}/cli_agent_mission_requests/mission-1`;
  await seedCloudVaultState(ownerUid);

  await assertSucceeds(
    setDoc(doc(phoneDb, requestPath), sealedMissionBase("mission-1"))
  );

  // Cancel with only sealed state fields is allowed.
  await assertSucceeds(
    setDoc(
      doc(phoneDb, requestPath),
      sealedMissionStatePatch({
        status: "cancelled",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );

  // A cancel that smuggles a plaintext liveSummary is denied (the field is in
  // the request-level denylist; the cancel predicate also bounds affectedKeys).
  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      {
        status: "cancelled",
        liveSummary: "Mission cancelled by user.",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
});

// T11 — project_memory_snapshots: opaque docID + sealed snapshot accepted,
// plaintext projectDisplayName / projectSlug rejected.
test("T11 project_memory_snapshots seal the name and reject plaintext slug", async () => {
  const ownerUid = "pms-owner";
  const db = authedDb(ownerUid);
  await seedHostedCloudEntitlement(ownerUid);
  const docID = `pm_${"a".repeat(16)}`;
  const snapshotPath = `users/${ownerUid}/project_memory_snapshots/${docID}`;
  const base = {
    docID,
    contentHash: "d".repeat(64),
    contentHashVersion: 2,
    sourceSessionCount: 3,
    sourceConversationCount: 5,
    generatedAt: "2026-06-02T00:00:00.000Z",
    freshness: "fresh",
    visualKinds: ["chart"],
    sealedSnapshot: sealedBlob(),
    encryption: { algorithm: "AES-256-GCM", keyVersion: 1, envelopeSchemaVersion: 2 },
    schemaVersion: 2,
    updatedAt: "2026-06-02T00:00:00.000Z",
  };

  await assertSucceeds(setDoc(doc(db, snapshotPath), base));
  // Plaintext project name fields are denied.
  await assertFails(
    setDoc(doc(db, snapshotPath), { ...base, projectDisplayName: "BurnBar" })
  );
  await assertFails(
    setDoc(doc(db, snapshotPath), { ...base, projectSlug: "burnbar" })
  );
  // Legacy v1 plaintext-keyed rows are fenced out (schemaVersion must be >= 2).
  await assertFails(
    setDoc(doc(db, snapshotPath), { ...base, schemaVersion: 1 })
  );
  await assertFails(
    setDoc(doc(db, snapshotPath), {
      ...base,
      sealedSnapshot: {
        schemaVersion: 2,
        algorithm: "AES-256-GCM",
        keyVersion: 1,
        plaintextSHA256: "e".repeat(64),
        integrityHashVersion: 1,
        sealedBoxBase64: "c2VhbGVkLWJsb2I=",
        createdAt: "2026-06-02T00:00:00.000Z",
        aad: "OpenBurnBar-CloudVault-aad-v2|pms-owner|project_memory_snapshots|pm_aaaaaaaaaaaaaaaa|sealedSnapshot|2|sealedSnapshot",
      },
    })
  );
});

// T12 — usage / budgetRules FAIL CLOSED: a fresh write may never carry a
// cleartext projectName/label. Sealed or nameless creates are accepted; legacy
// plaintext is tolerated only on an update where the field already exists.
test("T12 usage and budgetRules fail closed on plaintext project text", async () => {
  const db = authedDb("usage-owner");

  // A plaintext-only usage CREATE is now DENIED (no vault key → omit the name).
  await assertFails(
    setDoc(doc(db, "users/usage-owner/usage/plaintext-create"), {
      id: "plaintext-create",
      projectName: "BurnBar",
      totalCostUSD: 1.5,
    })
  );
  // A nameless usage row (no-key writer omitted the name) is accepted.
  await assertSucceeds(
    setDoc(doc(db, "users/usage-owner/usage/nameless"), {
      id: "nameless",
      totalCostUSD: 1.5,
    })
  );
  // Sealed usage row is accepted.
  await assertSucceeds(
    setDoc(doc(db, "users/usage-owner/usage/sealed"), {
      id: "sealed",
      sealedProjectName: sealedText(),
      projectKeyHash: "e".repeat(64),
      totalCostUSD: 1.5,
    })
  );
  // A row carrying BOTH sealed + plaintext name is denied.
  await assertFails(
    setDoc(doc(db, "users/usage-owner/usage/both"), {
      id: "both",
      sealedProjectName: sealedText(),
      projectName: "BurnBar",
    })
  );

  // Migration tolerance lives on UPDATE only. Seed a legacy plaintext row with
  // rules disabled, then prove an owner update that PRESERVES the existing
  // plaintext name still syncs, while introducing fresh plaintext is rejected.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "users/usage-owner/usage/legacy-mig"), {
      id: "legacy-mig",
      projectName: "BurnBar",
      totalCostUSD: 1.0,
    });
  });
  await assertSucceeds(
    updateDoc(doc(db, "users/usage-owner/usage/legacy-mig"), { totalCostUSD: 2.0 })
  );
  // Re-introducing a plaintext name onto a sealed row (none existed) is denied.
  await assertFails(
    updateDoc(doc(db, "users/usage-owner/usage/sealed"), { projectName: "BurnBar" })
  );

  // budgetRules: sealed name + label accepted; nameless accepted; any cleartext
  // projectName/label on create denied.
  await assertSucceeds(
    setDoc(doc(db, "users/usage-owner/budgetRules/sealed"), {
      id: "sealed",
      sealedProjectName: sealedText(),
      sealedLabel: sealedText(),
      projectKeyHash: "f".repeat(64),
      limitUSD: 100,
    })
  );
  await assertSucceeds(
    setDoc(doc(db, "users/usage-owner/budgetRules/nameless"), {
      id: "nameless",
      limitUSD: 100,
    })
  );
  await assertFails(
    setDoc(doc(db, "users/usage-owner/budgetRules/plaintext-name"), {
      id: "plaintext-name",
      projectName: "BurnBar",
      limitUSD: 100,
    })
  );
  await assertFails(
    setDoc(doc(db, "users/usage-owner/budgetRules/plaintext-label"), {
      id: "plaintext-label",
      label: "Monthly cap",
      limitUSD: 100,
    })
  );
  await assertFails(
    setDoc(doc(db, "users/usage-owner/budgetRules/leak-name"), {
      id: "leak-name",
      sealedProjectName: sealedText(),
      projectName: "BurnBar",
    })
  );
  await assertFails(
    setDoc(doc(db, "users/usage-owner/budgetRules/leak-label"), {
      id: "leak-label",
      sealedLabel: sealedText(),
      label: "Monthly cap",
    })
  );

  await assertSucceeds(
    setDoc(doc(db, "users/usage-owner/budgetEvents/event-ok"), {
      id: "event-ok",
      ruleID: "sealed",
      kind: "ruleUpdated",
      source: "settings_ui",
      amountAtEvent: 0,
      limitAtEvent: 100,
      occurredAt: serverTimestamp(),
      syncedAt: serverTimestamp(),
      sourceDeviceID: "device-a",
    })
  );
  await assertFails(
    setDoc(doc(db, "users/usage-owner/budgetEvents/event-leak"), {
      id: "event-leak",
      ruleID: "sealed",
      kind: "ruleUpdated",
      source: "settings_ui",
      amountAtEvent: 0,
      limitAtEvent: 100,
      detailJSON: "{\"label\":\"Secret Project\"}",
      occurredAt: serverTimestamp(),
      syncedAt: serverTimestamp(),
    })
  );
});

// T13 — cli_sessions/{id}/snapshots: sealed-only contract (no live writer).
// Sealed action label / touched files / mac path accepted; any plaintext key
// is rejected by the hard-dropped hasOnly allowlist; missing/malformed required
// sealed action label denied.
test("T13 cli_sessions snapshots require sealed action/files/path and reject plaintext", async () => {
  const ownerUid = "snap-owner";
  const db = authedDb(ownerUid);
  const base = {
    id: "snap-1",
    sessionID: "sess-1",
    sequence: 0,
    takenAt: "2026-06-02T00:00:00.000Z",
    schemaVersion: 2,
  };
  const snapshotPath = `users/${ownerUid}/cli_sessions/sess-1/snapshots/snap-1`;

  // Fully sealed snapshot is accepted.
  await assertSucceeds(
    setDoc(doc(db, snapshotPath), {
      ...base,
      sealedActionLabel: sealedText(),
      sealedTouchedFiles: sealedText(),
      sealedMacSnapshotPath: sealedText(),
    })
  );
  // Required action label cannot be omitted on a new snapshot.
  await assertFails(
    setDoc(doc(db, snapshotPath), {
      ...base,
      sealedTouchedFiles: sealedText(),
    })
  );
  // Plaintext action label / touched files / mac path are rejected by hasOnly.
  await assertFails(
    setDoc(doc(db, snapshotPath), {
      ...base,
      sealedActionLabel: sealedText(),
      actionLabel: "Edit src/foo.swift",
    })
  );
  await assertFails(
    setDoc(doc(db, snapshotPath), {
      ...base,
      sealedTouchedFiles: sealedText(),
      touchedFiles: ["/Users/me/file.swift"],
    })
  );
  await assertFails(
    setDoc(doc(db, snapshotPath), {
      ...base,
      sealedMacSnapshotPath: sealedText(),
      macSnapshotPath: "/Users/me/.snapshots/x",
    })
  );
  // Malformed sealed envelope is rejected by validCloudSealedText.
  await assertFails(
    setDoc(doc(db, snapshotPath), {
      ...base,
      sealedActionLabel: { algorithm: "rot13" },
    })
  );
});

// T14 — approval_policies: sealed-only writes; legacy plaintext-only creates
// are rejected by the hard-dropped hasOnly allowlist. Sealed doc with opaque
// hashes accepted; carrying plaintext, bad hash, and unknown keys rejected.
test("T14 approval_policies require sealed label/glob/project and reject plaintext", async () => {
  const ownerUid = "ap-owner";
  const db = authedDb(ownerUid);

  // Legacy plaintext-only policy is no longer accepted for new client writes.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/legacy`), {
      id: "legacy",
      decision: "approve",
      displayLabel: "Edits in BurnBar",
      fileGlob: "src/**",
      targetProject: "/Users/me/BurnBar",
    })
  );
  // Sealed policy (opaque doc ID + v2 AAD-bound sealed fields + 32-hex trapdoors) accepted.
  const policyID = `ap_${"a".repeat(32)}`;
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/${policyID}`), {
      decision: "approve",
      sealedDisplayLabel: sealedTextAt(ownerUid, "approval_policies", policyID, "sealedDisplayLabel"),
      sealedFileGlob: sealedTextAt(ownerUid, "approval_policies", policyID, "sealedFileGlob"),
      sealedTargetProject: sealedTextAt(ownerUid, "approval_policies", policyID, "sealedTargetProject"),
      projectKeyHash: "a".repeat(32),
      fileGlobHash: "b".repeat(32),
      schemaVersion: 2,
    })
  );
  // v2 AAD is mandatory and must bind to this exact document and field.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/wrong-aad`), {
      decision: "approve",
      sealedDisplayLabel: sealedTextAt(ownerUid, "approval_policies", "different-doc", "sealedDisplayLabel"),
      schemaVersion: 2,
    })
  );
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/v1-envelope`), {
      decision: "approve",
      sealedDisplayLabel: sealedText(),
      schemaVersion: 1,
    })
  );
  // A doc carrying BOTH sealed + plaintext is denied (each private field).
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/leak-label`), {
      decision: "approve",
      sealedDisplayLabel: sealedTextAt(ownerUid, "approval_policies", "leak-label", "sealedDisplayLabel"),
      displayLabel: "Edits in BurnBar",
      schemaVersion: 2,
    })
  );
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/leak-glob`), {
      decision: "approve",
      sealedDisplayLabel: sealedTextAt(ownerUid, "approval_policies", "leak-glob", "sealedDisplayLabel"),
      sealedFileGlob: sealedTextAt(ownerUid, "approval_policies", "leak-glob", "sealedFileGlob"),
      fileGlob: "src/**",
      schemaVersion: 2,
    })
  );
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/leak-project`), {
      decision: "approve",
      sealedDisplayLabel: sealedTextAt(ownerUid, "approval_policies", "leak-project", "sealedDisplayLabel"),
      sealedTargetProject: sealedTextAt(ownerUid, "approval_policies", "leak-project", "sealedTargetProject"),
      targetProject: "/Users/me/BurnBar",
      schemaVersion: 2,
    })
  );
  // A non-hex projectKeyHash is rejected.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/bad-hash`), {
      decision: "approve",
      sealedDisplayLabel: sealedTextAt(ownerUid, "approval_policies", "bad-hash", "sealedDisplayLabel"),
      sealedTargetProject: sealedTextAt(ownerUid, "approval_policies", "bad-hash", "sealedTargetProject"),
      projectKeyHash: "NOTHEX",
      schemaVersion: 2,
    })
  );
  // An unknown extra key is rejected by hasOnly.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/smuggle`), {
      decision: "approve",
      sealedDisplayLabel: sealedTextAt(ownerUid, "approval_policies", "smuggle", "sealedDisplayLabel"),
      notes: "hi",
      schemaVersion: 2,
    })
  );
});

// T15 — rollback_requests: sealed-only writes; legacy plaintext scope is
// rejected for new client writes. Sealed scope + error accepted; carrying
// plaintext is rejected.
test("T15 rollback_requests require sealed scope/error and reject plaintext", async () => {
  const ownerUid = "rr-owner";
  const db = authedDb(ownerUid);

  // Legacy plaintext-only request is no longer accepted for new client writes.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/rollback_requests/legacy`), {
      id: "legacy",
      sessionID: "sess-1",
      scopeJSON: '{"kind":"singleFile","path":"/Users/me/file.swift"}',
      status: "pending",
    })
  );
  // Sealed scope + sealed error message accepted.
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/rollback_requests/sealed`), {
      id: "sealed",
      sessionID: "sess-1",
      sealedScope: sealedText(),
      sealedErrorMessage: sealedText(),
      status: "failed",
    })
  );
  // A request carrying BOTH sealed + plaintext scope is denied.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/rollback_requests/leak-scope`), {
      id: "leak-scope",
      sessionID: "sess-1",
      sealedScope: sealedText(),
      scopeJSON: '{"kind":"fullSession"}',
      status: "pending",
    })
  );
  // A request carrying BOTH sealed + plaintext error is denied.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/rollback_requests/leak-error`), {
      id: "leak-error",
      sessionID: "sess-1",
      sealedScope: sealedText(),
      sealedErrorMessage: sealedText(),
      errorMessage: "boom",
      status: "failed",
    })
  );

  // Snake_case status tokens — including the newly-added terminal `cancelled`
  // and the active `in_flight` — are accepted by the allowlist
  // (hermes-gateway-e2e-rearchitecture rollback-status).
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/rollback_requests/active`), {
      id: "active",
      sessionID: "sess-1",
      sealedScope: sealedText(),
      status: "in_flight",
    })
  );
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/rollback_requests/cancelled`), {
      id: "cancelled",
      sessionID: "sess-1",
      sealedScope: sealedText(),
      status: "cancelled",
    })
  );
  // A legacy camelCase `inFlight` status is NOT in the wire allowlist — new
  // writes must use snake_case; only read decoders tolerate the legacy alias.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/rollback_requests/legacy-status`), {
      id: "legacy-status",
      sessionID: "sess-1",
      sealedScope: sealedText(),
      status: "inFlight",
    })
  );
});

// T16 — agent_identities: forward-declared sealed contract (no live writer).
// Sealed identity accepted; any plaintext free-text rejected outright; an
// arbitrary unlisted key rejected by hasOnly; malformed sealed denied.
test("T16 agent_identities hasOnly rejects arbitrary key and plaintext, accepts sealed", async () => {
  const ownerUid = "ai-owner";
  const db = authedDb(ownerUid);

  // Sealed identity (no plaintext free-text) accepted.
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/agent_identities/x`), {
      id: "x",
      runtimeID: "claude",
      glyph: "✦",
      paletteHex: "#112233",
      tier: "service",
      availability: "online",
      sealedDisplayName: sealedText(),
      sealedTagline: sealedText(),
      sealedPersonas: sealedText(),
    })
  );
  // Plaintext displayName / tagline / personas are rejected outright.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/agent_identities/leak-name`), {
      id: "leak-name",
      runtimeID: "claude",
      sealedDisplayName: sealedText(),
      displayName: "My Claude",
    })
  );
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/agent_identities/leak-tagline`), {
      id: "leak-tagline",
      runtimeID: "claude",
      sealedTagline: sealedText(),
      tagline: "Reads private repos",
    })
  );
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/agent_identities/leak-personas`), {
      id: "leak-personas",
      runtimeID: "claude",
      sealedPersonas: sealedText(),
      personas: [{ id: "p1", name: "Default" }],
    })
  );
  // An arbitrary unlisted key is rejected by hasOnly.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/agent_identities/smuggle`), {
      id: "smuggle",
      runtimeID: "claude",
      sealedDisplayName: sealedText(),
      notes: "hi",
    })
  );
  // A malformed sealed envelope is rejected by validCloudSealedText.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/agent_identities/bad-sealed`), {
      id: "bad-sealed",
      runtimeID: "claude",
      sealedDisplayName: { algorithm: "rot13" },
    })
  );
});

// T17 — subscription_topics: sealed graph + display text required; legacy
// plaintext-only creates rejected; both sealed + plaintext rejected; arbitrary
// key rejected.
test("T17 subscription_topics require sealed graph/display text and reject plaintext", async () => {
  const ownerUid = "st-owner";
  const db = authedDb(ownerUid);

  // Sealed-only topic accepted.
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/sealed`), {
      sealedAgentURI: sealedText(),
      sealedTopicID: sealedText(),
      sealedDisplayName: sealedText(),
      sealedDescription: sealedText(),
      cadence: "daily",
    })
  );
  // Partial updates still pass against an already-sealed document because rules
  // evaluate request.resource.data as the post-update document.
  await assertSucceeds(
    updateDoc(doc(db, `users/${ownerUid}/subscription_topics/sealed`), {
      deliveryMode: "muted",
      isMuted: true,
    })
  );
  // Legacy plaintext-only topic is no longer accepted for new client writes.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/legacy`), {
      agentURI: "agent://burnbar/research-scout",
      topicID: "agent-updates",
      displayName: "Research Scout updates",
      description: "Daily research digest.",
      cadence: "daily",
    })
  );
  // A topic carrying BOTH sealed + plaintext displayName is denied.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/leak-name`), {
      sealedAgentURI: sealedText(),
      sealedTopicID: sealedText(),
      sealedDisplayName: sealedText(),
      sealedDescription: sealedText(),
      displayName: "Research Scout updates",
    })
  );
  // A topic carrying BOTH sealed + plaintext description is denied.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/leak-desc`), {
      sealedAgentURI: sealedText(),
      sealedTopicID: sealedText(),
      sealedDisplayName: sealedText(),
      sealedDescription: sealedText(),
      description: "Daily research digest.",
    })
  );
  // A topic carrying BOTH sealed + plaintext graph edge is denied.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/leak-agent`), {
      agentURI: "agent://burnbar/research-scout",
      sealedAgentURI: sealedText(),
      sealedTopicID: sealedText(),
      sealedDisplayName: sealedText(),
      sealedDescription: sealedText(),
    })
  );
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/leak-topic`), {
      topicID: "agent-updates",
      sealedAgentURI: sealedText(),
      sealedTopicID: sealedText(),
      sealedDisplayName: sealedText(),
      sealedDescription: sealedText(),
    })
  );
  // An arbitrary unlisted key is rejected by hasOnly.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/smuggle`), {
      sealedAgentURI: sealedText(),
      sealedTopicID: sealedText(),
      sealedDisplayName: sealedText(),
      sealedDescription: sealedText(),
      foo: "bar",
    })
  );
});

// T18 — knowledge_repos: opaque keyed repoMatchToken + canonical
// sourceManifestId + sealed name accepted; every cleartext/deprecated repo
// identity (repoFullName / sourcePath / sourceSlug / sourceSlugToken) rejected;
// non-opaque tokens + smuggled keys rejected; cross-user denied.
// knowledge_sync_manifests is server-only (allow write: if false) and
// owner-read. (L40 — the connectKnowledgeRepo callable now persists the
// canonical opaque sourceManifestId instead of the transitional sourceSlugToken
// or reversible cleartext slug; these rules tests pin the on-disk contract.)
test("T18 knowledge_repos accept opaque tokens, reject cleartext repo identity + cross-user", async () => {
  const ownerUid = "kr-owner";
  const otherUid = "kr-intruder";
  const db = authedDb(ownerUid);
  const intruder = authedDb(otherUid);
  const repoId = "a".repeat(64); // doc id is the opaque repoMatchToken (64 hex)
  const repoPath = `users/${ownerUid}/knowledge_repos/${repoId}`;
  const base = {
    uid: ownerUid,
    repoId,
    repoMatchToken: "a".repeat(64),
    sourceManifestId: "b".repeat(64),
    sealedRepoFullName: sealedText(),
    installId: "inst-123",
    connectedAt: serverTimestamp(),
    schemaVersion: 1,
  };

  // Opaque-only shape (keyed match token + manifest token + sealed name) accepted.
  await assertSucceeds(setDoc(doc(db, repoPath), base));
  // Owner can read its own row.
  await assertSucceeds(getDoc(doc(db, repoPath)));

  // Every cleartext repo-identity field is rejected by the allowlist + ban.
  await assertFails(setDoc(doc(db, repoPath), { ...base, repoFullName: "owner/secret-repo" }));
  await assertFails(setDoc(doc(db, repoPath), { ...base, sourcePath: "/Users/me/secret" }));
  // The §4 residual: the reversible repo-name-derived slug must never be stored.
  await assertFails(setDoc(doc(db, repoPath), { ...base, sourceSlug: "repo-owner-secret-repo" }));
  // The transitional Stream-7 name is also rejected on new client writes; L40's
  // canonical field is sourceManifestId. Legacy rows are dual-read by callables.
  await assertFails(setDoc(doc(db, repoPath), { ...base, sourceSlugToken: "b".repeat(64) }));

  // Opaque tokens must be 64-hex; a non-hex / wrong-shape token is rejected.
  await assertFails(setDoc(doc(db, repoPath), { ...base, repoMatchToken: "not-a-hex-token" }));
  await assertFails(setDoc(doc(db, repoPath), { ...base, sourceManifestId: "repo-owner-secret-repo" }));
  await assertFails(setDoc(doc(db, repoPath), { ...base, sourceManifestId: "c".repeat(63) }));

  // A malformed sealed name is rejected by validCloudSealedText.
  await assertFails(
    setDoc(doc(db, repoPath), { ...base, sealedRepoFullName: { algorithm: "AES-256-GCM" } })
  );
  // An arbitrary unlisted key is rejected by keys().hasOnly([...]).
  await assertFails(setDoc(doc(db, repoPath), { ...base, foo: "bar" }));

  // Cross-user read + write are denied.
  await assertFails(getDoc(doc(intruder, repoPath)));
  await assertFails(setDoc(doc(intruder, repoPath), base));

  // knowledge_sync_manifests is a SERVER-ONLY writer (allow write: if false):
  // a direct client write is denied even with a well-formed payload...
  const manifestPath = `users/${ownerUid}/knowledge_sync_manifests/${"b".repeat(64)}`;
  await assertFails(
    setDoc(doc(db, manifestPath), {
      uid: ownerUid,
      needsResync: true,
      chunkCount: 0,
      byteCount: 0,
      schemaVersion: 1,
    })
  );
  // ...but the owner CAN read a server-seeded manifest (UI sync-health surface).
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), manifestPath), {
      uid: ownerUid,
      sourceManifestId: "b".repeat(64),
      needsResync: true,
      chunkCount: 12,
      byteCount: 3456,
      lastSyncAt: Timestamp.fromDate(new Date("2026-06-03T00:00:00.000Z")),
      schemaVersion: 1,
    });
  });
  await assertSucceeds(getDoc(doc(db, manifestPath)));
  // A cross-user read of another member's manifest is denied.
  await assertFails(getDoc(doc(intruder, manifestPath)));
});

test("rules test environment is isolated", () => {
  assert.ok(testEnv.projectId.startsWith("openburnbar-rules-"));
});
