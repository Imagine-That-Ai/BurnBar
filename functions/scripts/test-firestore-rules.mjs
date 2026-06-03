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
    schemaVersion: 1,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    vaultKeyID,
    sealedBoxBase64,
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

// Canonical CloudVaultBlobEnvelope (validCloudSealedBlob shape):
// schemaVersion/algorithm/keyVersion/plaintextSHA256/sealedBoxBase64/createdAt.
function sealedBlob(overrides = {}) {
  return {
    schemaVersion: 1,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    plaintextSHA256: "a".repeat(64),
    sealedBoxBase64: "c2VhbGVkLWJsb2I=",
    createdAt: "2026-06-02T00:00:00.000Z",
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
    sealedSchemaVersion: 1,
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
    sealedSchemaVersion: 1,
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
    sealedSchemaVersion: 1,
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

test("owners can publish iroh pairing data and audit events without leaking secrets", async () => {
  const ownerDb = authedDb("iroh-owner");
  const otherDb = authedDb("mallory");
  const publicKeyPath = "users/iroh-owner/iroh_pairing_keys/host";
  const pairingPath = "users/iroh-owner/iroh_pairing/relay-1";
  const auditPath = "users/iroh-owner/iroh_audit_events/event-1";

  await assertSucceeds(
    setDoc(doc(ownerDb, publicKeyPath), {
      id: "host",
      publicKeyBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      publishedAtMillis: 1778860800000,
      protocolVersion: 1,
      schemaVersion: 1,
    })
  );
  await assertSucceeds(getDoc(doc(ownerDb, publicKeyPath)));
  await assertFails(getDoc(doc(otherDb, publicKeyPath)));

  await assertSucceeds(
    setDoc(doc(ownerDb, pairingPath), {
      id: "relay-1",
      nodeId: "z".repeat(52),
      publishedAtMillis: 1778860800000,
      protocolVersion: 1,
      signature: "A".repeat(88),
      createdAt: "2026-05-15T00:00:00.000Z",
      updatedAt: "2026-05-15T00:00:00.000Z",
      schemaVersion: 1,
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

test("mobile agent grant queue is entitlement-gated and metadata-only", async () => {
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
  await assertSucceeds(setDoc(doc(db, authorityPath), authorityDoc));
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

  await assertSucceeds(setDoc(doc(db, requestPath), baseRequest));
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

test("current and legacy computer use subscription product ids satisfy the client authority gate", async () => {
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

    await assertSucceeds(
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
      filename: "screen.png",
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
      filename: "screen.png",
      mime: "image/png",
      size: 1234,
      peerDeviceIdHash: "peer-hash",
      direction: "macToIos",
      schemaVersion: 1,
    })
  );
});

test("BurnBar Cloud does not unlock computer-use authority but Cloud Pro does", async () => {
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
  await assertSucceeds(
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
  const sealedText = {
    algorithm: "AES-256-GCM",
    nonce: "base64nonce",
    ciphertext: "base64ciphertext",
    tag: "base64tag",
    keyVersion: 1,
  };

  await assertSucceeds(
    setDoc(doc(db, snippetPath), {
      id: "snippet-1",
      uid: "alice",
      sourceDeviceID: "mac-1",
      triggerHash: "a".repeat(32),
      sealedTitle: sealedText,
      sealedTrigger: sealedText,
      sealedBody: sealedText,
      sealedScope: sealedText,
      mode: "llm_rewrite",
      isEnabled: true,
      revision: 1,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      deletedAt: null,
      schemaVersion: 1,
      encryption: {
        algorithm: "AES-256-GCM",
        keyVersion: 1,
        tokenHashVersion: 1,
      },
    })
  );

  await assertFails(
    setDoc(doc(db, "users/alice/text_snippets/plaintext"), {
      id: "plaintext",
      uid: "alice",
      sourceDeviceID: "mac-1",
      triggerHash: "b".repeat(32),
      sealedTitle: sealedText,
      sealedTrigger: sealedText,
      sealedBody: sealedText,
      sealedScope: sealedText,
      body: "plaintext snippet",
      mode: "static",
      isEnabled: true,
      revision: 1,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
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
      sealedSchemaVersion: 1,
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
      sealedSchemaVersion: 1,
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
    sealedSchemaVersion: 1,
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

  await assertSucceeds(
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

  await assertSucceeds(
    setDoc(doc(db, wrapperPath), {
      uid: "pro-user",
      targetDeviceId: "device",
      sourceDeviceId: "mac",
      publicKeyFingerprint: "fingerprint",
      keyVersion: 1,
      wrappedVaultKey: "sealed-vault-key",
      vaultKeyID: TEST_VAULT_KEY_ID,
      algorithm: "P256_X963_HKDF_SHA256_AESGCM",
      status: "active",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 2,
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
      sealedSchemaVersion: 1,
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
      sealedSchemaVersion: 1,
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
      sealedSchemaVersion: 1,
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
      sealedSchemaVersion: 1,
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
      sealedSchemaVersion: 1,
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
  await assertSucceeds(setDoc(doc(ownerDb, destinationPath), destination));
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
    wrappedKey: "wrapped",
    relayEncryption: "p256-hkdf-sha256-aesgcm",
    relayKeyVersion: 1,
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
  // The sealed v2 request succeeds.
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
    sealedSchemaVersion: 1,
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

// T4 — session_logs chunk rejects unlisted + plaintext keys (hasOnly).
test("T4 session_logs chunk denies unlisted and plaintext keys", async () => {
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

  await assertSucceeds(
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
    sealedSchemaVersion: 1,
    vaultKeyID: TEST_VAULT_KEY_ID,
    sealedPayload: sealedPayload(),
  };

  await assertSucceeds(setDoc(doc(db, convPath), sealedConversation));
  // Re-introducing a plaintext projectName via merge is denied.
  await assertFails(
    setDoc(doc(db, convPath), { projectName: "BurnBar" }, { merge: true })
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
      sealedSchemaVersion: 1,
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

// T9 — media_attachment_manifests seal-aware filename (Fork F = SEAL).
test("T9 media_attachment_manifests accept sealedFilename and reject co-emitted plaintext", async () => {
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
  // Legacy plaintext filename still syncs (migration fallback).
  await assertSucceeds(
    setDoc(doc(db, "users/mam-owner/media_attachment_manifests/legacy-1"), {
      ...base,
      id: "legacy-1",
      filename: "screen.png",
    })
  );
  // A doc carrying BOTH the sealed and the cleartext name is rejected.
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
    sourceSessionCount: 3,
    sourceConversationCount: 5,
    generatedAt: "2026-06-02T00:00:00.000Z",
    freshness: "fresh",
    visualKinds: ["chart"],
    sealedSnapshot: sealedBlob(),
    encryption: { algorithm: "AES-256-GCM", keyVersion: 1, envelopeSchemaVersion: 1 },
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
});

// T12 — usage / budgetRules reject the plaintext project text once sealed.
test("T12 usage and budgetRules reject plaintext project text when sealed copy present", async () => {
  const db = authedDb("usage-owner");

  // Legacy usage row with only the plaintext name still syncs (migration).
  await assertSucceeds(
    setDoc(doc(db, "users/usage-owner/usage/legacy"), {
      id: "legacy",
      projectName: "BurnBar",
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

  // budgetRules: sealed name + label accepted; plaintext alongside is denied.
  await assertSucceeds(
    setDoc(doc(db, "users/usage-owner/budgetRules/sealed"), {
      id: "sealed",
      sealedProjectName: sealedText(),
      sealedLabel: sealedText(),
      projectKeyHash: "f".repeat(64),
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
});

// T13 — cli_sessions/{id}/snapshots: sealed-only contract (no live writer).
// Sealed action label / touched files / mac path accepted; any plaintext key
// is rejected by the hard-dropped hasOnly allowlist; malformed sealed denied.
test("T13 cli_sessions snapshots seal action/files/path and reject plaintext when sealed", async () => {
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

// T14 — approval_policies: legacy plaintext-only doc still syncs; sealed doc
// with opaque hashes accepted; carrying both sealed + plaintext is rejected;
// bad hash + unknown key rejected.
test("T14 approval_policies seal label/glob/project and reject plaintext when sealed", async () => {
  const ownerUid = "ap-owner";
  const db = authedDb(ownerUid);

  // Legacy plaintext-only policy still syncs (migration safety).
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/legacy`), {
      id: "legacy",
      decision: "approve",
      displayLabel: "Edits in BurnBar",
      fileGlob: "src/**",
      targetProject: "/Users/me/BurnBar",
    })
  );
  // Sealed policy (opaque doc ID + sealed fields + 32-hex trapdoors) accepted.
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/ap_${"a".repeat(32)}`), {
      decision: "approve",
      sealedDisplayLabel: sealedText(),
      sealedFileGlob: sealedText(),
      sealedTargetProject: sealedText(),
      projectKeyHash: "a".repeat(32),
      fileGlobHash: "b".repeat(32),
    })
  );
  // A doc carrying BOTH sealed + plaintext is denied (each private field).
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/leak-label`), {
      decision: "approve",
      sealedDisplayLabel: sealedText(),
      displayLabel: "Edits in BurnBar",
    })
  );
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/leak-glob`), {
      decision: "approve",
      sealedFileGlob: sealedText(),
      fileGlob: "src/**",
    })
  );
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/leak-project`), {
      decision: "approve",
      sealedTargetProject: sealedText(),
      targetProject: "/Users/me/BurnBar",
    })
  );
  // A non-hex projectKeyHash is rejected.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/bad-hash`), {
      decision: "approve",
      sealedTargetProject: sealedText(),
      projectKeyHash: "NOTHEX",
    })
  );
  // An unknown extra key is rejected by hasOnly.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/approval_policies/smuggle`), {
      decision: "approve",
      sealedDisplayLabel: sealedText(),
      notes: "hi",
    })
  );
});

// T15 — rollback_requests: legacy plaintext scope still syncs; sealed scope +
// error accepted; carrying both sealed + plaintext is rejected.
test("T15 rollback_requests seal scope/error and reject plaintext when sealed", async () => {
  const ownerUid = "rr-owner";
  const db = authedDb(ownerUid);

  // Legacy plaintext-only request still syncs (migration safety).
  await assertSucceeds(
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
      sealedErrorMessage: sealedText(),
      errorMessage: "boom",
      status: "failed",
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

// T17 — subscription_topics: sealed display text accepted; legacy plaintext-only
// still syncs; both sealed + plaintext rejected; arbitrary key rejected.
test("T17 subscription_topics seal display text, reject plaintext-when-sealed and arbitrary keys", async () => {
  const ownerUid = "st-owner";
  const db = authedDb(ownerUid);

  // Sealed-only topic accepted.
  await assertSucceeds(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/sealed`), {
      agentURI: "agent://burnbar/research-scout",
      topicID: "agent-updates",
      sealedDisplayName: sealedText(),
      sealedDescription: sealedText(),
      cadence: "daily",
    })
  );
  // Legacy plaintext-only topic still syncs (migration safety).
  await assertSucceeds(
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
      agentURI: "agent://burnbar/research-scout",
      topicID: "agent-updates",
      sealedDisplayName: sealedText(),
      displayName: "Research Scout updates",
    })
  );
  // A topic carrying BOTH sealed + plaintext description is denied.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/leak-desc`), {
      agentURI: "agent://burnbar/research-scout",
      topicID: "agent-updates",
      sealedDescription: sealedText(),
      description: "Daily research digest.",
    })
  );
  // An arbitrary unlisted key is rejected by hasOnly.
  await assertFails(
    setDoc(doc(db, `users/${ownerUid}/subscription_topics/smuggle`), {
      agentURI: "agent://burnbar/research-scout",
      topicID: "agent-updates",
      sealedDisplayName: sealedText(),
      foo: "bar",
    })
  );
});

test("rules test environment is isolated", () => {
  assert.ok(testEnv.projectId.startsWith("openburnbar-rules-"));
});
