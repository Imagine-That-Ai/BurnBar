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
 *   - A Mac `hermes_connections` relay heartbeat carrying
 *     `hostInstallationId` is accepted; an overlong host ID is rejected.
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
  getDoc,
  setDoc,
  Timestamp,
  updateDoc,
} from "firebase/firestore";

const PROJECT_ID = "burnbar-test";
const RULES_PATH = "../firestore.rules";

const aliceUid = "alice-uid";
const malloryUid = "mallory-uid";

const futureTimestamp = Timestamp.fromMillis(Date.now() + 30 * 24 * 60 * 60 * 1000);

// T-AZ-02: a shared-artifact document. The path segment `workspace-<uid>` is the
// tenant boundary; the doc body still carries the matching owner/workspace fields.
function workspaceArtifact(uid) {
  return {
    id: "artifact-1",
    ownerUserID: uid,
    workspaceID: `workspace-${uid}`,
    teamID: "team-default",
    title: "Shared note",
    schemaVersion: 1,
    updatedAt: Timestamp.fromMillis(Date.now()),
  };
}

// T-PTR-06: canonical key-wrapper identity. Both writers form the wrapper doc ID
// as `<vaultKeyID>_<targetDeviceId>_<keyVersion>`, so the rules bind the path
// segment to exactly that composite to cap same-generation wrapper minting.
const wrapperVaultKeyID = "v1_" + "a".repeat(32);
const wrapperTargetDeviceId = "iphone-1";
const wrapperSourceDeviceId = "mac-1";
const wrapperKeyVersion = 1;
const canonicalWrapperId = `${wrapperVaultKeyID}_${wrapperTargetDeviceId}_${wrapperKeyVersion}`;

function canonicalKeyWrapper() {
  return {
    uid: aliceUid,
    targetDeviceId: wrapperTargetDeviceId,
    sourceDeviceId: wrapperSourceDeviceId,
    publicKeyFingerprint: "a".repeat(64),
    keyVersion: wrapperKeyVersion,
    wrappedVaultKey: "D".repeat(128),
    vaultKeyID: wrapperVaultKeyID,
    algorithm: "ECIES-P256-AESGCM",
    status: "active",
    schemaVersion: 3,
    createdAt: Timestamp.fromMillis(Date.now()),
    updatedAt: Timestamp.fromMillis(Date.now()),
  };
}

// A trusted agent-grant-authority document shaped like the server writer's output.
// Clients must never be able to pre-seed this (create is server-owned).
function agentGrantAuthorityDoc() {
  return {
    sourceDeviceId: "ios-phone-1",
    peerNodeId: "pi-peer-node-1",
    publicKeyBase64: "A".repeat(64),
    publishedAtMillis: Date.now(),
    schemaVersion: 1,
    updatedAt: Timestamp.fromMillis(Date.now()),
  };
}

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

const validHermesRelayConnection = {
  id: "relay-host-mac-1",
  displayName: "Alice Mac Hermes Relay",
  mode: "relayLink",
  status: "online",
  capabilities: [
    "remote_relay",
    "cli_agent_chat",
    "cli_agent_model_catalog",
    "cli_agent_session_action",
  ],
  hostInstallationId: "691D5F27-491B-4660-9769-62FDE0D3704F",
  relayPublicKey: "B".repeat(88),
  relayKeyVersion: 3,
  relayEncryption: "hpke-auth-p256-hkdfsha256-aes256gcm",
  realtimeRelayStatus: "offline",
  updatedAt: new Date().toISOString(),
  lastSeenAt: new Date().toISOString(),
  schemaVersion: 2,
};

const validIrohPeerNodeId = "a".repeat(52);
const validIrohController = {
  id: validIrohPeerNodeId,
  connectionId: "relay-host-mac-1",
  irohPeerNodeId: validIrohPeerNodeId,
  deviceId: "ios-phone-1",
  publishedAtMillis: Date.now(),
  protocolVersion: 1,
  publishedByDeviceId: "ios-phone-1",
  schemaVersion: 1,
  updatedAt: Timestamp.fromMillis(Date.now()),
};

