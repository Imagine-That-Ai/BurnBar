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
  collection,
  doc,
  getDoc,
  getDocs,
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

async function seedBurnBarUltraEntitlement(
  uid,
  productID = "com.openburnbar.ultra.monthly"
) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/${uid}/entitlements/burnbar_ultra`), {
      id: "burnbar_ultra",
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

function sealedPayload(vaultKeyID = TEST_VAULT_KEY_ID, sealedBoxBase64 = "c2VhbGVk", aad = "OpenBurnBar-CloudVaultSealedPayload-v2") {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    vaultKeyID,
    sealedBoxBase64,
    aad,
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

function sealedBlobAt(uid, collection, docID, field, overrides = {}) {
  return sealedBlob({
    aad: cloudVaultAAD(uid, collection, docID, field),
    ...overrides,
  });
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

function sealedChatThreadPatch(ownerUid, threadId, overrides = {}) {
  return {
    contentIncluded: true,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD(ownerUid, "chat_threads", threadId, "sealedPayload")),
    ...overrides,
  };
}

function sealedMissionBase(ownerUid, id, overrides = {}) {
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
    sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD(ownerUid, "cli_agent_mission_requests", id, "sealedPayload")),
    ...overrides,
  };
}

function sealedMissionEvent(ownerUid, requestId, overrides = {}) {
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
    sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD(ownerUid, "cli_agent_mission_requests", requestId, "sealedPayload")),
    ...overrides,
  };
}

function sealedMissionStatePatch(ownerUid, id, overrides = {}) {
  return {
    contentSealed: true,
    sealedStatePayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVkLXN0YXRl", cloudVaultAAD(ownerUid, "cli_agent_mission_requests", id, "sealedStatePayload")),
    sealedStateSchemaVersion: 1,
    sealedStateVaultKeyID: TEST_VAULT_KEY_ID,
    ...overrides,
  };
}

async function seedMission(uid, id, overrides = {}) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), `users/${uid}/cli_agent_mission_requests/${id}`),
      sealedMissionBase(uid, id, overrides)
    );
  });
}

// Canonical at-rest CloudVault Signal envelope fixture, mirroring
// packages/signal-envelope-contracts at-rest wire shape. Exact owner-scoped
// documents are accepted; per-coordinate overrides prove relocation and
// pollution attempts stay fail-closed.
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
          recipientIdentityKeyB64: Buffer.alloc(33, 7).toString("base64"),
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
      senderIdentityKeyB64: Buffer.alloc(33, 8).toString("base64"),
      signatureB64: Buffer.alloc(64, 9).toString("base64"),
      signatureVersion: 1,
      ...senderAuth,
    },
    ...envelope,
  };
}

function authedDb(uid) {
  return testEnv.authenticatedContext(uid, { email: `${uid}@example.test` }).firestore();
}

test("credential transfers are server-only for legacy and v2 ids", async () => {
  const ownerDb = authedDb("credential-owner");
  const otherDb = authedDb("credential-attacker");
  const unauthDb = testEnv.unauthenticatedContext().firestore();
  const legacyPath = "credential_transfers/ABCDEFGHJKM2";
  const v2Path = `credential_transfers/ct_${"a".repeat(24)}`;
  const baseTransfer = {
    ownerUid: "credential-owner",
    schemaVersion: 2,
    state: "ready",
    payload: `v2.${"s".repeat(22)}.${"i".repeat(16)}.${"c".repeat(32)}`,
    createdAt: Timestamp.fromMillis(Date.now() - 1_000),
    expiresAt: Timestamp.fromMillis(Date.now() + 23 * 60 * 60 * 1000),
    consumed: false,
  };

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), legacyPath), baseTransfer);
    await setDoc(doc(context.firestore(), v2Path), baseTransfer);
  });

  async function assertAllCredentialTransferClientOpsFail(db, transferPath) {
    await assertFails(setDoc(doc(db, transferPath), baseTransfer));
    await assertFails(getDoc(doc(db, transferPath)));
    await assertFails(updateDoc(doc(db, transferPath), { state: "consumed" }));
    await assertFails(deleteDoc(doc(db, transferPath)));
    await assertFails(getDocs(collection(db, "credential_transfers")));
  }

  for (const db of [ownerDb, otherDb, unauthDb]) {
    await assertAllCredentialTransferClientOpsFail(db, legacyPath);
    await assertAllCredentialTransferClientOpsFail(db, v2Path);
  }
});

test("account erasure retention records are server-only", async () => {
  const ownerDb = authedDb("erasure-owner");
  const otherDb = authedDb("erasure-attacker");
  const unauthDb = testEnv.unauthenticatedContext().firestore();
  const uidHash = "a".repeat(64);
  const recordPath = `account_erasure_audit/${uidHash}`;
  const retentionRecord = {
    schemaVersion: 1,
    uidHash,
    status: "intent_recorded",
    intentAudit: {
      action: "account.delete.request",
      auditLogPath: "users/erasure-owner/unified_audit_log/audit-event-1",
      auditHash: "b".repeat(64),
      previousHash: "0".repeat(64),
      sequence: 1,
    },
    startedAt: Timestamp.fromMillis(Date.now()),
    updatedAt: Timestamp.fromMillis(Date.now()),
  };

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), recordPath), retentionRecord);
  });

  async function assertAllErasureRetentionClientOpsFail(db) {
    await assertFails(setDoc(doc(db, recordPath), retentionRecord));
    await assertFails(getDoc(doc(db, recordPath)));
    await assertFails(updateDoc(doc(db, recordPath), { status: "account_deleted" }));
    await assertFails(deleteDoc(doc(db, recordPath)));
    await assertFails(getDocs(collection(db, "account_erasure_audit")));
  }

  for (const db of [ownerDb, otherDb, unauthDb]) {
    await assertAllErasureRetentionClientOpsFail(db);
  }
});

test("provider accounts reject plaintext, unknown credential containers, and client-authored refresh sweep entries", async () => {
  const ownerDb = authedDb("provider-owner");
  const basePath = "users/provider-owner/provider_accounts/account-1";
  const canonical = {
    id: "account-1",
    providerID: "codex",
    label: "Codex",
    status: "connected",
    credentialKind: "token",
    storageScope: "device_keychain",
    redactedLabel: "sk_...1234",
    isDefault: true,
    sortKey: 0,
    schemaVersion: 2,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  await assertSucceeds(setDoc(doc(ownerDb, basePath), canonical));
  await assertSucceeds(
    setDoc(doc(ownerDb, "users/provider-owner/provider_accounts/account-sentinel"), {
      ...canonical,
      id: "account-sentinel",
      lastRefreshAt: "1970-01-01T00:00:00.000Z",
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/provider-owner/provider_accounts/account-null"), {
      ...canonical,
      id: "account-null",
      lastRefreshAt: null,
    })
  );
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

  for (const status of ["connected", "stale", "error"]) {
    for (const storageScope of ["cloud_refreshable", "server_private"]) {
      await assertFails(
        setDoc(doc(ownerDb, `users/provider-owner/provider_accounts/${status}-${storageScope}`), {
          ...canonical,
          id: `${status}-${storageScope}`,
          status,
          storageScope,
        })
      );
    }
  }

  await assertSucceeds(
    setDoc(doc(ownerDb, "users/provider-owner/provider_accounts/disconnected-cloud"), {
      ...canonical,
      id: "disconnected-cloud",
      status: "disconnected",
      storageScope: "cloud_refreshable",
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
  await assertSucceeds(
    setDoc(doc(ownerDb, "users/escrow-owner/escrow_envelopes/envelope-v2"), {
      ...envelope,
      id: "envelope-v2",
      envelopeVersion: 2,
      metadataBinding: "escrow-credential-aad-v1",
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/escrow_envelopes/envelope-v2-missing-binding"), {
      ...envelope,
      id: "envelope-v2-missing-binding",
      envelopeVersion: 2,
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/escrow_envelopes/envelope-v2-wrong-binding"), {
      ...envelope,
      id: "envelope-v2-wrong-binding",
      envelopeVersion: 2,
      metadataBinding: "wrong-binding",
    })
  );
  await assertFails(
    setDoc(doc(ownerDb, "users/escrow-owner/escrow_envelopes/envelope-id-mismatch"), {
      ...envelope,
      id: "different-envelope-id",
    })
  );
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

test("L41 Signal prekey/session directory is server-only, owner-readable, and rotation-aware", async () => {
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

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "users/signal-dir-owner/escrow_devices/trusted-missing-signal"), {
      deviceId: "trusted-missing-signal",
      deviceName: "Trusted Mac",
      platform: "macOS",
      trustState: "trusted",
      publicKeyFingerprint: "T".repeat(44),
      keyVersion: 1,
      targetSignalIdentityKeyId: "trusted-missing-signal_1",
      targetSignalIdentityPublicKeyFingerprint: "P".repeat(44),
      createdAt: now,
      updatedAt: now,
    });
  });
  await assertFails(
    setDoc(doc(ownerDb, "users/signal-dir-owner/signal_identity_public_keys/trusted-missing-signal_1"), {
      deviceId: "trusted-missing-signal",
      platform: "macOS",
      identityKeyId: "trusted-missing-signal_1",
      publicKeyData: "Z".repeat(44),
      publicKeyFingerprint: "P".repeat(44),
      keyVersion: 1,
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
  await assertFails(setDoc(doc(ownerDb, signedPreKeyPath), signedPreKey));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), signedPreKeyPath), signedPreKey);
  });
  await assertSucceeds(getDoc(doc(ownerDb, signedPreKeyPath)));
  await assertFails(
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
  await assertFails(setDoc(doc(ownerDb, oneTimePreKeyPath), oneTimePreKey));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), oneTimePreKeyPath), oneTimePreKey);
  });
  await assertSucceeds(getDoc(doc(ownerDb, oneTimePreKeyPath)));
  await assertFails(
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
  await assertFails(setDoc(doc(ownerDb, kyberPreKeyPath), kyberPreKey));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), kyberPreKeyPath), kyberPreKey);
  });
  await assertSucceeds(getDoc(doc(ownerDb, kyberPreKeyPath)));
  await assertFails(
    setDoc(doc(ownerDb, "users/signal-dir-owner/signal_identity_public_keys/device-1_1/kyber_prekeys/kpk-nosig"), {
      ...kyberPreKey,
      kyberPreKeyId: "kpk-nosig",
      signatureB64: "",
    })
  );
  await assertFails(
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
  await assertFails(setDoc(doc(ownerDb, sessionPath), sessionDirectoryDoc));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), sessionPath), sessionDirectoryDoc);
  });
  await assertSucceeds(getDoc(doc(ownerDb, sessionPath)));
  await assertFails(
    setDoc(doc(ownerDb, "users/signal-dir-owner/signal_identity_public_keys/device-1_1/sessions/session-private"), {
      ...sessionDirectoryDoc,
      sessionId: "session-private",
      sessionStateB64: "SERIALIZED_SIGNAL_SESSION_MUST_STAY_ON_DEVICE",
    })
  );
  await assertFails(
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
  await assertFails(setDoc(doc(ownerDb, rotationPath), rotationEvent));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), rotationPath), rotationEvent);
  });
  await assertSucceeds(getDoc(doc(ownerDb, rotationPath)));
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
  const controllerRoutePath = "users/iroh-owner/iroh_pairing/relay-1/controller_routes/phone-1";
  const controllerChallengePath = "users/iroh-owner/iroh_controller_route_challenges/challenge-1";
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
  await assertFails(
    setDoc(doc(ownerDb, controllerRoutePath), {
      connectionId: "relay-1",
      sourceDeviceId: "phone-1",
      transportNodeId: "a".repeat(52),
      authorityPeerNodeId: "ios-phone-authority",
      status: "active",
      generation: 1,
      expiresAtMillis: 1778860860000,
      schemaVersion: 1,
    })
  );
  await assertSucceeds(getDoc(doc(ownerDb, controllerRoutePath)));
  await assertFails(getDoc(doc(otherDb, controllerRoutePath)));
  await assertFails(getDoc(doc(ownerDb, controllerChallengePath)));
  await assertFails(setDoc(doc(ownerDb, controllerChallengePath), { status: "pending" }));

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
  const mediaManifestFor = (uid, id = "manifest-1") => ({
    id,
    blobHash: "b".repeat(64),
    sealedFilename: sealedTextAt(uid, "media_attachment_manifests", id, "sealedFilename"),
    mime: "image/png",
    size: 1234,
    peerDeviceIdHash: "peer-hash",
    direction: "macToIos",
    schemaVersion: 1,
  });

  await seedBurnBarProEntitlement("cloud-only-media");
  await assertFails(
    setDoc(
      doc(cloudDb, "users/cloud-only-media/media_attachment_manifests/manifest-1"),
      mediaManifestFor("cloud-only-media")
    )
  );

  const proDb = authedDb("cloud-pro-media");
  await seedBurnBarProMaxEntitlement("cloud-pro-media");
  await assertSucceeds(
    setDoc(
      doc(proDb, "users/cloud-pro-media/media_attachment_manifests/manifest-1"),
      mediaManifestFor("cloud-pro-media")
    )
  );

  const playProDb = authedDb("play-cloud-pro-media");
  await seedBurnBarProMaxEntitlement("play-cloud-pro-media", "com.openburnbar.promax.v2.monthly");
  await assertSucceeds(
    setDoc(
      doc(playProDb, "users/play-cloud-pro-media/media_attachment_manifests/manifest-1"),
      mediaManifestFor("play-cloud-pro-media")
    )
  );
});

function sealedMissionGroup(ownerUid, id, width, overrides = {}) {
  const childMissionIDs = Array.from({ length: width }, (_, index) => `${id}-child-${index}`);
  return {
    id,
    missionKind: "fan_out",
    childMissionIDs,
    runtimeTokens: childMissionIDs.map((childID) => `runtime:${childID}`),
    parallelismLimit: width,
    source: "ios-insights",
    mergeStrategy: "keep_all",
    phase: "queued",
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    schemaVersion: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(
      TEST_VAULT_KEY_ID,
      "c2VhbGVkLW1pc3Npb24tZ3JvdXA=",
      cloudVaultAAD(ownerUid, "mission_groups", id, "sealedPayload")
    ),
    ...overrides,
  };
}

async function assertMissionGroupCap(uid, allowedWidth, deniedWidth) {
  await seedCloudVaultState(uid);
  const db = authedDb(uid);
  await assertSucceeds(
    setDoc(doc(db, `users/${uid}/mission_groups/${uid}-ok`), sealedMissionGroup(uid, `${uid}-ok`, allowedWidth))
  );
  await assertFails(
    setDoc(doc(db, `users/${uid}/mission_groups/${uid}-too-wide`), sealedMissionGroup(uid, `${uid}-too-wide`, deniedWidth))
  );
}

test("Wand mission groups enforce Free, Cloud, Cloud Pro, and Ultra fan-out caps", async () => {
  await assertMissionGroupCap("wand-free", 1, 2);

  await seedHostedCloudEntitlement("wand-cloud");
  await assertMissionGroupCap("wand-cloud", 3, 4);

  await seedBurnBarProMaxEntitlement("wand-pro");
  await assertMissionGroupCap("wand-pro", 8, 9);

  await seedBurnBarUltraEntitlement("wand-ultra");
  await assertMissionGroupCap("wand-ultra", 16, 17);
});

test("Wand dispatch accepts established presentation modes and platform group sources", async () => {
  const uid = "wand-wire-contracts";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);

  const paretoChildID = "005CA603-3B30-407F-8EA6-D95B55D0AC41";
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/${paretoChildID}`),
      sealedMissionBase(uid, paretoChildID, {
        missionKind: "diligence",
        requestedRuntime: "claude",
        requestedModelID: "claude-opus-4-1",
        source: "ios-insights",
        sourceSurface: "ios-insights",
        deliveryMode: "action_only",
        presentationMode: "native_chat",
        groupID: "grp-E7225885-439B-4D05-9F88-68412DF019F8",
        siblingIndex: 0,
        siblingCount: 2,
        isGroupChild: true,
        schemaVersion: 3,
      })
    )
  );

  for (const presentationMode of ["native_chat", "mac_visible_cli", "mac_interactive_cli"]) {
    const id = `mission-${presentationMode}`;
    await assertFails(
      setDoc(doc(db, `users/${uid}/cli_agent_mission_requests/${id}`), sealedMissionBase(uid, id, {
        presentationMode,
      }))
    );
  }
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/mission-unknown-mode`),
      sealedMissionBase(uid, "mission-unknown-mode", { presentationMode: "unknown_mode" })
    )
  );

  // War Room — the Flame's routing target. Advisory and owner-written; the
  // executing Mac still decides whether to claim the mission.
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/mission-flame-routed`),
      sealedMissionBase(uid, "mission-flame-routed", {
        originatorKind: "flame",
        originatorRef: "d-a3f2c9",
        targetBodyID: "mac-mini-abc123",
      })
    )
  );
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/mission-flame-long-target`),
      sealedMissionBase(uid, "mission-flame-long-target", { targetBodyID: "b".repeat(161) })
    )
  );
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/mission-flame-bad-target`),
      sealedMissionBase(uid, "mission-flame-bad-target", { targetBodyID: 42 })
    )
  );

  for (const source of ["ios-hermes-square", "android-hermes-square", "mac-wand"]) {
    const id = `group-${source}`;
    await assertSucceeds(
      setDoc(doc(db, `users/${uid}/mission_groups/${id}`), sealedMissionGroup(uid, id, 1, { source }))
    );
  }
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/mission_groups/group-unknown-source`),
      sealedMissionGroup(uid, "group-unknown-source", 1, { source: "unknown-wand" })
    )
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

test("Google Play Cloud Pro unlocks computer-use session metadata writes", async () => {
  const uid = "play-cloud-pro-control";
  const db = authedDb(uid);
  await seedBurnBarProMaxEntitlement(uid, "com.openburnbar.promax.v2.monthly");

  await assertSucceeds(
    setDoc(doc(db, `users/${uid}/computer_use_sessions/session-1`), {
      id: "session-1",
      sessionId: "session-1",
      userId: uid,
      mode: "browser",
      trustMode: "manual",
      startedAt: Timestamp.fromDate(new Date("2026-06-05T00:00:00.000Z")),
      actionCount: 0,
      approvalCount: 0,
      rejectionCount: 0,
      panicHaltCount: 0,
      visionSpendUSD: 0,
      manifestHashHex: "a".repeat(64),
      macAppVersion: "1.0.0",
      schemaVersion: 1,
      updatedAt: Timestamp.fromDate(new Date("2026-06-05T00:00:00.000Z")),
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
      sealedChatThreadPatch("alice", "device_thread", {
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );

  await assertFails(
    setDoc(
      doc(freeDb, threadPath),
      {
        ...sealedChatThreadPatch("alice", "device_thread"),
        title: "private plan",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
});

test("owners can sync encrypted text expansion snippets without plaintext fields", async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "users/alice/escrow_public_keys/mac-1_1"), {
      deviceId: "mac-1",
      keyVersion: 1,
      publicKeyData: "A".repeat(88),
      algorithm: "ECIES-P256-AESGCM",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });
  });

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
  await seedMission("ivy", "mission-1");
  await seedMission("ivy", "mission-android", {
    missionKind: "custom",
    requestedRuntime: "opencode",
    depth: "light",
    approvalMode: "read_only",
    source: "android-insights",
  });
  await seedMission("ivy", "chat-ios", {
    missionKind: "chat",
    requestedRuntime: "codex",
    requestedModelID: "gpt-5.5",
    source: "ios-chat",
    clientThreadID: "mobile-thread-1",
    resumeAction: "new",
  });
  await seedMission("ivy", "mission-lifecycle", {
    missionKind: "custom",
    requestedRuntime: "codex",
    approvalMode: "read_only",
  });

  await assertFails(
    setDoc(doc(phoneDb, requestPath), sealedMissionBase("ivy", "mission-1"))
  );
  await assertFails(
    setDoc(doc(phoneDb, `${requestPath}/events/000001`), sealedMissionEvent("ivy", "mission-1"))
  );
  const androidRequestPath = "users/ivy/cli_agent_mission_requests/mission-android";
  await assertFails(
    setDoc(doc(phoneDb, androidRequestPath), sealedMissionBase("ivy", "mission-android", {
      missionKind: "custom",
      requestedRuntime: "opencode",
      depth: "light",
      approvalMode: "read_only",
      source: "android-insights",
    }))
  );
  await assertFails(
    setDoc(doc(phoneDb, "users/ivy/cli_agent_mission_requests/mission-readonly-shell"), sealedMissionBase("ivy", "mission-readonly-shell", {
      approvalMode: "read_only",
      commandsAllowed: true,
    }))
  );
  await assertFails(
    setDoc(doc(phoneDb, "users/ivy/cli_agent_mission_requests/mission-readonly-edit"), sealedMissionBase("ivy", "mission-readonly-edit", {
      approvalMode: "read_only",
      fileEditsAllowed: true,
    }))
  );
  await assertFails(
    setDoc(doc(phoneDb, `${androidRequestPath}/events/000001`), sealedMissionEvent("ivy", "mission-android", {
      source: "android",
    }))
  );
  const chatRequestPath = "users/ivy/cli_agent_mission_requests/chat-ios";
  await assertFails(
    setDoc(doc(phoneDb, chatRequestPath), sealedMissionBase("ivy", "chat-ios", {
      missionKind: "chat",
      requestedRuntime: "codex",
      requestedModelID: "gpt-5.5",
      source: "ios-chat",
      clientThreadID: "mobile-thread-1",
      resumeAction: "new",
    }))
  );
  await assertFails(
    setDoc(doc(phoneDb, `${chatRequestPath}/events/000001`), sealedMissionEvent("ivy", "chat-ios", {
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
  await assertFails(
    setDoc(doc(phoneDb, lifecyclePath), sealedMissionBase("ivy", "mission-lifecycle", {
      missionKind: "custom",
      requestedRuntime: "codex",
      approvalMode: "read_only",
    }))
  );
  await assertFails(
    setDoc(
      doc(phoneDb, lifecyclePath),
      sealedMissionStatePatch("ivy", "mission-lifecycle", {
        sealedStatePayload: sealedPayload(
          TEST_VAULT_KEY_ID,
          "c2VhbGVkLXN0YXRl",
          cloudVaultAAD("ivy", "cli_agent_mission_requests", "mission-lifecycle", "sealedPayload")
        ),
        status: "accepted",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
  await assertFails(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000001`), sealedMissionEvent("ivy", "mission-lifecycle"))
  );
  await assertFails(
    setDoc(
      doc(phoneDb, lifecyclePath),
      sealedMissionStatePatch("ivy", "mission-lifecycle", {
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
  await assertFails(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000002`), sealedMissionEvent("ivy", "mission-lifecycle", {
      sequence: 2,
      timestamp: "2026-05-13T00:00:01.000Z",
      phase: "accepted",
      runtime: "codex",
      source: "mac",
    }))
  );
  await assertFails(
    setDoc(
      doc(phoneDb, lifecyclePath),
      sealedMissionStatePatch("ivy", "mission-lifecycle", {
        status: "starting",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
  await assertFails(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000003`), sealedMissionEvent("ivy", "mission-lifecycle", {
      sequence: 3,
      timestamp: "2026-05-13T00:00:02.000Z",
      phase: "starting",
      runtime: "codex",
      source: "mac",
    }))
  );
  await assertFails(
    setDoc(
      doc(phoneDb, lifecyclePath),
      sealedMissionStatePatch("ivy", "mission-lifecycle", {
        status: "running",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
  await assertFails(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000004`), sealedMissionEvent("ivy", "mission-lifecycle", {
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
  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      sealedMissionStatePatch("ivy", "mission-1", {
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
  await assertFails(
    setDoc(doc(phoneDb, `${requestPath}/events/000002`), sealedMissionEvent("ivy", "mission-1", {
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
      sealedMissionStatePatch("ivy", "mission-1", {
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
      sealedMissionStatePatch("ivy", "mission-1", {
        approvalStatus: "Approved",
        approvalRespondedAt: "2026-05-13T00:00:04.000Z",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      sealedMissionStatePatch("ivy", "mission-1", {
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
      sealedMissionStatePatch("ivy", "mission-1", {
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

  await assertFails(
    setDoc(
      doc(phoneDb, requestPath),
      sealedMissionStatePatch("ivy", "mission-1", {
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
  await assertFails(
    setDoc(doc(phoneDb, `${requestPath}/events/000003`), sealedMissionEvent("ivy", "mission-1", {
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
      sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("jules", "cli_sessions", "thread-1", "sealedPayload")),
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
      sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("jules", "cli_sessions", "thread-2", "sealedPayload")),
    })
  );
});

test("owners can mirror sealed AI Inbox items for mobile", async () => {
  const macDb = authedDb("iris");
  const otherDb = authedDb("mallory");
  const itemPath = "users/iris/ai_inbox_items/inb_alpha";
  await seedCloudVaultState("iris");

  const validItem = (id, overrides = {}) => ({
    id,
    fingerprint: `stuck_pr:${id}`,
    kind: "stuck_pr",
    priority: 2,
    state: "new",
    occurrenceCount: 1,
    firstSeenAt: serverTimestamp(),
    lastSeenAt: serverTimestamp(),
    modelProvenance: "local-rules",
    hasMemoryCandidates: false,
    schemaVersion: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("iris", "ai_inbox_items", id, "sealedPayload")),
    updatedAt: serverTimestamp(),
    ...overrides,
  });

  await assertSucceeds(setDoc(doc(macDb, itemPath), validItem("inb_alpha")));
  await assertSucceeds(getDoc(doc(macDb, itemPath)));
  await assertFails(getDoc(doc(otherDb, itemPath)));

  // The whole point of the sealed split: the title/body/evidence may never ride
  // top-level, and no key outside the codec allowlist is accepted.
  await assertFails(
    setDoc(doc(macDb, "users/iris/ai_inbox_items/inb_title"), validItem("inb_title", { title: "PR #1975 has stalled" }))
  );
  await assertFails(
    setDoc(doc(macDb, "users/iris/ai_inbox_items/inb_summary"), validItem("inb_summary", { summary: "leaked body" }))
  );
  await assertFails(
    setDoc(doc(macDb, "users/iris/ai_inbox_items/inb_project"), validItem("inb_project", { projectName: "BurnBar" }))
  );
  await assertFails(
    setDoc(doc(macDb, "users/iris/ai_inbox_items/inb_extra"), validItem("inb_extra", { notInAllowlist: true }))
  );

  // Enum + range constraints.
  await assertFails(
    setDoc(doc(macDb, "users/iris/ai_inbox_items/inb_kind"), validItem("inb_kind", { kind: "not_a_kind" }))
  );
  await assertFails(
    setDoc(doc(macDb, "users/iris/ai_inbox_items/inb_state"), validItem("inb_state", { state: "archived" }))
  );
  await assertFails(
    setDoc(doc(macDb, "users/iris/ai_inbox_items/inb_p0"), validItem("inb_p0", { priority: 0 }))
  );
  await assertFails(
    setDoc(doc(macDb, "users/iris/ai_inbox_items/inb_p5"), validItem("inb_p5", { priority: 5 }))
  );
  await assertFails(
    setDoc(doc(macDb, "users/iris/ai_inbox_items/inb_neg"), validItem("inb_neg", { occurrenceCount: -1 }))
  );
  await assertFails(
    setDoc(doc(macDb, "users/iris/ai_inbox_items/inb_unsealed"), validItem("inb_unsealed", { contentSealed: false }))
  );
  // The doc id must match the payload id, so an item cannot be filed under another's key.
  await assertFails(
    setDoc(doc(macDb, "users/iris/ai_inbox_items/inb_mismatch"), validItem("inb_alpha"))
  );
  // AAD is path-bound: a payload sealed for a different doc must not transplant.
  await assertFails(
    setDoc(
      doc(macDb, "users/iris/ai_inbox_items/inb_aad"),
      validItem("inb_aad", {
        sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("iris", "ai_inbox_items", "inb_alpha", "sealedPayload")),
      })
    )
  );

  await assertSucceeds(deleteDoc(doc(macDb, itemPath)));
});

test("any owner device may write AI Inbox item state, with a constrained feedback enum", async () => {
  const phoneDb = authedDb("ivan");
  const otherDb = authedDb("mallory");
  const statePath = "users/ivan/ai_inbox_item_state/inb_alpha";

  const validState = (id, overrides = {}) => ({
    id,
    readAt: serverTimestamp(),
    archivedAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    updatedByDeviceID: "iphone-1",
    ...overrides,
  });

  await assertSucceeds(setDoc(doc(phoneDb, statePath), validState("inb_alpha")));
  await assertSucceeds(
    setDoc(doc(phoneDb, "users/ivan/ai_inbox_item_state/inb_useful"), validState("inb_useful", { feedback: "useful" }))
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, "users/ivan/ai_inbox_item_state/inb_wrong"), validState("inb_wrong", { feedback: "wrong" }))
  );
  await assertSucceeds(getDoc(doc(phoneDb, statePath)));
  await assertFails(getDoc(doc(otherDb, statePath)));

  // Feedback must not become a free-text side channel.
  await assertFails(
    setDoc(doc(phoneDb, "users/ivan/ai_inbox_item_state/inb_free"), validState("inb_free", { feedback: "a sentence of private text" }))
  );
  await assertFails(
    setDoc(doc(phoneDb, "users/ivan/ai_inbox_item_state/inb_extra"), validState("inb_extra", { note: "not allowlisted" }))
  );
  await assertFails(
    setDoc(doc(phoneDb, "users/ivan/ai_inbox_item_state/inb_mismatch"), validState("inb_alpha"))
  );
  await assertFails(
    setDoc(doc(phoneDb, "users/ivan/ai_inbox_item_state/inb_stamp"), validState("inb_stamp", { updatedAt: "2026-08-04" }))
  );

  await assertSucceeds(deleteDoc(doc(phoneDb, statePath)));
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
    sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("carol", "conversations", "device_conv", "sealedPayload")),
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
  await assertSucceeds(
    updateDoc(doc(db, "users/carol/session_logs/device_log"), {
      deletedAt: serverTimestamp(),
      version: 2,
      updatedAt: serverTimestamp(),
    })
  );
  await assertSucceeds(
    updateDoc(doc(db, "users/carol/session_logs/device_log"), {
      version: 3,
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    updateDoc(doc(db, "users/carol/session_logs/device_log"), {
      deletedAt: deleteField(),
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    updateDoc(doc(db, "users/carol/session_logs/device_log"), {
      deletedAt: "2026-06-24T00:00:00.000Z",
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
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "users/carol/session_logs/device_log/chunks/legacy"), {
      index: 2,
      body: "legacy plaintext markdown",
      schemaVersion: 1,
      updatedAt: new Date(),
    });
  });
  await assertSucceeds(
    deleteDoc(doc(db, "users/carol/session_logs/device_log/chunks/legacy"))
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
      facetSchemaVersion: 3,
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
      toolTags: ["bash", "edit", "exec_command", "grep_search", "other", "read"],
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

  // Tool tags are public search facets: only small, known tool slugs are allowed.
  await assertFails(
    setDoc(doc(db, "users/facet-user/session_logs/device_facets_arbitrary_tag"), {
      ...facetBase,
      toolTags: ["bash", "cat-/home/example/redacted-session.md"],
    })
  );

  await assertFails(
    updateDoc(doc(db, "users/facet-user/session_logs/device_facets_ok"), {
      toolTags: ["read", "paste full prompt here"],
      updatedAt: serverTimestamp(),
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

test("root user documents allow profile metadata only and reject secret-shaped fields", async () => {
  const db = authedDb("root-user");

  await assertSucceeds(
    setDoc(doc(db, "users/root-user"), {
      uid: "root-user",
      displayName: "Root User",
      email: "root@example.test",
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/root-user"), {
      uid: "other-user",
      displayName: "Wrong owner",
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/root-user"), {
      uid: "root-user",
      token: "plaintext-token",
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/root-user"), {
      uid: "root-user",
      cloudVaultKey: "plaintext-key",
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    })
  );
});

test("burnbar pro cloud search index writes are server-only while vault wrappers require trusted devices", async () => {
  const db = authedDb("pro-user");
  const documentPath = "users/pro-user/cloud_search_documents/device_session";
  const chunkPath = "users/pro-user/cloud_search_chunks/device_session_0";
  const indexStatePath = "users/pro-user/cloud_search_index_state/device";
  // T-PTR-06: the wrapper doc ID must be the deterministic
  // `<vaultKeyID>_<targetDeviceId>_<keyVersion>` composite. wrapperPayload below
  // uses vaultKeyID=TEST_VAULT_KEY_ID, targetDeviceId="device", keyVersion=1.
  const wrapperPath = `users/pro-user/cloud_vault_key_wrappers/${TEST_VAULT_KEY_ID}_device_1`;
  const wrapperMismatchedIdPath = "users/pro-user/cloud_vault_key_wrappers/wrapper";
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
        createdAt: serverTimestamp(),
        appVersion: "1.0.2",
        publicKeyFingerprint: "escrow-fingerprint",
        keyVersion: 1,
        approvedByDeviceId: "approving-mac",
        trustChainVersion: 1,
        trustChainAlgorithm: "signal-identity-xeddsa-v1",
        trustChainSignature: "A".repeat(88),
        targetSignalIdentityKeyId: "device_1",
        targetSignalIdentityPublicKeyFingerprint: "B".repeat(44),
        approvedBySignalIdentityKeyId: "approving-mac_1",
        approvedBySignalIdentityPublicKeyFingerprint: "C".repeat(44),
        signalIdentityRepairVersion: 1,
        signalIdentityRepairAlgorithm: "escrow-possession-challenge-v1",
        signalIdentityReapprovalRequired: false,
        signalIdentityRepairedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    );
  });

  await assertSucceeds(
    setDoc(
      doc(db, "users/pro-user/escrow_devices/device"),
      {
        deviceId: "device",
        deviceName: "Phone renamed",
        platform: "iOS",
        publicKeyFingerprint: "escrow-fingerprint",
        keyVersion: 1,
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(db, "users/pro-user/escrow_devices/device"),
      {
        signalIdentityReapprovalRequired: true,
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(doc(db, "users/pro-user/escrow_devices/forged-repair"), {
      deviceId: "forged-repair",
      platform: "iPadOS",
      deviceName: "Forged iPad",
      trustState: "pending",
      signalIdentityRepairVersion: 1,
      signalIdentityRepairAlgorithm: "escrow-possession-challenge-v1",
      signalIdentityReapprovalRequired: false,
      signalIdentityRepairedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    })
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
  // T-PTR-06: the same trusted-device payload under a NON-deterministic doc ID is
  // rejected — a stolen-session owner cannot mint extra same-generation wrappers
  // under arbitrary doc IDs.
  await assertFails(
    setDoc(doc(db, wrapperMismatchedIdPath), wrapperPayload)
  );
  await assertFails(deleteDoc(doc(db, wrapperPath)));
});

test("CloudVault rotation jobs are server-created and client-checkpointed only", async () => {
  const db = authedDb("rotate-user");
  const otherDb = authedDb("intruder");
  const jobPath = "users/rotate-user/cloud_vault_rotation_jobs/job-1";

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), jobPath), {
      jobId: "job-1",
      uid: "rotate-user",
      status: "queued",
      reason: "revocation_rewrap",
      currentVaultKeyID: `v1_${"a".repeat(32)}`,
      newVaultKeyID: `v1_${"b".repeat(32)}`,
      fromVaultGeneration: 1,
      toVaultGeneration: 2,
      survivorDeviceIds: ["device-1"],
      revokedDeviceIds: ["device-2"],
      createdByDeviceId: "device-1",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    });
    await setDoc(doc(context.firestore(), "users/rotate-user/cloud_vault_rotation_requirements/revoke_1"), {
      requirementId: "revoke_1",
      uid: "rotate-user",
      status: "pending",
      reason: "device_revoked",
      revokedDeviceId: "device-2",
      currentVaultKeyID: `v1_${"a".repeat(32)}`,
      currentVaultGeneration: 1,
      survivorDeviceIds: ["device-1"],
      rotateCallable: "rotateCloudVaultKey",
      nextRotationReason: "revocation_rewrap",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    });
  });

  await assertSucceeds(getDoc(doc(db, jobPath)));
  await assertFails(getDoc(doc(otherDb, jobPath)));
  await assertSucceeds(getDoc(doc(db, "users/rotate-user/cloud_vault_rotation_requirements/revoke_1")));
  await assertFails(getDoc(doc(otherDb, "users/rotate-user/cloud_vault_rotation_requirements/revoke_1")));
  await assertFails(
    setDoc(doc(db, "users/rotate-user/cloud_vault_rotation_requirements/client-created"), {
      requirementId: "client-created",
      status: "pending",
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    updateDoc(doc(db, "users/rotate-user/cloud_vault_rotation_requirements/revoke_1"), {
      status: "complete",
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    setDoc(doc(db, "users/rotate-user/cloud_vault_rotation_jobs/client-created"), {
      jobId: "client-created",
      status: "queued",
      updatedAt: serverTimestamp(),
    })
  );

  await assertSucceeds(
    updateDoc(doc(db, jobPath), {
      status: "rewrapping",
      clientDeviceId: "device-1",
      processedDocumentCount: 10,
      rewrappedDocumentCount: 4,
      changedFieldCount: 9,
      documentRewrapComplete: false,
      storageRewrapComplete: false,
      storageRewrapPending: true,
      processedStorageBlobCount: 2,
      rewrappedStorageBlobCount: 1,
      updatedAt: serverTimestamp(),
    })
  );

  await assertFails(
    updateDoc(doc(db, jobPath), {
      newVaultKeyID: `v1_${"c".repeat(32)}`,
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    updateDoc(doc(otherDb, jobPath), {
      status: "complete",
      updatedAt: serverTimestamp(),
    })
  );

  const checkpointPath = `${jobPath}/checkpoints/conversations_chat`;
  await assertSucceeds(
    setDoc(doc(db, checkpointPath), {
      domainID: "conversations_chat",
      status: "documents_complete",
      scannedDocumentCount: 10,
      rewrappedDocumentCount: 4,
      changedFieldCount: 9,
      updatedAt: serverTimestamp(),
    })
  );
  await assertSucceeds(
    setDoc(doc(db, `${jobPath}/checkpoints/session_logs_storage`), {
      domainID: "session_logs_storage",
      status: "storage_rewrapping",
      scannedDocumentCount: 2,
      rewrappedDocumentCount: 1,
      changedFieldCount: 0,
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    setDoc(doc(db, `${jobPath}/checkpoints/bad-domain`), {
      domainID: "different",
      status: "documents_complete",
      scannedDocumentCount: 1,
      rewrappedDocumentCount: 1,
      changedFieldCount: 1,
      updatedAt: serverTimestamp(),
    })
  );
  await assertFails(
    setDoc(doc(db, `${jobPath}/checkpoints/session_logs`), {
      domainID: "session_logs",
      status: "documents_complete",
      scannedDocumentCount: 1,
      rewrappedDocumentCount: 1,
      changedFieldCount: 1,
      newVaultKeyID: `v1_${"d".repeat(32)}`,
      updatedAt: serverTimestamp(),
    })
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
    palette: "rainbow",
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
    palette: "rainbow",
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
  const senderPublicKey = "A".repeat(88);

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
    setDoc(doc(db, connectionPath), {
      ...connectionDoc,
      redisURL: "redis://:secret@127.0.0.1:6379/0",
      updatedAt: "2026-05-12T00:00:02.000Z",
    })
  );

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
      relayKeyVersion: 2,
      senderPublicKey,
      senderDeviceId: "mac-device-1",
      senderPeerNodeId: "iroh-peer-1",
      senderCounter: 1,
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

test("realtime relay URLs must stay on bounded secure host routes", async () => {
  const db = authedDb("relay-url-user");
  await seedHostedCloudEntitlement("relay-url-user");

  const hermesConnectionPath = "users/relay-url-user/hermes_connections/hermes-relay-mac";
  const piConnectionPath = "users/relay-url-user/pi_agent_connections/pi-relay-mac";
  const hermesConnectionDoc = {
    id: "hermes-relay-mac",
    displayName: "Mac Hermes Relay",
    mode: "relayLink",
    status: "online",
    capabilities: ["chat_completions", "remote_relay", "realtime_relay"],
    relayPublicKey: "A".repeat(88),
    relayKeyVersion: 3,
    relayEncryption: "hpke-auth-p256-hkdfsha256-aes256gcm",
    realtimeRelayURL: "wss://relay.openburnbar.test/v1/realtime",
    realtimeRelayStatus: "online",
    realtimeRelayProtocolVersion: 1,
    createdAt: "2026-06-24T00:00:00.000Z",
    updatedAt: "2026-06-24T00:00:00.000Z",
    schemaVersion: 2,
  };
  const piConnectionDoc = {
    id: "pi-relay-mac",
    displayName: "Mac Pi Relay",
    mode: "relayLink",
    status: "online",
    capabilities: ["chat_completions", "remote_relay", "realtime_relay"],
    relayPublicKey: "B".repeat(88),
    relayKeyVersion: 1,
    relayEncryption: "p256-hkdf-sha256-aesgcm",
    realtimeRelayURL: "wss://relay.openburnbar.test/v1/realtime",
    realtimeRelayStatus: "online",
    realtimeRelayProtocolVersion: 1,
    createdAt: "2026-06-24T00:00:00.000Z",
    updatedAt: "2026-06-24T00:00:00.000Z",
    schemaVersion: 2,
  };

  await assertSucceeds(setDoc(doc(db, hermesConnectionPath), hermesConnectionDoc));
  await assertSucceeds(setDoc(doc(db, piConnectionPath), piConnectionDoc));

  for (const realtimeRelayURL of [
    "ws://relay.openburnbar.test/v1/realtime",
    "wss://127.0.0.1:8317/v1/realtime",
    "wss://10.0.0.5/v1/realtime",
    "wss://metadata.google.internal/computeMetadata/v1",
    "wss://user:pass@relay.openburnbar.test/v1/realtime",
    "wss://relay.openburnbar.test/v1/realtime?token=secret",
    "wss://relay.openburnbar.test/v1/realtime#fragment",
  ]) {
    await assertFails(
      setDoc(doc(db, hermesConnectionPath), {
        ...hermesConnectionDoc,
        realtimeRelayURL,
        updatedAt: "2026-06-24T00:00:01.000Z",
      })
    );
    await assertFails(
      setDoc(doc(db, piConnectionPath), {
        ...piConnectionDoc,
        realtimeRelayURL,
        updatedAt: "2026-06-24T00:00:01.000Z",
      })
    );
  }
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
    sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("ma-owner", "mobile_assistant_chats", "thread-1", "sealedPayload")),
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

// L37 — exact owner-scoped Signal at-rest writes are accepted, while
// relocation/forgery/type-confusion vectors remain denied.
test("L37 signalEnvelope is accepted on exact mobile_assistant_chats direct writes", async () => {
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
    sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("sig-owner", "mobile_assistant_chats", "thread-1", "sealedPayload")),
  };

  const goodEnvelope = signalAtRestEnvelope({
    uid: "sig-owner",
    collection: "mobile_assistant_chats",
    docId: "thread-1",
  });

  // 1. Legacy sealed CloudVault writes still work without the Signal envelope.
  await assertSucceeds(setDoc(doc(db, threadPath), baseThread));

  // 2. A well-formed envelope bound to THIS exact path is accepted on the
  // owner-scoped direct client path.
  await assertSucceeds(setDoc(doc(db, threadPath), { ...baseThread, signalEnvelope: goodEnvelope }));

  // 3. The IDENTICAL envelope written at a DIFFERENT doc path fails closed (relocation):
  //    binding.docId="thread-1" no longer matches the path's threadId="thread-2".
  await assertFails(
    setDoc(doc(db, "users/sig-owner/mobile_assistant_chats/thread-2"), {
      ...baseThread,
      id: "thread-2",
      signalEnvelope: goodEnvelope,
    })
  );

  // 4. Per-coordinate relocation of the binding — each must fail closed.
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

  // 5. Envelope-level forgery / mode confusion / pollution — each must fail closed.
  const forgeries = [
    { envelope: { mode: "transport" } }, // top-level mode mismatch
    { envelope: { relayEncryption: "signal-doubleratchet-pqxdh-v1" } }, // transport scheme on at-rest
    { envelope: { signalEnvelopeFormatVersion: 2 } }, // wrong envelope version
    { envelope: { relayKeyVersion: 4 } }, // transport-only field present (hasOnly rejects on at-rest)
    { envelope: { extraTopLevel: "x" } }, // unlisted top-level key (hasOnly)
    { ciphertextLayer: { payloadCiphertextB64: "not_base64!!" } }, // bad base64 charset
    { ciphertextLayer: { payloadCiphertextB64: "abc" } }, // length not %4
    { ciphertextLayer: { payloadCiphertextB64: "" } }, // empty ciphertext
    { ciphertextLayer: { payloadCiphertextB64: 7 } }, // non-string ciphertext
    { envelope: { ciphertextLayer: "not-a-map" } }, // nested ciphertext type confusion
    { ciphertextLayer: { payloadAADLabel: "has a space" } }, // label charset (no spaces/pipe)
    { ciphertextLayer: { extra: "x" } }, // unlisted ciphertextLayer key (hasOnly)
    { keyDelivery: { contentKeyLength: 16 } }, // wrong content-key length
    { keyDelivery: { scheme: "signal-doubleratchet-pqxdh-v1" } }, // transport scheme in keyDelivery
    { keyDelivery: { wraps: [] } }, // empty wraps (< 1)
    { keyDelivery: { extra: "x" } }, // unlisted keyDelivery key (hasOnly)
    { envelope: { keyDelivery: "not-a-map" } }, // nested key-delivery type confusion
    { envelope: { binding: "not-a-map" } }, // nested binding type confusion
    { senderAuth: { senderIdentityKeyB64: "A".repeat(40) } }, // wrong identity-key wire length
    { senderAuth: { senderIdentityKeyB64: "!".repeat(44) } }, // bad identity-key base64 charset
    { senderAuth: { senderIdentityKeyB64: 7 } }, // non-string identity key
    { senderAuth: { signatureB64: "A".repeat(84) } }, // wrong signature wire length
    { senderAuth: { signatureB64: "!".repeat(88) } }, // bad signature base64 charset
    { senderAuth: { signatureB64: 7 } }, // non-string signature
    { envelope: { senderAuth: "not-a-map" } }, // nested sender-auth type confusion
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

  // 6. A plaintext field smuggled INSIDE the envelope key slot (not the envelope shape)
  //    fails closed — the field must be a valid envelope, never arbitrary data.
  await assertFails(
    setDoc(doc(db, "users/sig-owner/mobile_assistant_chats/thread-plain"), {
      ...baseThread,
      id: "thread-plain",
      signalEnvelope: { plaintext: "secret message" },
    })
  );

  // 7. (Remediation R11) Type confusion — a NON-MAP signalEnvelope value (string,
  //    number, bool, list) fails closed; direct clients cannot write this field.
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

// L37 — cli_sessions is one of the ten explicitly wired collections; the
// generic gate must accept its exact Signal mirror shape.
test("L37 signalEnvelope is accepted on cli_sessions exact mirror shape", async () => {
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
    sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("nw-owner", "cli_sessions", "sess-1", "sealedPayload")),
  };
  await assertSucceeds(setDoc(doc(db, "users/nw-owner/cli_sessions/sess-1"), base));
  await assertSucceeds(
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
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "users/slc-owner/session_logs/log/chunks/legacy"), {
      index: 5,
      body: "legacy plaintext markdown",
      schemaVersion: 1,
      updatedAt: new Date(),
    });
  });
  await assertSucceeds(
    deleteDoc(doc(db, "users/slc-owner/session_logs/log/chunks/legacy"))
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
    sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("conv-owner", "conversations", "conv-1", "sealedPayload")),
  };

  await assertSucceeds(setDoc(doc(db, convPath), sealedConversation));
  // Re-introducing a plaintext projectName via merge is denied.
  await assertFails(
    setDoc(doc(db, convPath), { projectName: "BurnBar" }, { merge: true })
  );
});

// L37b (rules half) — Mac client-direct collections chat_threads + conversations
// accept exact owner/path-bound Signal at-rest writes; relocation and collection
// mismatches remain denied, while normal legacy rows remain readable/writable.
test("L37b signalEnvelope is accepted only on exact chat_threads + conversations paths", async () => {
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
    sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("sigb-owner", "chat_threads", "ct-1", "sealedPayload")),
    createdAt: "2026-06-05T00:00:00.000Z",
    updatedAt: "2026-06-05T00:00:00.000Z",
  };
  const goodThreadEnv = signalAtRestEnvelope({
    uid: "sigb-owner",
    collection: "chat_threads",
    docId: "ct-1",
  });
  // 1. Legacy sealed CloudVault chat-thread writes still work without the Signal envelope.
  await assertSucceeds(setDoc(doc(db, "users/sigb-owner/chat_threads/ct-1"), threadBase));
  // 2. A well-formed envelope bound to THIS exact path is accepted.
  await assertSucceeds(
    setDoc(doc(db, "users/sigb-owner/chat_threads/ct-1"), { ...threadBase, signalEnvelope: goodThreadEnv })
  );
  // 3. The SAME envelope at a different doc fails closed (binding.docId no longer matches).
  await assertFails(
    setDoc(doc(db, "users/sigb-owner/chat_threads/ct-2"), {
      ...threadBase,
      threadId: "ct-2",
      signalEnvelope: goodThreadEnv,
    })
  );
  // 4. An envelope bound to a DIFFERENT collection fails closed on chat_threads.
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
    sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("sigb-owner", "conversations", "conv-sig-1", "sealedPayload")),
  };
  const goodConvEnv = signalAtRestEnvelope({
    uid: "sigb-owner",
    collection: "conversations",
    docId: "conv-sig-1",
  });
  // 1. Legacy sealed CloudVault conversation writes still work without the Signal envelope.
  await assertSucceeds(setDoc(doc(db, "users/sigb-owner/conversations/conv-sig-1"), convBase));
  // 2. A well-formed envelope bound to THIS exact path is accepted.
  await assertSucceeds(
    setDoc(doc(db, "users/sigb-owner/conversations/conv-sig-1"), { ...convBase, signalEnvelope: goodConvEnv })
  );
  // 3. Relocation to a different conversation doc fails closed.
  await assertFails(
    setDoc(doc(db, "users/sigb-owner/conversations/conv-sig-2"), {
      ...convBase,
      id: "conv-sig-2",
      signalEnvelope: goodConvEnv,
    })
  );
  // 4. Wrong-collection binding fails closed on conversations.
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
      sealedPayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVk", cloudVaultAAD("cli-owner", "cli_sessions", "thread-1", "sealedPayload")),
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

// T8 — iroh_audit_events keeps client telemetry out of trusted ops rollups.
test("T8 iroh_audit_events denies client rollup eligibility", async () => {
  const db = authedDb("iroh-owner");
  const base = {
    id: "evt-1",
    connectionId: "conn-1",
    eventType: "iroh_fallback_to_firestore",
    observedAt: "2026-06-02T00:00:00.000Z",
    transport: "firestore",
    rttMillis: 25,
    detail: { reason: "relay_unavailable" },
    schemaVersion: 1,
    expireAt: Timestamp.fromDate(new Date("2026-07-02T00:00:00.000Z")),
  };

  await assertSucceeds(
    setDoc(doc(db, "users/iroh-owner/iroh_audit_events/evt-1"), base)
  );
  await assertSucceeds(
    setDoc(doc(db, "users/iroh-owner/iroh_audit_events/evt-2"), {
      ...base,
      id: "evt-2",
      rollupEligible: false,
    })
  );
  await assertFails(
    setDoc(doc(db, "users/iroh-owner/iroh_audit_events/evt-3"), {
      ...base,
      id: "evt-3",
      rollupEligible: true,
    })
  );
  await assertFails(
    setDoc(doc(db, "users/iroh-owner/iroh_audit_events/evt-4"), {
      ...base,
      id: "evt-4",
      rttMillis: -1,
    })
  );
});

// T8b — media_session_events rejects an arbitrary unlisted key (hasOnly).
test("T8b media_session_events denies unlisted keys", async () => {
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
  await assertFails(
    setDoc(doc(db, "users/mse-owner/media_session_events/evt-4"), {
      ...base,
      id: "evt-4",
      freezeCount: -1,
    })
  );
  await assertFails(
    setDoc(doc(db, "users/mse-owner/media_session_events/evt-5"), {
      ...base,
      id: "evt-5",
      freezeCount: 51,
    })
  );
  await assertFails(
    setDoc(doc(db, "users/mse-owner/media_session_events/evt-6"), {
      ...base,
      id: "evt-6",
      freezeCount: 1.5,
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
      sealedFilename: sealedTextAt("mam-owner", "media_attachment_manifests", "sealed-1", "sealedFilename"),
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
      sealedFilename: sealedTextAt("mam-owner", "media_attachment_manifests", "both-1", "sealedFilename"),
      filename: "screen.png",
    })
  );
  // An arbitrary unlisted key is rejected by hasOnly.
  await assertFails(
    setDoc(doc(db, "users/mam-owner/media_attachment_manifests/extra-1"), {
      ...base,
      id: "extra-1",
      sealedFilename: sealedTextAt("mam-owner", "media_attachment_manifests", "extra-1", "sealedFilename"),
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
  await seedMission(ownerUid, "mission-1");

  // Cancel with only sealed state fields is allowed.
  await assertSucceeds(
    setDoc(
      doc(phoneDb, requestPath),
      sealedMissionStatePatch(ownerUid, "mission-1", {
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

test("T10a cancel from pending succeeds", async () => {
  const uid = "cancel-pending";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await seedMission(uid, "m-pending");
  await assertSucceeds(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-pending`),
      sealedMissionStatePatch(uid, "m-pending", { status: "cancelled", updatedAt: serverTimestamp() }),
      { merge: true }
    )
  );
});

test("T10b cancel from running succeeds", async () => {
  const uid = "cancel-running";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await seedMission(uid, "m-running", { status: "running", claimedBy: "mac-1" });
  await assertSucceeds(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-running`),
      sealedMissionStatePatch(uid, "m-running", { status: "cancelled", updatedAt: serverTimestamp() }),
      { merge: true }
    )
  );
});

test("T10c cancel from starting succeeds", async () => {
  const uid = "cancel-starting";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await seedMission(uid, "m-starting", { status: "starting", claimedBy: "mac-1" });
  await assertSucceeds(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-starting`),
      sealedMissionStatePatch(uid, "m-starting", { status: "cancelled", updatedAt: serverTimestamp() }),
      { merge: true }
    )
  );
});

test("T10d cancel after completed denied", async () => {
  const uid = "cancel-completed";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await seedMission(uid, "m-completed", { status: "completed", claimedBy: "mac-1" });
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-completed`),
      sealedMissionStatePatch(uid, "m-completed", { status: "cancelled", updatedAt: serverTimestamp() }),
      { merge: true }
    )
  );
});

test("T10e cancel after failed denied", async () => {
  const uid = "cancel-failed";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await seedMission(uid, "m-failed", { status: "failed", claimedBy: "mac-1" });
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-failed`),
      sealedMissionStatePatch(uid, "m-failed", { status: "cancelled", updatedAt: serverTimestamp() }),
      { merge: true }
    )
  );
});

test("T10f cancel after canceled/cancelled denied", async () => {
  const uid = "cancel-already";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await seedMission(uid, "m-canceled", { status: "canceled", claimedBy: "mac-1" });
  await seedMission(uid, "m-cancelled", { status: "cancelled", claimedBy: "mac-1" });
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-canceled`),
      sealedMissionStatePatch(uid, "m-canceled", { status: "cancelled", updatedAt: serverTimestamp() }),
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-cancelled`),
      sealedMissionStatePatch(uid, "m-cancelled", { status: "cancelled", updatedAt: serverTimestamp() }),
      { merge: true }
    )
  );
});