const validIrohFallbackAuditEvent = {
  id: "iroh-audit-fallback-1",
  connectionId: "relay-host-mac-1",
  eventType: "iroh_fallback_to_firestore",
  transport: "firestore",
  observedAt: new Date().toISOString(),
  detail: {
    reason: "iroh_stream_failed",
  },
  schemaVersion: 1,
  expireAt: futureTimestamp,
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

// T-PTR-06: seed the create prerequisites (current vault generation + the two
// trusted escrow devices) so the wrapper-create rule's only remaining gate under
// test is the doc-ID composite bind.
async function seedKeyWrapperPrereqs(testEnv, uid) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const dbAdmin = ctx.firestore();
    await setDoc(doc(dbAdmin, `users/${uid}/cloud_vault_state/current`), {
      uid,
      vaultKeyID: wrapperVaultKeyID,
      status: "active",
      keyVersion: 1,
      algorithm: "AES-256-GCM",
      createdByDeviceId: wrapperSourceDeviceId,
      schemaVersion: 2,
    });
    for (const deviceId of [wrapperTargetDeviceId, wrapperSourceDeviceId]) {
      await setDoc(doc(dbAdmin, `users/${uid}/escrow_devices/${deviceId}`), {
        deviceId,
        trustState: "trusted",
        platform: "iOS",
      });
    }
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

  // --- T-PTR-06: wrapper doc-ID is capped to the deterministic composite ---
  // With every other prerequisite satisfied (hosted-quota entitlement, current
  // vault generation, two trusted escrow devices), a wrapper write whose doc ID
  // is NOT `<vaultKeyID>_<targetDeviceId>_<keyVersion>` is rejected, so a stolen
  // session cannot mint extra same-generation wrappers under arbitrary doc IDs.
  await withEntitlement(testEnv, aliceUid, async () => {
    await seedKeyWrapperPrereqs(testEnv, aliceUid);

    await step("wrapper create with a non-canonical doc ID is rejected", async () => {
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/cloud_vault_key_wrappers/extra-wrapper-99`),
          canonicalKeyWrapper()
        )
      );
    });

    await step("wrapper create with the canonical composite doc ID is accepted", async () => {
      await assertSucceeds(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/cloud_vault_key_wrappers/${canonicalWrapperId}`),
          canonicalKeyWrapper()
        )
      );
    });
  });

  // --- T-TOOL-06: agent_grant_authorities cannot be pre-seeded by a client ---
  // The authority doc is the server-owned trust anchor checked before first pin;
  // `allow create: if false` means no client write can plant one ahead of time.
  await step("client create of an agent_grant_authorities doc is rejected", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, `users/${aliceUid}/agent_grant_authorities/ios-phone-1`),
        agentGrantAuthorityDoc()
      )
    );
  });

  await step("client update of a server-seeded agent_grant_authorities doc is rejected", async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `users/${aliceUid}/agent_grant_authorities/ios-phone-1`),
        agentGrantAuthorityDoc()
      );
    });
    await assertFails(
      updateDoc(
        doc(aliceDB, `users/${aliceUid}/agent_grant_authorities/ios-phone-1`),
        { publicKeyBase64: "B".repeat(64) }
      )
    );
  });

  // --- T-AZ-02: workspace artifact paths are bound to the caller ---
  // A caller may only touch their OWN `workspaces/workspace-<uid>/...` subtree.
  await step("workspace artifact write on the caller's own workspace path is accepted", async () => {
    await assertSucceeds(
      setDoc(
        doc(aliceDB, `workspaces/workspace-${aliceUid}/teams/team-default/artifacts/artifact-1`),
        workspaceArtifact(aliceUid)
      )
    );
  });

  await step("workspace artifact write on another tenant's workspace path is rejected", async () => {
    // Even though Alice stamps her own ownerUserID, the path segment
    // `workspace-mallory-uid` is not hers, so the write is denied.
    await assertFails(
      setDoc(
        doc(aliceDB, `workspaces/workspace-${malloryUid}/teams/team-default/artifacts/artifact-1`),
        { ...workspaceArtifact(aliceUid), workspaceID: `workspace-${malloryUid}` }
      )
    );
  });

  await step("workspace artifact read on another tenant's workspace path is rejected", async () => {
    // Mallory owns a doc in her own workspace; Alice cannot read it via the
    // cross-tenant path even though she is authenticated.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `workspaces/workspace-${malloryUid}/teams/team-default/artifacts/artifact-1`),
        workspaceArtifact(malloryUid)
      );
    });
    await assertFails(
      getDoc(doc(aliceDB, `workspaces/workspace-${malloryUid}/teams/team-default/artifacts/artifact-1`))
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
    await step("hermes relay connection WITH hostInstallationId is accepted", async () => {
      await assertSucceeds(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/hermes_connections/${validHermesRelayConnection.id}`),
          validHermesRelayConnection
        )
      );
    });

    await step("hermes relay connection with an overlong hostInstallationId is rejected", async () => {
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/hermes_connections/${validHermesRelayConnection.id}`),
          {
            ...validHermesRelayConnection,
            hostInstallationId: "H".repeat(129),
          }
        )
      );
    });

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

    await step("iroh controller NodeId direct owner write is rejected", async () => {
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/iroh_pairing/relay-host-mac-1/iroh_controllers/${validIrohPeerNodeId}`),
          validIrohController
        )
      );
    });

    await step("iroh controller NodeId server-written doc is owner-readable", async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        const dbAdmin = ctx.firestore();
        await setDoc(
          doc(dbAdmin, `users/${aliceUid}/iroh_pairing/relay-host-mac-1/iroh_controllers/${validIrohPeerNodeId}`),
          validIrohController
        );
      });
      await assertSucceeds(
        getDoc(doc(aliceDB, `users/${aliceUid}/iroh_pairing/relay-host-mac-1/iroh_controllers/${validIrohPeerNodeId}`))
      );
    });

    await step("iroh fallback audit create is accepted but update and delete are rejected", async () => {
      const auditPath = `users/${aliceUid}/iroh_audit_events/${validIrohFallbackAuditEvent.id}`;
      await assertSucceeds(setDoc(doc(aliceDB, auditPath), validIrohFallbackAuditEvent));
      await assertFails(updateDoc(doc(aliceDB, auditPath), { rttMillis: 25 }));
      await assertFails(deleteDoc(doc(aliceDB, auditPath)));
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