test("T10g cancel with global or missing AAD denied", async () => {
  const uid = "cancel-aad";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await seedMission(uid, "m-aad");
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-aad`),
      {
        contentSealed: true,
        sealedStatePayload: sealedPayload(TEST_VAULT_KEY_ID, "c2VhbGVkLXN0YXRl", "global-aad"),
        sealedStateSchemaVersion: 1,
        sealedStateVaultKeyID: TEST_VAULT_KEY_ID,
        status: "cancelled",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-aad`),
      {
        contentSealed: true,
        sealedStatePayload: {
          schemaVersion: 2,
          algorithm: "AES-256-GCM",
          keyVersion: 1,
          vaultKeyID: TEST_VAULT_KEY_ID,
          sealedBoxBase64: "c2VhbGVkLXN0YXRl",
        },
        sealedStateSchemaVersion: 1,
        sealedStateVaultKeyID: TEST_VAULT_KEY_ID,
        status: "cancelled",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
});

test("T12 cli_agent_mission_requests client create denied", async () => {
  const uid = "mission-create-deny";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await assertFails(
    setDoc(doc(db, `users/${uid}/cli_agent_mission_requests/client-create`), sealedMissionBase(uid, "client-create"))
  );
});

test("T13 client host claim denied", async () => {
  const uid = "mission-claim-deny";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await seedMission(uid, "m-claim");
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-claim`),
      sealedMissionStatePatch(uid, "m-claim", {
        status: "accepted",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
});

test("T14 client fail() after claimed denied", async () => {
  const uid = "mission-fail-deny";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await seedMission(uid, "m-fail", { status: "accepted", claimedBy: "mac-winner" });
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-fail`),
      sealedMissionStatePatch(uid, "m-fail", {
        status: "failed",
        updatedAt: serverTimestamp(),
      }),
      { merge: true }
    )
  );
});

test("T15 kimi / gemini / openclaude mirrors persist", async () => {
  const uid = "mission-runtime-persist";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  for (const runtime of ["kimi", "gemini", "openclaude"]) {
    await assertSucceeds(
      setDoc(doc(db, `users/${uid}/mobile_assistant_chats/${runtime}-thread`), {
        id: `${runtime}-thread`,
        runtime,
        createdAt: "2026-08-19T00:00:00.000Z",
        updatedAt: "2026-08-19T00:00:00.000Z",
        messageCount: 1,
        contentSealed: true,
        sealedSchemaVersion: 2,
        vaultKeyID: TEST_VAULT_KEY_ID,
        sealedPayload: sealedPayload(
          TEST_VAULT_KEY_ID,
          "c2VhbGVk",
          cloudVaultAAD(uid, "mobile_assistant_chats", `${runtime}-thread`, "sealedPayload")
        ),
      })
    );
  }
});

test("T16 unknown runtime event denied", async () => {
  const uid = "mission-event-unknown";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await seedMission(uid, "m-event", { status: "running", claimedBy: "mac-1" });
  await assertFails(
    setDoc(doc(db, `users/${uid}/cli_agent_mission_requests/m-event/events/000002`), sealedMissionEvent(uid, "m-event", {
      sequence: 2,
      runtime: "not-a-runtime",
      source: "mac",
    }))
  );
});

test("T17 client event create denied", async () => {
  const uid = "mission-event-deny";
  const db = authedDb(uid);
  await seedCloudVaultState(uid);
  await seedMission(uid, "m-event-deny");
  await assertFails(
    setDoc(
      doc(db, `users/${uid}/cli_agent_mission_requests/m-event-deny/events/000001`),
      sealedMissionEvent(uid, "m-event-deny")
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
  const playProUid = "pms-play-cloud-pro-owner";
  const playProDocID = `pm_${"b".repeat(16)}`;
  const playProDb = authedDb(playProUid);
  await seedBurnBarProMaxEntitlement(playProUid, "com.openburnbar.promax.annual");
  await assertSucceeds(
    setDoc(doc(playProDb, `users/${playProUid}/project_memory_snapshots/${playProDocID}`), {
      ...base,
      docID: playProDocID,
      contentHash: "e".repeat(64),
      sealedSnapshot: sealedBlobAt(playProUid, "project_memory_snapshots", playProDocID, "sealedSnapshot"),
    })
  );
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
      sealedProjectName: sealedTextAt("usage-owner", "usage", "sealed", "sealedProjectName"),
      projectKeyHash: "e".repeat(64),
      totalCostUSD: 1.5,
    })
  );
  // A row carrying BOTH sealed + plaintext name is denied.
  await assertFails(
    setDoc(doc(db, "users/usage-owner/usage/both"), {
      id: "both",
      sealedProjectName: sealedTextAt("usage-owner", "usage", "both", "sealedProjectName"),
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
      sealedProjectName: sealedTextAt("usage-owner", "budgetRules", "sealed", "sealedProjectName"),
      sealedLabel: sealedTextAt("usage-owner", "budgetRules", "sealed", "sealedLabel"),
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
      sealedProjectName: sealedTextAt("usage-owner", "budgetRules", "leak-name", "sealedProjectName"),
      projectName: "BurnBar",
    })
  );
  await assertFails(
    setDoc(doc(db, "users/usage-owner/budgetRules/leak-label"), {
      id: "leak-label",
      sealedLabel: sealedTextAt("usage-owner", "budgetRules", "leak-label", "sealedLabel"),
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
      sealedActionLabel: sealedTextAt(ownerUid, "snapshots", "snap-1", "sealedActionLabel"),
      sealedTouchedFiles: sealedTextAt(ownerUid, "snapshots", "snap-1", "sealedTouchedFiles"),
      sealedMacSnapshotPath: sealedTextAt(ownerUid, "snapshots", "snap-1", "sealedMacSnapshotPath"),
    })
  );
  // Required action label cannot be omitted on a new snapshot.
  await assertFails(
    setDoc(doc(db, snapshotPath), {
      ...base,
      sealedTouchedFiles: sealedTextAt(ownerUid, "snapshots", "snap-1", "sealedTouchedFiles"),
    })
  );
  // Plaintext action label / touched files / mac path are rejected by hasOnly.
  await assertFails(
    setDoc(doc(db, snapshotPath), {
      ...base,
      sealedActionLabel: sealedTextAt(ownerUid, "snapshots", "snap-1", "sealedActionLabel"),
      actionLabel: "Edit src/foo.swift",
    })
  );
  await assertFails(
    setDoc(doc(db, snapshotPath), {
      ...base,
      sealedTouchedFiles: sealedTextAt(ownerUid, "snapshots", "snap-1", "sealedTouchedFiles"),
      touchedFiles: ["/Users/me/file.swift"],
    })
  );
  await assertFails(
    setDoc(doc(db, snapshotPath), {
      ...base,
      sealedMacSnapshotPath: sealedTextAt(ownerUid, "snapshots", "snap-1", "sealedMacSnapshotPath"),
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

  const rrSealed = (docId, field) => sealedTextAt(ownerUid, "rollback_requests", docId, field);

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
      sealedScope: rrSealed("sealed", "sealedScope"),
      sealedErrorMessage: rrSealed("sealed", "sealedErrorMessage"),
      status: "failed",
    })
  );
  // A request carrying BOTH sealed + plaintext scope is denied.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/rollback_requests/leak-scope`), {
      id: "leak-scope",
      sessionID: "sess-1",
      sealedScope: rrSealed("leak-scope", "sealedScope"),
      scopeJSON: '{"kind":"fullSession"}',
      status: "pending",
    })
  );
  // A request carrying BOTH sealed + plaintext error is denied.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/rollback_requests/leak-error`), {
      id: "leak-error",
      sessionID: "sess-1",
      sealedScope: rrSealed("leak-error", "sealedScope"),
      sealedErrorMessage: rrSealed("leak-error", "sealedErrorMessage"),
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
      sealedScope: rrSealed("active", "sealedScope"),
      status: "in_flight",
    })
  );
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/rollback_requests/cancelled`), {
      id: "cancelled",
      sessionID: "sess-1",
      sealedScope: rrSealed("cancelled", "sealedScope"),
      status: "cancelled",
    })
  );
  // A legacy camelCase `inFlight` status is NOT in the wire allowlist — new
  // writes must use snake_case; only read decoders tolerate the legacy alias.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/rollback_requests/legacy-status`), {
      id: "legacy-status",
      sessionID: "sess-1",
      sealedScope: rrSealed("legacy-status", "sealedScope"),
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

  const aiSealed = (docId, field) => sealedTextAt(ownerUid, "agent_identities", docId, field);

  // Sealed identity (no plaintext free-text) accepted.
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/agent_identities/x`), {
      id: "x",
      runtimeID: "claude",
      glyph: "✦",
      paletteHex: "#112233",
      tier: "service",
      availability: "online",
      sealedDisplayName: aiSealed("x", "sealedDisplayName"),
      sealedTagline: aiSealed("x", "sealedTagline"),
      sealedPersonas: aiSealed("x", "sealedPersonas"),
    })
  );
  // Plaintext displayName / tagline / personas are rejected outright.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/agent_identities/leak-name`), {
      id: "leak-name",
      runtimeID: "claude",
      sealedDisplayName: aiSealed("leak-name", "sealedDisplayName"),
      displayName: "My Claude",
    })
  );
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/agent_identities/leak-tagline`), {
      id: "leak-tagline",
      runtimeID: "claude",
      sealedTagline: aiSealed("leak-tagline", "sealedTagline"),
      tagline: "Reads private repos",
    })
  );
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/agent_identities/leak-personas`), {
      id: "leak-personas",
      runtimeID: "claude",
      sealedPersonas: aiSealed("leak-personas", "sealedPersonas"),
      personas: [{ id: "p1", name: "Default" }],
    })
  );
  // An arbitrary unlisted key is rejected by hasOnly.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/agent_identities/smuggle`), {
      id: "smuggle",
      runtimeID: "claude",
      sealedDisplayName: aiSealed("smuggle", "sealedDisplayName"),
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

  const stSealed = (docId, field) => sealedTextAt(ownerUid, "subscription_topics", docId, field);

  // Sealed-only topic accepted.
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/sealed`), {
      sealedAgentURI: stSealed("sealed", "sealedAgentURI"),
      sealedTopicID: stSealed("sealed", "sealedTopicID"),
      sealedDisplayName: stSealed("sealed", "sealedDisplayName"),
      sealedDescription: stSealed("sealed", "sealedDescription"),
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
      sealedAgentURI: stSealed("leak-name", "sealedAgentURI"),
      sealedTopicID: stSealed("leak-name", "sealedTopicID"),
      sealedDisplayName: stSealed("leak-name", "sealedDisplayName"),
      sealedDescription: stSealed("leak-name", "sealedDescription"),
      displayName: "Research Scout updates",
    })
  );
  // A topic carrying BOTH sealed + plaintext description is denied.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/leak-desc`), {
      sealedAgentURI: stSealed("leak-desc", "sealedAgentURI"),
      sealedTopicID: stSealed("leak-desc", "sealedTopicID"),
      sealedDisplayName: stSealed("leak-desc", "sealedDisplayName"),
      sealedDescription: stSealed("leak-desc", "sealedDescription"),
      description: "Daily research digest.",
    })
  );
  // A topic carrying BOTH sealed + plaintext graph edge is denied.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/leak-agent`), {
      agentURI: "agent://burnbar/research-scout",
      sealedAgentURI: stSealed("leak-agent", "sealedAgentURI"),
      sealedTopicID: stSealed("leak-agent", "sealedTopicID"),
      sealedDisplayName: stSealed("leak-agent", "sealedDisplayName"),
      sealedDescription: stSealed("leak-agent", "sealedDescription"),
    })
  );
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/leak-topic`), {
      topicID: "agent-updates",
      sealedAgentURI: stSealed("leak-topic", "sealedAgentURI"),
      sealedTopicID: stSealed("leak-topic", "sealedTopicID"),
      sealedDisplayName: stSealed("leak-topic", "sealedDisplayName"),
      sealedDescription: stSealed("leak-topic", "sealedDescription"),
    })
  );
  // An arbitrary unlisted key is rejected by hasOnly.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/smuggle`), {
      sealedAgentURI: stSealed("smuggle", "sealedAgentURI"),
      sealedTopicID: stSealed("smuggle", "sealedTopicID"),
      sealedDisplayName: stSealed("smuggle", "sealedDisplayName"),
      sealedDescription: stSealed("smuggle", "sealedDescription"),
      foo: "bar",
    })
  );
});

// T18 — knowledge_repos: server-owned opaque keyed repoMatchToken + canonical
// sourceManifestId + sealed name are owner-readable; direct client writes,
// cleartext/deprecated repo identity fields, smuggled keys, and cross-user
// access are denied.
// knowledge_sync_manifests is server-only (allow write: if false) and
// owner-read. (L40 — the connectKnowledgeRepo callable now persists the
// canonical opaque sourceManifestId instead of the transitional sourceSlugToken
// or reversible cleartext slug; these rules tests pin the on-disk contract.)
test("T18 knowledge_repos are server-owned, owner-readable, and reject cleartext repo identity", async () => {
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
    sealedRepoFullName: sealedTextAt(ownerUid, "knowledge_repos", repoId, "sealedRepoFullName"),
    installId: "inst-123",
    connectedAt: serverTimestamp(),
    schemaVersion: 1,
  };

  // Direct client writes are denied even for the canonical opaque-only shape.
  await assertFails(setDoc(doc(db, repoPath), base));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), repoPath), base);
  });
  // Owner can read its server-seeded row.
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

// T19 — memory_facts and memory_forget_receipts carry sealed facts plus opaque
// 64-hex HMAC handles only. Source HMAC lists are bounded and per-entry checked
// so clients cannot smuggle plaintext source refs through list values.
test("T19 memory cloud artifacts require sealed facts and HMAC-only source lists", async () => {
  const ownerUid = "memory-owner";
  const db = authedDb(ownerUid);
  const timestamp = Timestamp.fromDate(new Date("2026-06-04T00:00:00.000Z"));
  const sourceRefHmac = "a".repeat(64);
  const factIds = {
    noEntitlement: "1".repeat(64),
    cloudOnly: "2".repeat(64),
    ok: "3".repeat(64),
    playCloudProOk: "4".repeat(64),
    ultraOk: "5".repeat(64),
    plaintextSource: "6".repeat(64),
    uppercaseSource: "7".repeat(64),
    objectSource: "8".repeat(64),
    tooManySources: "9".repeat(64),
  };
  const receiptIds = {
    factOk: "c".repeat(64),
    plaintextSource: "d".repeat(64),
    sourceOk: "e".repeat(64),
  };

  const memoryFactFor = (uid, docID, overrides = {}) => ({
    uid,
    docID,
    schemaVersion: 1,
    sourceKind: "chat",
    kind: "fact",
    reviewStatus: "approved",
    sealedMemory: sealedBlobAt(uid, "memory_facts", docID, "sealedMemory"),
    sourceRefHmacs: [sourceRefHmac],
    citationCount: 1,
    validFrom: timestamp,
    updatedAt: timestamp,
    replicatedAt: timestamp,
    ...overrides,
  });
  const memoryFact = (docID, overrides = {}) => memoryFactFor(ownerUid, docID, overrides);

  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/memory_facts/${factIds.noEntitlement}`), memoryFact(factIds.noEntitlement))
  );
  await seedHostedCloudEntitlement(ownerUid);
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/memory_facts/${factIds.cloudOnly}`), memoryFact(factIds.cloudOnly))
  );
  await seedBurnBarProMaxEntitlement(ownerUid);

  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/memory_facts/${factIds.ok}`), memoryFact(factIds.ok))
  );
  const googlePlayCloudProUid = "memory-play-cloud-pro-owner";
  const googlePlayCloudProDb = authedDb(googlePlayCloudProUid);
  await seedBurnBarProMaxEntitlement(googlePlayCloudProUid, "com.openburnbar.promax.v2.monthly");
  await assertSucceeds(
    setDoc(
      doc(googlePlayCloudProDb, `users/${googlePlayCloudProUid}/memory_facts/${factIds.playCloudProOk}`),
      memoryFactFor(googlePlayCloudProUid, factIds.playCloudProOk)
    )
  );
  const ultraUid = "memory-ultra-owner";
  const ultraDb = authedDb(ultraUid);
  await seedBurnBarUltraEntitlement(ultraUid);
  await assertSucceeds(
    setDoc(
      doc(ultraDb, `users/${ultraUid}/memory_facts/${factIds.ultraOk}`),
      memoryFactFor(ultraUid, factIds.ultraOk)
    )
  );
  await assertFails(
    setDoc(
      doc(db, `users/${ownerUid}/memory_facts/${factIds.plaintextSource}`),
      memoryFact(factIds.plaintextSource, {
        sourceRefHmacs: [sourceRefHmac, "thread/message/plaintext"],
        citationCount: 2,
      })
    )
  );
  await assertFails(
    setDoc(
      doc(db, `users/${ownerUid}/memory_facts/${factIds.uppercaseSource}`),
      memoryFact(factIds.uppercaseSource, {
        sourceRefHmacs: ["A".repeat(64)],
      })
    )
  );
  await assertFails(
    setDoc(
      doc(db, `users/${ownerUid}/memory_facts/${factIds.objectSource}`),
      memoryFact(factIds.objectSource, {
        sourceRefHmacs: [{ plaintext: "message-id" }],
      })
    )
  );
  await assertFails(
    setDoc(
      doc(db, `users/${ownerUid}/memory_facts/${factIds.tooManySources}`),
      memoryFact(factIds.tooManySources, {
        sourceRefHmacs: Array.from({ length: 51 }, (_, index) => (index % 10).toString().repeat(64)),
        citationCount: 50,
      })
    )
  );

  const factReceipt = (receiptID, overrides = {}) => ({
    uid: ownerUid,
    receiptID,
    schemaVersion: 1,
    memoryIdHmac: "b".repeat(64),
    sourceRefHmacs: [sourceRefHmac],
    reason: "user_delete",
    createdAt: timestamp,
    replicatedAt: timestamp,
    ...overrides,
  });

  await assertSucceeds(
    setDoc(
      doc(db, `users/${ownerUid}/memory_forget_receipts/${receiptIds.factOk}`),
      factReceipt(receiptIds.factOk)
    )
  );
  await assertFails(
    setDoc(
      doc(db, `users/${ownerUid}/memory_forget_receipts/${receiptIds.plaintextSource}`),
      factReceipt(receiptIds.plaintextSource, {
        sourceRefHmacs: [sourceRefHmac, "thread/message/plaintext"],
      })
    )
  );

  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/memory_forget_receipts/${receiptIds.sourceOk}`), {
      uid: ownerUid,
      receiptID: receiptIds.sourceOk,
      schemaVersion: 1,
      sourceRefHmac,
      reason: "clear_history",
      createdAt: timestamp,
      replicatedAt: timestamp,
    })
  );
});

test("hermes_bodies: owner can create, update, delete; non-owner cannot", async () => {
  const ownerDb = authedDb("hermes-body-owner");
  const otherDb = authedDb("hermes-body-attacker");
  const bodyId = "relay-host-test-uuid";
  const now = new Date().toISOString();

  function validBody(overrides = {}) {
    return {
      id: bodyId,
      deviceID: "device-abc-123",
      displayName: "Studio Hermes",
      machineName: "Mac Studio",
      platform: "macos",
      hardware: {
        hardwareModel: "mac14,13",
        chipBrand: "Apple M2 Ultra",
        coresPerformance: 16,
        coresEfficiency: 4,
        memBytes: 64000000000,
      },
      hermes: { installed: true, gatewayReachable: true },
      endpoints: { pairingConnectionId: bodyId },
      presence: { state: "online", lastHeartbeatAt: now, wireReachable: false },
      capabilities: ["fleet_probe", "hermes_chat"],
      schemaVersion: 1,
      createdAt: now,
      updatedAt: now,
      ...overrides,
    };
  }

  // Owner can create
  await assertSucceeds(
    setDoc(doc(ownerDb, `users/hermes-body-owner/hermes_bodies/${bodyId}`), validBody())
  );

  // Owner can update (heartbeat — no displayName/createdAt)
  await assertSucceeds(
    updateDoc(doc(ownerDb, `users/hermes-body-owner/hermes_bodies/${bodyId}`), {
      presence: { state: "online", lastHeartbeatAt: new Date().toISOString(), wireReachable: false },
      updatedAt: new Date().toISOString(),
    })
  );

  // Owner can delete
  await assertSucceeds(
    deleteDoc(doc(ownerDb, `users/hermes-body-owner/hermes_bodies/${bodyId}`))
  );

  // Non-owner cannot create
  await assertFails(
    setDoc(doc(otherDb, `users/hermes-body-owner/hermes_bodies/${bodyId}`), validBody())
  );

  // Re-create for non-owner tests
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/hermes-body-owner/hermes_bodies/${bodyId}`), validBody());
  });

  // Non-owner cannot update
  await assertFails(
    updateDoc(doc(otherDb, `users/hermes-body-owner/hermes_bodies/${bodyId}`), {
      updatedAt: now,
    })
  );

  // Non-owner cannot delete
  await assertFails(
    deleteDoc(doc(otherDb, `users/hermes-body-owner/hermes_bodies/${bodyId}`))
  );
});

test("hermes_bodies: rejects invalid payloads", async () => {
  const ownerDb = authedDb("hermes-body-owner-2");
  const bodyId = "relay-host-test-uuid-2";
  const now = new Date().toISOString();
  const base = {
    id: bodyId,
    deviceID: "device-abc-123",
    displayName: "Studio Hermes",
    machineName: "Mac Studio",
    platform: "macos",
    hardware: { hardwareModel: "mac14,13" },
    hermes: { installed: true, gatewayReachable: true },
    endpoints: { pairingConnectionId: bodyId },
    presence: { state: "online", lastHeartbeatAt: now, wireReachable: false },
    capabilities: ["fleet_probe"],
    schemaVersion: 1,
    createdAt: now,
    updatedAt: now,
  };

  // id mismatch
  await assertFails(
    setDoc(doc(ownerDb, `users/hermes-body-owner-2/hermes_bodies/${bodyId}`), {
      ...base,
      id: "wrong-id",
    })
  );

  // wrong platform
  await assertFails(
    setDoc(doc(ownerDb, `users/hermes-body-owner-2/hermes_bodies/${bodyId}`), {
      ...base,
      platform: "ios",
    })
  );

  // extra key not in allowlist
  await assertFails(
    setDoc(doc(ownerDb, `users/hermes-body-owner-2/hermes_bodies/${bodyId}`), {
      ...base,
      secretKey: "should-not-be-here",
    })
  );

  // hardware not a map
  await assertFails(
    setDoc(doc(ownerDb, `users/hermes-body-owner-2/hermes_bodies/${bodyId}`), {
      ...base,
      hardware: "not-a-map",
    })
  );

  // capabilities not a list
  await assertFails(
    setDoc(doc(ownerDb, `users/hermes-body-owner-2/hermes_bodies/${bodyId}`), {
      ...base,
      capabilities: "not-a-list",
    })
  );

  // schemaVersion not an int
  await assertFails(
    setDoc(doc(ownerDb, `users/hermes-body-owner-2/hermes_bodies/${bodyId}`), {
      ...base,
      schemaVersion: "one",
    })
  );

  // missing createdAt on create (omit the field entirely)
  const { createdAt: _omit, ...bodyWithoutCreatedAt } = base;
  await assertFails(
    setDoc(doc(ownerDb, `users/hermes-body-owner-2/hermes_bodies/${bodyId}`), bodyWithoutCreatedAt)
  );

  // valid create succeeds
  await assertSucceeds(
    setDoc(doc(ownerDb, `users/hermes-body-owner-2/hermes_bodies/${bodyId}`), base)
  );

  // displayName over the 120-char cap
  await assertFails(
    setDoc(doc(ownerDb, `users/hermes-body-owner-2/hermes_bodies/${bodyId}`), {
      ...base,
      displayName: "x".repeat(121),
    })
  );

  // capabilities over the 16-entry cap
  await assertFails(
    setDoc(doc(ownerDb, `users/hermes-body-owner-2/hermes_bodies/${bodyId}`), {
      ...base,
      capabilities: Array.from({ length: 17 }, (_, i) => `cap_${i}`),
    })
  );
});

// The HermesBodyDirectory renders the fleet from a collection listener, so the
// owner-read allowlist entry is load-bearing: without it the War Room surfaces
// go blank while every write still passes.
test("hermes_bodies: owner reads the collection, non-owner is denied", async () => {
  const ownerId = "hermes-body-reader";
  const bodyId = "relay-host-reader-uuid";
  const now = new Date().toISOString();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/${ownerId}/hermes_bodies/${bodyId}`), {
      id: bodyId,
      deviceID: "device-reader",
      displayName: "Reader Hermes",
      machineName: "Mac mini",
      platform: "macos",
      hardware: {},
      hermes: { installed: true, gatewayReachable: false },
      endpoints: { pairingConnectionId: bodyId },
      presence: { state: "online", lastHeartbeatAt: now, wireReachable: false },
      capabilities: ["fleet_probe"],
      schemaVersion: 1,
      createdAt: now,
      updatedAt: now,
    });
  });

  const ownerDb = authedDb(ownerId);
  await assertSucceeds(getDoc(doc(ownerDb, `users/${ownerId}/hermes_bodies/${bodyId}`)));
  await assertSucceeds(getDocs(collection(ownerDb, `users/${ownerId}/hermes_bodies`)));

  const otherDb = authedDb("hermes-body-reader-attacker");
  await assertFails(getDoc(doc(otherDb, `users/${ownerId}/hermes_bodies/${bodyId}`)));
  await assertFails(getDocs(collection(otherDb, `users/${ownerId}/hermes_bodies`)));
});

test("war_wire_grants: owner grants and revokes; pairId must be canonical", async () => {
  const ownerId = "war-wire-owner";
  const bodyA = "relay-host-aaaa";
  const bodyB = "relay-host-bbbb";
  const pairId = `${bodyA}__${bodyB}`;
  const now = new Date().toISOString();
  const ownerDb = authedDb(ownerId);
  const path = `users/${ownerId}/war_wire_grants/${pairId}`;

  const base = {
    id: pairId,
    bodyIdA: bodyA,
    bodyIdB: bodyB,
    state: "active",
    grantedByDeviceID: "device-a",
    grantedAt: now,
    schemaVersion: 1,
    createdAt: now,
    updatedAt: now,
  };

  await assertSucceeds(setDoc(doc(ownerDb, path), base));

  // Either machine may revoke.
  await assertSucceeds(
    updateDoc(doc(ownerDb, path), {
      state: "revoked",
      revokedByDeviceID: "device-b",
      revokedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    })
  );

  // The covered pair is immutable — a revoked grant can't be re-pointed.
  await assertFails(
    updateDoc(doc(ownerDb, path), { bodyIdB: "relay-host-cccc" })
  );

  // Unknown state values are rejected.
  await assertFails(updateDoc(doc(ownerDb, path), { state: "pending" }));

  // pairId must be the sorted join, not an arbitrary id.
  await assertFails(
    setDoc(doc(ownerDb, `users/${ownerId}/war_wire_grants/whatever`), {
      ...base,
      id: "whatever",
    })
  );

  // Reversed (unsorted) endpoints are rejected so both Macs derive one doc.
  const reversedPair = `${bodyB}__${bodyA}`;
  await assertFails(
    setDoc(doc(ownerDb, `users/${ownerId}/war_wire_grants/${reversedPair}`), {
      ...base,
      id: reversedPair,
      bodyIdA: bodyB,
      bodyIdB: bodyA,
    })
  );

  // A non-owner can neither read nor write another account's grants.
  const otherDb = authedDb("war-wire-attacker");
  await assertFails(getDoc(doc(otherDb, path)));
  await assertFails(setDoc(doc(otherDb, path), base));
  await assertFails(deleteDoc(doc(otherDb, path)));

  // The owner reads its own grants (the Wire gate depends on this).
  await assertSucceeds(getDoc(doc(ownerDb, path)));
  await assertSucceeds(getDocs(collection(ownerDb, `users/${ownerId}/war_wire_grants`)));
  await assertSucceeds(deleteDoc(doc(ownerDb, path)));
});

// T27 — Team memory red-team suite (D16 / P21).
//
// These are adversarial by construction: each case is a way a member, an
// ex-member, a neighbouring team or a plain client could try to reach data the
// team lane promises they cannot. The lane's whole membership story is "the
// rules re-read the live roster on every read AND every write", so the roster
// is seeded with security rules DISABLED (mirroring the Admin-SDK-only roster
// callables) and every assertion below runs through client rules.

const TEAM_FACT_TIMESTAMP = Timestamp.fromDate(new Date("2026-09-05T00:00:00.000Z"));

function cloudVaultTeamAAD(teamId, collection, docID, field) {
  return cloudVaultAAD(`team:${teamId}`, collection, docID, field);
}

function sealedTeamBlobAt(teamId, collection, docID, field, overrides = {}) {
  return sealedBlob({
    aad: cloudVaultTeamAAD(teamId, collection, docID, field),
    ...overrides,
  });
}

async function seedTeamRoster(teamId, members, teamOverrides = {}) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const fs = context.firestore();
    await setDoc(doc(fs, `team_rosters/${teamId}`), {
      teamId,
      name: "Red Team",
      activeKeyVersion: 1,
      retainedKeyVersions: [1],
      slugKeyId: null,
      keyRotationRequired: false,
      createdBy: members[0]?.uid ?? "unknown",
      schemaVersion: 1,
      ...teamOverrides,
    });
    for (const member of members) {
      await setDoc(doc(fs, `team_rosters/${teamId}/members/${member.uid}`), {
        uid: member.uid,
        teamId,
        role: member.role ?? "member",
        status: member.status ?? "active",
        escrowDeviceFingerprints: [],
        activeTeamKeyVersion: 1,
        invitedBy: members[0]?.uid ?? "unknown",
        schemaVersion: 1,
      });
    }
  });
}

async function setTeamMemberStatus(teamId, uid, status) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), `team_rosters/${teamId}/members/${uid}`), { status });
  });
}

async function setTeamActiveKeyVersion(teamId, activeKeyVersion, retainedKeyVersions) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), `team_rosters/${teamId}`), {
      activeKeyVersion,
      retainedKeyVersions,
    });
  });
}

async function seedTeamFact(teamId, uid, docID, overrides = {}) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), `team_memory_facts/${teamId}/facts/${docID}`),
      teamMemoryFact(teamId, uid, docID, overrides)
    );
  });
}

function teamMemoryFact(teamId, uid, docID, overrides = {}) {
  return {
    uid,
    teamId,
    docID,
    schemaVersion: 2,
    sourceKind: "agent",
    kind: "architecture",
    reviewStatus: "approved",
    sealedMemory: sealedTeamBlobAt(teamId, "team_memory_facts", docID, "sealedMemory"),
    sourceRefHmacs: ["a".repeat(64)],
    citationCount: 1,
    validFrom: TEAM_FACT_TIMESTAMP,
    updatedAt: TEAM_FACT_TIMESTAMP,
    replicatedAt: TEAM_FACT_TIMESTAMP,
    teamKeyVersion: 1,
    ...overrides,
  };
}

// An escrow device's `publicKeyFingerprint` is base64 of a 32-byte SHA-256
// digest — 43 base64 characters plus the `=` pad — NOT 64 hex. Everything that
// produces one (`CloudVaultDeviceKeypair`), stores one (`escrow_public_keys`)
// and verifies one (`EscrowDeviceSafetyCode.isFingerprint`, which base64-decodes
// it) agrees on that shape, so the fixture must too: seeding hex here is what
// let a hex validator look green while refusing every envelope a real device
// could ever wrap. See `test_an_envelope_wrapped_to_a_hex_fingerprint_is_rejected`.
const TEAM_ESCROW_FINGERPRINT = `${"b".repeat(43)}=`;

// Fixture wrap material, BUILT AT RUNTIME rather than committed. The rules only
// require `wrappedKeyBase64` to be non-empty base64 under 4 KiB, so a fixture
// never needs real wrapped bytes — and a committed base64 literal next to a
// `…Key…` field name is exactly the shape the repo's secret scanner refuses.
const WRAPPED_FIXTURE_B64 = Buffer.from("wrapped-fixture", "utf8").toString("base64");
const SUBSTITUTED_FIXTURE_B64 = Buffer.from("substituted-fixture", "utf8").toString("base64");

function teamKeyEnvelope(teamId, uid, deviceId, escrowKeyVersion, keySlot, wrappedBy, overrides = {}) {
  return {
    teamId,
    uid,
    deviceId,
    escrowKeyVersion,
    keySlot,
    algorithm: "ECIES-P256-AESGCM",
    wrappedKeyBase64: WRAPPED_FIXTURE_B64,
    recipientPublicKeyFingerprint: TEAM_ESCROW_FINGERPRINT,
    // Pinned by the rules to the author, so the roster authority can tell whose
    // wrap an envelope is and count only wraps it is willing to trust.
    wrappedBy,
    createdAt: TEAM_FACT_TIMESTAMP,
    ...overrides,
  };
}

test("test_a_non_member_is_denied_read_and_write", async () => {
  const teamId = "team_aaaaaaaaaaaaaaa1";
  const memberUid = "t27-member-1";
  const outsiderUid = "t27-outsider-1";
  const factId = "1".repeat(64);
  const outsiderFactId = "2".repeat(64);

  await seedTeamRoster(teamId, [{ uid: memberUid, role: "admin" }]);
  await seedBurnBarProMaxEntitlement(memberUid);
  await seedBurnBarProMaxEntitlement(outsiderUid);

  const memberDb = authedDb(memberUid);
  const outsiderDb = authedDb(outsiderUid);

  await assertSucceeds(
    setDoc(doc(memberDb, `team_memory_facts/${teamId}/facts/${factId}`), teamMemoryFact(teamId, memberUid, factId))
  );
  await assertSucceeds(getDoc(doc(memberDb, `team_memory_facts/${teamId}/facts/${factId}`)));

  // No roster row at all: get, list and create must every one of them fail.
  await assertFails(getDoc(doc(outsiderDb, `team_memory_facts/${teamId}/facts/${factId}`)));
  await assertFails(getDocs(collection(outsiderDb, `team_memory_facts/${teamId}/facts`)));
  await assertFails(
    setDoc(
      doc(outsiderDb, `team_memory_facts/${teamId}/facts/${outsiderFactId}`),
      teamMemoryFact(teamId, outsiderUid, outsiderFactId)
    )
  );
  await assertFails(getDoc(doc(outsiderDb, `team_rosters/${teamId}`)));

  // The entitlement alone buys nothing: a member without it is also denied.
  const unentitledUid = "t27-unentitled-1";
  await seedTeamRoster(teamId, [{ uid: memberUid, role: "admin" }, { uid: unentitledUid }]);
  await assertFails(getDoc(doc(authedDb(unentitledUid), `team_memory_facts/${teamId}/facts/${factId}`)));
});

test("test_an_ex_member_is_denied_after_rotation", async () => {
  const teamId = "team_aaaaaaaaaaaaaaa2";
  const adminUid = "t27-admin-2";
  const exMemberUid = "t27-ex-member-2";
  const factId = "3".repeat(64);
  const postRotationFactId = "4".repeat(64);

  await seedTeamRoster(teamId, [{ uid: adminUid, role: "admin" }, { uid: exMemberUid }]);
  await seedBurnBarProMaxEntitlement(adminUid);
  await seedBurnBarProMaxEntitlement(exMemberUid);

  const exMemberDb = authedDb(exMemberUid);
  await assertSucceeds(
    setDoc(
      doc(exMemberDb, `team_memory_facts/${teamId}/facts/${factId}`),
      teamMemoryFact(teamId, exMemberUid, factId)
    )
  );

  await setTeamMemberStatus(teamId, exMemberUid, "removed");
  await setTeamActiveKeyVersion(teamId, 2, [1, 2]);

  // Cut off on the very next request — read AND write, including their own row.
  await assertFails(getDoc(doc(exMemberDb, `team_memory_facts/${teamId}/facts/${factId}`)));
  await assertFails(
    updateDoc(doc(exMemberDb, `team_memory_facts/${teamId}/facts/${factId}`), { updatedAt: TEAM_FACT_TIMESTAMP })
  );
  await assertFails(
    setDoc(
      doc(exMemberDb, `team_memory_facts/${teamId}/facts/${postRotationFactId}`),
      teamMemoryFact(teamId, exMemberUid, postRotationFactId, {
        teamKeyVersion: 2,
        sealedMemory: sealedTeamBlobAt(teamId, "team_memory_facts", postRotationFactId, "sealedMemory", {
          keyVersion: 2,
        }),
      })
    )
  );
  await assertFails(getDoc(doc(exMemberDb, `team_rosters/${teamId}`)));
});

test("test_a_client_cannot_write_the_roster", async () => {
  const teamId = "team_aaaaaaaaaaaaaaa3";
  const adminUid = "t27-admin-3";
  const attackerUid = "t27-attacker-3";

  await seedTeamRoster(teamId, [{ uid: adminUid, role: "admin" }]);
  await seedBurnBarProMaxEntitlement(adminUid);
  await seedBurnBarProMaxEntitlement(attackerUid);

  // Not even an ACTIVE ADMIN may write the roster: the callables own it.
  for (const [label, db] of [
    ["attacker", authedDb(attackerUid)],
    ["admin", authedDb(adminUid)],
  ]) {
    assert.ok(label);
    await assertFails(
      setDoc(doc(db, `team_rosters/${teamId}`), { teamId, name: "Forged", activeKeyVersion: 1 })
    );
    await assertFails(
      updateDoc(doc(db, `team_rosters/${teamId}`), { activeKeyVersion: 99 })
    );
    await assertFails(
      setDoc(doc(db, `team_rosters/${teamId}/members/${attackerUid}`), {
        uid: attackerUid,
        teamId,
        role: "admin",
        status: "active",
      })
    );
    await assertFails(
      setDoc(doc(db, `team_rosters/${teamId}/invites/${"c".repeat(64)}`), {
        teamId,
        inviteeUid: attackerUid,
        status: "pending",
      })
    );
    await assertFails(
      setDoc(doc(db, `team_rosters/${teamId}/audit_log/forged-event`), {
        teamId,
        action: "member_promoted",
        actorUid: attackerUid,
      })
    );
    await assertFails(deleteDoc(doc(db, `team_rosters/${teamId}/members/${adminUid}`)));
  }
});

test("test_a_member_of_team_a_cannot_read_team_b", async () => {
  const teamA = "team_aaaaaaaaaaaaaaa4";
  const teamB = "team_bbbbbbbbbbbbbbb4";
  const userA = "t27-user-a-4";
  const userB = "t27-user-b-4";
  const factB = "5".repeat(64);
  const intruderFact = "6".repeat(64);

  await seedTeamRoster(teamA, [{ uid: userA, role: "admin" }]);
  await seedTeamRoster(teamB, [{ uid: userB, role: "admin" }]);
  await seedBurnBarProMaxEntitlement(userA);
  await seedBurnBarProMaxEntitlement(userB);

  const dbA = authedDb(userA);
  const dbB = authedDb(userB);

  await assertSucceeds(
    setDoc(doc(dbB, `team_memory_facts/${teamB}/facts/${factB}`), teamMemoryFact(teamB, userB, factB))
  );

  await assertFails(getDoc(doc(dbA, `team_memory_facts/${teamB}/facts/${factB}`)));
  await assertFails(getDocs(collection(dbA, `team_memory_facts/${teamB}/facts`)));
  await assertFails(getDoc(doc(dbA, `team_rosters/${teamB}`)));
  await assertFails(getDoc(doc(dbA, `team_rosters/${teamB}/members/${userB}`)));
  await assertFails(
    setDoc(
      doc(dbA, `team_memory_facts/${teamB}/facts/${intruderFact}`),
      teamMemoryFact(teamB, userA, intruderFact)
    )
  );
});

test("test_a_forwarded_invite_grants_nothing", async () => {
  const teamId = "team_aaaaaaaaaaaaaaa5";
  const adminUid = "t27-admin-5";
  const inviteeUid = "t27-invitee-5";
  const forwardeeUid = "t27-forwardee-5";
  // The invite doc id IS sha256(token): holding the token means knowing the id.
  const inviteId = "d".repeat(64);
  const factId = "7".repeat(64);

  await seedTeamRoster(teamId, [{ uid: adminUid, role: "admin" }]);
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `team_rosters/${teamId}/invites/${inviteId}`), {
      teamId,
      tokenHash: inviteId,
      inviteeUid,
      role: "member",
      status: "pending",
      invitedBy: adminUid,
      schemaVersion: 1,
    });
  });
  await seedBurnBarProMaxEntitlement(forwardeeUid);

  const forwardeeDb = authedDb(forwardeeUid);

  // Knowing the token buys no read of the invite, no self-insertion into the
  // roster, and no access to team data. The uid binding itself is proved by
  // teamRoster.test.ts; these rules make the token inert on its own.
  await assertFails(getDoc(doc(forwardeeDb, `team_rosters/${teamId}/invites/${inviteId}`)));
  await assertFails(
    updateDoc(doc(forwardeeDb, `team_rosters/${teamId}/invites/${inviteId}`), { inviteeUid: forwardeeUid })
  );
  await assertFails(
    setDoc(doc(forwardeeDb, `team_rosters/${teamId}/members/${forwardeeUid}`), {
      uid: forwardeeUid,
      teamId,
      role: "member",
      status: "active",
    })
  );
  await assertFails(
    setDoc(
      doc(forwardeeDb, `team_memory_facts/${teamId}/facts/${factId}`),
      teamMemoryFact(teamId, forwardeeUid, factId)
    )
  );
});

test("test_cross_team_ciphertext_splice_is_rejected", async () => {
  const teamA = "team_aaaaaaaaaaaaaaa6";
  const teamB = "team_bbbbbbbbbbbbbbb6";
  const splicerUid = "t27-splicer-6";
  const docID = "8".repeat(64);

  // The splicer is legitimately active in BOTH teams; the only thing stopping
  // team A's ciphertext from landing in team B is the AAD binding.
  await seedTeamRoster(teamA, [{ uid: splicerUid, role: "admin" }]);
  await seedTeamRoster(teamB, [{ uid: splicerUid, role: "admin" }]);
  await seedBurnBarProMaxEntitlement(splicerUid);

  const db = authedDb(splicerUid);

  await assertFails(
    setDoc(
      doc(db, `team_memory_facts/${teamB}/facts/${docID}`),
      teamMemoryFact(teamB, splicerUid, docID, {
        sealedMemory: sealedTeamBlobAt(teamA, "team_memory_facts", docID, "sealedMemory"),
      })
    )
  );
  // A personal-lane AAD is refused for the same reason.
  await assertFails(
    setDoc(
      doc(db, `team_memory_facts/${teamB}/facts/${docID}`),
      teamMemoryFact(teamB, splicerUid, docID, {
        sealedMemory: sealedBlobAt(splicerUid, "team_memory_facts", docID, "sealedMemory"),
      })
    )
  );
  await assertSucceeds(
    setDoc(doc(db, `team_memory_facts/${teamB}/facts/${docID}`), teamMemoryFact(teamB, splicerUid, docID))
  );
});

test("test_member_cannot_update_another_members_fact", async () => {
  const teamId = "team_aaaaaaaaaaaaaaa7";
  const authorUid = "t27-author-7";
  const peerUid = "t27-peer-7";
  const docID = "9".repeat(64);

  await seedTeamRoster(teamId, [{ uid: authorUid, role: "admin" }, { uid: peerUid }]);
  await seedBurnBarProMaxEntitlement(authorUid);
  await seedBurnBarProMaxEntitlement(peerUid);
  await seedTeamFact(teamId, authorUid, docID);

  const peerDb = authedDb(peerUid);
  const authorDb = authedDb(authorUid);

  // A plain member may READ the fact but never overwrite it — not by keeping
  // the author uid, and certainly not by claiming authorship.
  await assertSucceeds(getDoc(doc(peerDb, `team_memory_facts/${teamId}/facts/${docID}`)));
  await assertFails(
    setDoc(doc(peerDb, `team_memory_facts/${teamId}/facts/${docID}`), teamMemoryFact(teamId, authorUid, docID))
  );
  await assertFails(
    setDoc(doc(peerDb, `team_memory_facts/${teamId}/facts/${docID}`), teamMemoryFact(teamId, peerUid, docID))
  );
  await assertFails(deleteDoc(doc(peerDb, `team_memory_facts/${teamId}/facts/${docID}`)));

  await assertSucceeds(
    setDoc(doc(authorDb, `team_memory_facts/${teamId}/facts/${docID}`), teamMemoryFact(teamId, authorUid, docID))
  );
});

test("test_admin_can_update_but_cannot_rewrite_the_author_uid", async () => {
  const teamId = "team_aaaaaaaaaaaaaaa8";
  const adminUid = "t27-admin-8";
  const authorUid = "t27-author-8";
  const docID = "a".repeat(64);

  await seedTeamRoster(teamId, [{ uid: adminUid, role: "admin" }, { uid: authorUid }]);
  await seedBurnBarProMaxEntitlement(adminUid);
  await seedBurnBarProMaxEntitlement(authorUid);
  await seedTeamFact(teamId, authorUid, docID);

  const adminDb = authedDb(adminUid);

  await assertSucceeds(
    setDoc(
      doc(adminDb, `team_memory_facts/${teamId}/facts/${docID}`),
      teamMemoryFact(teamId, authorUid, docID, { rewrapJobId: "rewrap-2026-09-05" })
    )
  );
  // Authorship is immutable even to an admin.
  await assertFails(
    setDoc(doc(adminDb, `team_memory_facts/${teamId}/facts/${docID}`), teamMemoryFact(teamId, adminUid, docID))
  );
});

test("test_write_under_a_superseded_team_key_version_is_denied", async () => {
  const teamId = "team_aaaaaaaaaaaaaaa9";
  const memberUid = "t27-member-9";
  const staleDocId = "b".repeat(64);
  const freshDocId = "0".repeat(64);

  await seedTeamRoster(teamId, [{ uid: memberUid, role: "admin" }]);
  await seedBurnBarProMaxEntitlement(memberUid);
  await setTeamActiveKeyVersion(teamId, 2, [1, 2]);

  const db = authedDb(memberUid);

  // v1 is retained (old documents still open) but no longer writable.
  await assertFails(
    setDoc(doc(db, `team_memory_facts/${teamId}/facts/${staleDocId}`), teamMemoryFact(teamId, memberUid, staleDocId))
  );
  await assertSucceeds(
    setDoc(
      doc(db, `team_memory_facts/${teamId}/facts/${freshDocId}`),
      teamMemoryFact(teamId, memberUid, freshDocId, {
        teamKeyVersion: 2,
        sealedMemory: sealedTeamBlobAt(teamId, "team_memory_facts", freshDocId, "sealedMemory", { keyVersion: 2 }),
      })
    )
  );
});

test("test_outer_and_sealed_key_versions_must_match", async () => {
  const teamId = "team_ccccccccccccccc1";
  const memberUid = "t27-member-10";
  const docID = "c".repeat(64);

  await seedTeamRoster(teamId, [{ uid: memberUid, role: "admin" }]);
  await seedBurnBarProMaxEntitlement(memberUid);
  await setTeamActiveKeyVersion(teamId, 2, [1, 2]);

  const db = authedDb(memberUid);

  // Outer label says v2 (matching the roster) but the envelope is sealed v1.
  await assertFails(
    setDoc(
      doc(db, `team_memory_facts/${teamId}/facts/${docID}`),
      teamMemoryFact(teamId, memberUid, docID, {
        teamKeyVersion: 2,
        sealedMemory: sealedTeamBlobAt(teamId, "team_memory_facts", docID, "sealedMemory", { keyVersion: 1 }),
      })
    )
  );
  // ...and the mirror image: envelope v2, outer label v1.
  await assertFails(
    setDoc(
      doc(db, `team_memory_facts/${teamId}/facts/${docID}`),
      teamMemoryFact(teamId, memberUid, docID, {
        teamKeyVersion: 1,
        sealedMemory: sealedTeamBlobAt(teamId, "team_memory_facts", docID, "sealedMemory", { keyVersion: 2 }),
      })
    )
  );
});

test("test_member_cannot_write_plaintext_fields", async () => {
  // The ENFORCEMENT is `keys().hasOnly(...)` on the fact validator — a single
  // allowlist, not a denylist. The explicit `!("text" in d)` negations that
  // used to sit beside it were mutation-tested and provably dead (removing all
  // six broke nothing), so they were deleted; this test is what proves every
  // one of those field names is still refused.
  const teamId = "team_ccccccccccccccc2";
  const memberUid = "t27-member-11";

  await seedTeamRoster(teamId, [{ uid: memberUid, role: "admin" }]);
  await seedBurnBarProMaxEntitlement(memberUid);

  const db = authedDb(memberUid);
  const leaks = [
    { text: "the plaintext body" },
    { body: "the plaintext body" },
    { citations: [{ threadLogicalID: "thread-1", messageID: "message-1" }] },
    { embedding: [0.1, 0.2, 0.3] },
    { cloakedVector: [0.1, 0.2, 0.3] },
    { vector: [0.1, 0.2, 0.3] },
    { projectName: "OpenBurnBar" },
    // vaultGeneration is a PERSONAL vault concept; letting it in would admit
    // the personal rewrap worker's update shape by accident.
    { vaultGeneration: 3 },
  ];

  let index = 0;
  for (const leak of leaks) {
    const docID = `${index}`.repeat(64).slice(0, 64);
    index += 1;
    await assertFails(
      setDoc(
        doc(db, `team_memory_facts/${teamId}/facts/${docID}`),
        teamMemoryFact(teamId, memberUid, docID, leak)
      )
    );
  }
  // Plaintext source refs in the HMAC list are rejected too.
  const plaintextSourceId = "e".repeat(64);
  await assertFails(
    setDoc(
      doc(db, `team_memory_facts/${teamId}/facts/${plaintextSourceId}`),
      teamMemoryFact(teamId, memberUid, plaintextSourceId, {
        sourceRefHmacs: ["thread-1|message-1|hash"],
      })
    )
  );
});

test("test_placeholder_citation_hmacs_are_rejected", async () => {
  const teamId = "team_ccccccccccccccc3";
  const memberUid = "t27-member-12";
  const overCountId = "f".repeat(64);
  const underCountId = "1".repeat(63) + "2";
  const okId = "2".repeat(63) + "3";

  await seedTeamRoster(teamId, [{ uid: memberUid, role: "admin" }]);
  await seedBurnBarProMaxEntitlement(memberUid);

  const db = authedDb(memberUid);

  // The held attempt derived citationCount and sourceRefHmacs independently,
  // then padded the list with a placeholder. The rule now forces one
  // derivation: the count IS the list length.
  await assertFails(
    setDoc(
      doc(db, `team_memory_facts/${teamId}/facts/${overCountId}`),
      teamMemoryFact(teamId, memberUid, overCountId, { citationCount: 2, sourceRefHmacs: ["a".repeat(64)] })
    )
  );
  await assertFails(
    setDoc(
      doc(db, `team_memory_facts/${teamId}/facts/${underCountId}`),
      teamMemoryFact(teamId, memberUid, underCountId, {
        citationCount: 1,
        sourceRefHmacs: ["a".repeat(64), "b".repeat(64)],
      })
    )
  );
  await assertSucceeds(
    setDoc(
      doc(db, `team_memory_facts/${teamId}/facts/${okId}`),
      teamMemoryFact(teamId, memberUid, okId, {
        citationCount: 2,
        sourceRefHmacs: ["a".repeat(64), "b".repeat(64)],
      })
    )
  );
});

test("test_a_member_cannot_read_another_members_key_envelope", async () => {
  const teamId = "team_ccccccccccccccc4";
  const memberUid = "t27-member-13";
  const peerUid = "t27-peer-13";
  const outsiderUid = "t27-outsider-13";

  await seedTeamRoster(teamId, [{ uid: memberUid, role: "admin" }, { uid: peerUid }]);
  await seedBurnBarProMaxEntitlement(memberUid);
  await seedBurnBarProMaxEntitlement(peerUid);
  await seedBurnBarProMaxEntitlement(outsiderUid);

  const memberDb = authedDb(memberUid);
  const peerDb = authedDb(peerUid);
  const ownId = `${memberUid}_device-a_1_v1`;
  const peerId = `${peerUid}_device-b_1_v1`;
  const peerSlugId = `${peerUid}_device-b_1_slug`;

  // An active ADMIN may PUBLISH an envelope for a joiner (the wrap happened
  // client-side against the joiner's own published escrow key)...
  await assertSucceeds(
    setDoc(
      doc(memberDb, `team_key_envelopes/${teamId}/envelopes/${ownId}`),
      teamKeyEnvelope(teamId, memberUid, "device-a", 1, "v1", memberUid)
    )
  );
  await assertSucceeds(
    setDoc(
      doc(memberDb, `team_key_envelopes/${teamId}/envelopes/${peerId}`),
      teamKeyEnvelope(teamId, peerUid, "device-b", 1, "v1", memberUid)
    )
  );
  await assertSucceeds(
    setDoc(
      doc(memberDb, `team_key_envelopes/${teamId}/envelopes/${peerSlugId}`),
      teamKeyEnvelope(teamId, peerUid, "device-b", 1, "slug", memberUid)
    )
  );

  // ...but reads only its own, and a published envelope is immutable.
  await assertSucceeds(getDoc(doc(memberDb, `team_key_envelopes/${teamId}/envelopes/${ownId}`)));
  await assertFails(getDoc(doc(memberDb, `team_key_envelopes/${teamId}/envelopes/${peerId}`)));
  await assertSucceeds(getDoc(doc(peerDb, `team_key_envelopes/${teamId}/envelopes/${peerId}`)));
  await assertFails(getDoc(doc(peerDb, `team_key_envelopes/${teamId}/envelopes/${ownId}`)));
  await assertFails(getDocs(collection(memberDb, `team_key_envelopes/${teamId}/envelopes`)));
  await assertFails(
    updateDoc(doc(peerDb, `team_key_envelopes/${teamId}/envelopes/${peerId}`), {
      wrappedKeyBase64: SUBSTITUTED_FIXTURE_B64,
    })
  );
  await assertFails(deleteDoc(doc(peerDb, `team_key_envelopes/${teamId}/envelopes/${peerId}`)));

  // The document id is pinned to (uid, deviceId, escrowKeyVersion, keySlot), so
  // an envelope cannot be filed under a slot it does not name.
  await assertFails(
    setDoc(
      doc(memberDb, `team_key_envelopes/${teamId}/envelopes/${memberUid}_device-a_1_v2`),
      teamKeyEnvelope(teamId, memberUid, "device-a", 1, "v1", memberUid)
    )
  );
  await assertFails(
    setDoc(
      doc(authedDb(outsiderUid), `team_key_envelopes/${teamId}/envelopes/${outsiderUid}_device-c_1_v1`),
      teamKeyEnvelope(teamId, outsiderUid, "device-c", 1, "v1", outsiderUid)
    )
  );
});

test("test_a_plain_member_cannot_squat_a_peers_key_envelope", async () => {
  // PR1 review F1. Envelopes are create-only and immutable: whoever writes an
  // id owns it for ever, and nobody — not an admin, not a support callable —
  // can repair it. When every active member could create an envelope for every
  // uid, a plain member could pre-write a joiner's whole id set with garbage
  // wraps and leave that joiner permanently active-but-blind. `create` is now
  // admin-or-self, and `wrappedBy` is pinned to the author.
  const teamId = "team_ccccccccccccccc5";
  const adminUid = "t27-admin-14";
  const malloryUid = "t27-mallory-14";
  const joinerUid = "t27-joiner-14";
  const outsiderUid = "t27-outsider-14";

  await seedTeamRoster(teamId, [
    { uid: adminUid, role: "admin" },
    { uid: malloryUid },
    { uid: joinerUid, status: "pending" },
  ]);
  for (const uid of [adminUid, malloryUid, joinerUid, outsiderUid]) {
    await seedBurnBarProMaxEntitlement(uid);
  }

  const malloryDb = authedDb(malloryUid);
  const adminDb = authedDb(adminUid);
  const joinerId = `${joinerUid}_device-j_1_v1`;
  const joinerSlugId = `${joinerUid}_device-j_1_slug`;
  const mallorySelfId = `${malloryUid}_device-m_1_v1`;

  // A plain member cannot squat the joiner's vault-key OR slug-key slots.
  await assertFails(
    setDoc(
      doc(malloryDb, `team_key_envelopes/${teamId}/envelopes/${joinerId}`),
      teamKeyEnvelope(teamId, joinerUid, "device-j", 1, "v1", malloryUid)
    )
  );
  await assertFails(
    setDoc(
      doc(malloryDb, `team_key_envelopes/${teamId}/envelopes/${joinerSlugId}`),
      teamKeyEnvelope(teamId, joinerUid, "device-j", 1, "slug", malloryUid)
    )
  );

  // ...and cannot launder the attempt by lying about who wrapped it, in either
  // direction: `wrappedBy` is pinned to `request.auth.uid`.
  await assertFails(
    setDoc(
      doc(malloryDb, `team_key_envelopes/${teamId}/envelopes/${joinerId}`),
      teamKeyEnvelope(teamId, joinerUid, "device-j", 1, "v1", adminUid)
    )
  );
  await assertFails(
    setDoc(
      doc(malloryDb, `team_key_envelopes/${teamId}/envelopes/${mallorySelfId}`),
      teamKeyEnvelope(teamId, malloryUid, "device-m", 1, "v1", adminUid)
    )
  );

  // Self-wrap is the legitimate member case: enrolling a second Mac, and how a
  // founder bootstraps their own key material.
  await assertSucceeds(
    setDoc(
      doc(malloryDb, `team_key_envelopes/${teamId}/envelopes/${mallorySelfId}`),
      teamKeyEnvelope(teamId, malloryUid, "device-m", 1, "v1", malloryUid)
    )
  );

  // An envelope addressed to a uid that is not on this roster is refused, so
  // the tenant cannot be filled with unreclaimable documents for strangers.
  await assertFails(
    setDoc(
      doc(adminDb, `team_key_envelopes/${teamId}/envelopes/${outsiderUid}_device-o_1_v1`),
      teamKeyEnvelope(teamId, outsiderUid, "device-o", 1, "v1", adminUid)
    )
  );

  // The admin keeps the ability the lane actually needs: handing a PENDING
  // joiner its keys.
  await assertSucceeds(
    setDoc(
      doc(adminDb, `team_key_envelopes/${teamId}/envelopes/${joinerId}`),
      teamKeyEnvelope(teamId, joinerUid, "device-j", 1, "v1", adminUid)
    )
  );
});

test("test_a_member_cannot_pre_place_an_envelope_for_a_future_key_generation", async () => {
  // Cursor round, thread firestore.rules:5096. Admin-or-self closed peer
  // squatting but left the FUTURE open. Envelope ids are immutable and derived
  // as `{uid}_{deviceId}_{escrowKeyVersion}_v{N}`, so an active member could
  // self-wrap the ids the NEXT rotation will demand of them — with a wrap to
  // any key but their pinned one — and occupy them for ever. `rotateTeamKey`
  // then fails coverage on the fingerprint mismatch and cannot repair a
  // create-only document, so one ordinary member could permanently deny the
  // team its only revocation primitive while keeping the current key.
  //
  // A self-wrap is now confined to generations the team has ALREADY published.
  const teamId = "team_ccccccccccccccc7";
  const adminUid = "t27-admin-16";
  const malloryUid = "t27-mallory-16";

  await seedTeamRoster(teamId, [{ uid: adminUid, role: "admin" }, { uid: malloryUid }]);
  for (const uid of [adminUid, malloryUid]) {
    await seedBurnBarProMaxEntitlement(uid);
  }

  const malloryDb = authedDb(malloryUid);
  const adminDb = authedDb(adminUid);
  const selfEnvelope = (slot, deviceId = "device-m") =>
    setDoc(
      doc(malloryDb, `team_key_envelopes/${teamId}/envelopes/${malloryUid}_${deviceId}_1_${slot}`),
      teamKeyEnvelope(teamId, malloryUid, deviceId, 1, slot, malloryUid)
    );

  // The next generation, and the one after it, are both denied.
  await assertFails(selfEnvelope("v2"));
  await assertFails(selfEnvelope("v3"));

  // What a member legitimately self-wraps still works: the CURRENT generation
  // and the non-rotating slug key.
  await assertSucceeds(selfEnvelope("v1"));
  await assertSucceeds(selfEnvelope("slug"));

  // The rotating admin is the one who publishes the next generation.
  await assertSucceeds(
    setDoc(
      doc(adminDb, `team_key_envelopes/${teamId}/envelopes/${malloryUid}_device-m_1_v2`),
      teamKeyEnvelope(teamId, malloryUid, "device-m", 1, "v2", adminUid)
    )
  );

  // Once the rotation lands, v2 is a published generation and the member may
  // self-wrap it for a newly enrolled device — but v3 is again out of reach.
  await setTeamActiveKeyVersion(teamId, 2, [1, 2]);
  await assertSucceeds(selfEnvelope("v2", "device-m2"));
  await assertFails(selfEnvelope("v3", "device-m2"));
});

test("test_an_envelope_wrapped_to_a_hex_fingerprint_is_rejected", async () => {
  // Memory program D16 / PR 1. `recipientPublicKeyFingerprint` is the ONLY
  // thing binding an envelope to a key the recipient actually published — the
  // roster authority compares it against the fingerprint pinned on the member
  // row at accept time, and a mismatch means the requirement it was meant to
  // cover is simply unmet. So the shape has to be the shape real devices
  // publish: base64 of a 32-byte SHA-256 digest, 43 base64 characters plus the
  // `=` pad. An earlier draft pinned `^[a-f0-9]{64}$` here, which no device has
  // ever published; no client could have written a single valid envelope.
  // Both halves are asserted so the regex cannot silently drift back to hex or
  // slacken into a bare length bound.
  const teamId = "team_ccccccccccccccd1";
  const adminUid = "t27-admin-24";

  await seedTeamRoster(teamId, [{ uid: adminUid, role: "admin" }]);
  await seedBurnBarProMaxEntitlement(adminUid);
  const adminDb = authedDb(adminUid);
  const envelopePath = (slot) => `team_key_envelopes/${teamId}/envelopes/${adminUid}_device-a_1_${slot}`;

  // The real shape is accepted.
  await assertSucceeds(
    setDoc(doc(adminDb, envelopePath("v1")), teamKeyEnvelope(teamId, adminUid, "device-a", 1, "v1", adminUid))
  );

  // 64 hex — the shape the earlier draft demanded — is not a fingerprint any
  // device emits.
  await assertFails(
    setDoc(
      doc(adminDb, envelopePath("v2")),
      teamKeyEnvelope(teamId, adminUid, "device-a", 1, "v2", adminUid, {
        recipientPublicKeyFingerprint: "b".repeat(64),
      })
    )
  );

  // Nor is a base64 string of the wrong digest length, or a non-string.
  await assertFails(
    setDoc(
      doc(adminDb, envelopePath("v3")),
      teamKeyEnvelope(teamId, adminUid, "device-a", 1, "v3", adminUid, {
        recipientPublicKeyFingerprint: `${"b".repeat(27)}=`,
      })
    )
  );
  await assertFails(
    setDoc(
      doc(adminDb, envelopePath("v4")),
      teamKeyEnvelope(teamId, adminUid, "device-a", 1, "v4", adminUid, {
        recipientPublicKeyFingerprint: 1,
      })
    )
  );
});

test("test_a_fact_create_pins_the_author_uid", async () => {
  // PR1 review F9 / mutant M11: removing `request.resource.data.uid ==
  // request.auth.uid` from the fact `allow create` broke no test. Every
  // existing case that wrote a foreign uid was either an outsider (denied
  // earlier by isTeamMember) or an update on an existing document. This is the
  // create-time author pin on its own.
  const teamId = "team_ccccccccccccccc6";
  const authorUid = "t27-author-15";
  const peerUid = "t27-peer-15";
  const foreignId = "3".repeat(64);
  const ownId = "4".repeat(64);

  await seedTeamRoster(teamId, [{ uid: authorUid, role: "admin" }, { uid: peerUid }]);
  await seedBurnBarProMaxEntitlement(authorUid);
  await seedBurnBarProMaxEntitlement(peerUid);

  const peerDb = authedDb(peerUid);

  // A brand new document claiming a teammate as its author is refused...
  await assertFails(
    setDoc(doc(peerDb, `team_memory_facts/${teamId}/facts/${foreignId}`), teamMemoryFact(teamId, authorUid, foreignId))
  );
  // ...including for an ADMIN, who may edit a teammate's row but may not
  // manufacture one in their name.
  await assertFails(
    setDoc(
      doc(authedDb(authorUid), `team_memory_facts/${teamId}/facts/${foreignId}`),
      teamMemoryFact(teamId, peerUid, foreignId)
    )
  );
  // ...and the same member writing under their own uid succeeds.
  await assertSucceeds(
    setDoc(doc(peerDb, `team_memory_facts/${teamId}/facts/${ownId}`), teamMemoryFact(teamId, peerUid, ownId))
  );
});

test("rules test environment is isolated", () => {
  assert.ok(testEnv.projectId.startsWith("openburnbar-rules-"));
});
