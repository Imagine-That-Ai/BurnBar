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

function authedDb(uid) {
  return testEnv.authenticatedContext(uid, { email: `${uid}@example.test` }).firestore();
}

test("credential transfers are encrypted, owner-scoped, expiring one-time codes", async () => {
  const ownerDb = authedDb("credential-owner");
  const otherDb = authedDb("credential-attacker");
  const validCode = "ABCDEFGHJKM2";
  const validPath = `credential_transfers/${validCode}`;
  const baseTransfer = {
    ownerUid: "credential-owner",
    payload: "v1.c2FsdC1maXh0dXJl.aXYtZml4dHVyZQ.Y2lwaGVydGV4dC1maXh0dXJl",
    createdAt: Timestamp.fromDate(new Date("2026-06-01T00:00:00.000Z")),
    expiresAt: Timestamp.fromDate(new Date("2099-01-01T00:00:00.000Z")),
    consumed: false,
  };

  await assertSucceeds(setDoc(doc(ownerDb, validPath), baseTransfer));
  await assertSucceeds(getDoc(doc(ownerDb, validPath)));
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

  await assertSucceeds(
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

  await assertSucceeds(
    setDoc(
      doc(freeDb, threadPath),
      {
        contentIncluded: true,
        title: "private plan",
        preview: "private preview",
        messages: [{ id: "m1", role: "user", content: "secret prompt" }],
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

  await assertSucceeds(
    setDoc(doc(phoneDb, requestPath), {
      id: "mission-1",
      title: "Debt Mission",
      prompt: "Find the highest-leverage technical debt mission from the current Insights brief.",
      missionKind: "debt",
      requestedRuntime: "auto",
      targetProject: "",
      depth: "standard",
      approvalMode: "existing_policy",
      commandsAllowed: false,
      fileEditsAllowed: false,
      source: "ios-insights",
      status: "pending",
      liveSummary: "Mission queued from this device.",
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: serverTimestamp(),
      schemaVersion: 2,
    })
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${requestPath}/events/000001`), {
      sequence: 1,
      timestamp: "2026-05-13T00:00:00.000Z",
      kind: "status",
      phase: "queued",
      title: "Queued",
      message: "Mission queued from this device.",
      source: "ios",
      isError: false,
    })
  );
  const androidRequestPath = "users/ivy/cli_agent_mission_requests/mission-android";
  await assertSucceeds(
    setDoc(doc(phoneDb, androidRequestPath), {
      id: "mission-android",
      title: "Android Mission",
      prompt: "Launch a mobile mission from Android.",
      missionKind: "custom",
      requestedRuntime: "opencode",
      targetProject: "",
      depth: "light",
      approvalMode: "read_only",
      commandsAllowed: false,
      fileEditsAllowed: false,
      source: "android-insights",
      status: "pending",
      liveSummary: "Mission queued from this Android device.",
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: serverTimestamp(),
      schemaVersion: 2,
    })
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${androidRequestPath}/events/000001`), {
      sequence: 1,
      timestamp: "2026-05-13T00:00:00.000Z",
      kind: "status",
      phase: "queued",
      title: "Queued",
      message: "Mission queued from this Android device.",
      source: "android",
      isError: false,
    })
  );
  const chatRequestPath = "users/ivy/cli_agent_mission_requests/chat-ios";
  await assertSucceeds(
    setDoc(doc(phoneDb, chatRequestPath), {
      id: "chat-ios",
      title: "New Codex chat",
      prompt: "Start a normal mobile chat.",
      missionKind: "chat",
      requestedRuntime: "codex",
      requestedModelID: "gpt-5.5",
      targetProject: "",
      depth: "standard",
      approvalMode: "existing_policy",
      commandsAllowed: false,
      fileEditsAllowed: false,
      source: "ios-chat",
      status: "pending",
      liveSummary: "Chat queued from this device.",
      clientThreadID: "mobile-thread-1",
      resumeAction: "new",
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: serverTimestamp(),
      schemaVersion: 2,
    })
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${chatRequestPath}/events/000001`), {
      sequence: 1,
      timestamp: "2026-05-13T00:00:00.000Z",
      kind: "status",
      phase: "queued",
      title: "Queued",
      message: "Chat queued from this device.",
      source: "ios-chat",
      isError: false,
    })
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
    setDoc(doc(phoneDb, lifecyclePath), {
      id: "mission-lifecycle",
      title: "Lifecycle Mission",
      prompt: "Exercise accepted, starting, and running lifecycle states.",
      missionKind: "custom",
      requestedRuntime: "codex",
      targetProject: "",
      depth: "standard",
      approvalMode: "read_only",
      commandsAllowed: false,
      fileEditsAllowed: false,
      source: "ios-insights",
      status: "pending",
      liveSummary: "Mission queued from this device.",
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: serverTimestamp(),
      schemaVersion: 2,
    })
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000001`), {
      sequence: 1,
      timestamp: "2026-05-13T00:00:00.000Z",
      kind: "status",
      phase: "queued",
      title: "Queued",
      message: "Mission queued from this device.",
      source: "ios",
      isError: false,
    })
  );
  await assertSucceeds(
    setDoc(
      doc(phoneDb, lifecyclePath),
      {
        status: "accepted",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        selectedModelID: "gpt-5.5",
        liveSummary: "Codex claimed the mission on this Mac.",
        startedAt: "2026-05-13T00:00:01.000Z",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000002`), {
      sequence: 2,
      timestamp: "2026-05-13T00:00:01.000Z",
      kind: "status",
      phase: "accepted",
      title: "Accepted",
      message: "Codex claimed the mission on this Mac.",
      runtime: "codex",
      source: "mac",
      isError: false,
    })
  );
  await assertSucceeds(
    setDoc(
      doc(phoneDb, lifecyclePath),
      {
        status: "starting",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        liveSummary: "Starting Codex with the mission prompt.",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000003`), {
      sequence: 3,
      timestamp: "2026-05-13T00:00:02.000Z",
      kind: "status",
      phase: "starting",
      title: "Starting",
      message: "Starting Codex with the mission prompt.",
      runtime: "codex",
      source: "mac",
      isError: false,
    })
  );
  await assertSucceeds(
    setDoc(
      doc(phoneDb, lifecyclePath),
      {
        status: "running",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        liveSummary: "Codex is running on this Mac.",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${lifecyclePath}/events/000004`), {
      sequence: 4,
      timestamp: "2026-05-13T00:00:03.000Z",
      kind: "status",
      phase: "running",
      title: "Running",
      message: "Codex is running on this Mac.",
      runtime: "codex",
      source: "mac",
      isError: false,
    })
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
      {
        status: "waiting_for_approval",
        claimedBy: "mac-1",
        approvalRequestId: "approval-1",
        approvalStatus: "pending",
        approvalRequestedAt: "2026-05-13T00:00:03.500Z",
        approvalTitle: "Approve Debt Mission",
        approvalMessage: "Codex is waiting for approval before commands.",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        liveSummary: "Codex is waiting for approval before commands.",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${requestPath}/events/000002`), {
      sequence: 2,
      timestamp: "2026-05-13T00:00:03.000Z",
      kind: "tool_call",
      phase: "tool_use",
      title: "Read",
      message: "Read: AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift",
      fullMessage: "Read: AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift\n\n{\"offset\":1,\"limit\":120}",
      messageLength: 96,
      messageTruncated: false,
      runtime: "codex",
      source: "mac",
      toolName: "Read",
      isError: false,
    })
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
  await assertSucceeds(
    setDoc(
      doc(phoneDb, requestPath),
      {
        approvalStatus: "approved",
        approvalRespondedAt: "2026-05-13T00:00:04.000Z",
        liveSummary: "Approval granted from mobile. Waiting for the Mac to resume.",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
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
      {
        status: "completed",
        claimedBy: "mac-1",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        sessionId: "thread-1",
        liveSummary: "Codex returned a result.",
        resultPreview: "Prioritized debt mission with validation commands.",
        completedAt: "2026-05-13T00:00:05.000Z",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
  );
  await assertSucceeds(
    setDoc(doc(phoneDb, `${requestPath}/events/000003`), {
      sequence: 3,
      timestamp: "2026-05-13T00:00:05.000Z",
      kind: "final_answer",
      phase: "completed",
      title: "Completed",
      message: "Prioritized debt mission with validation commands.",
      fullMessage: "Prioritized debt mission with validation commands.\n\nValidation:\n- xcodebuild test\n- ./gradlew test",
      messageLength: 95,
      messageTruncated: false,
      runtime: "codex",
      source: "mac",
      isError: false,
    })
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

  await assertSucceeds(
    setDoc(doc(macDb, sessionPath), {
      id: "thread-1",
      agent: "claude",
      title: "Diligence Mission",
      preview: "Security and launch-readiness findings",
      modelName: "claude-code",
      workspaceLabel: "BurnBar",
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: "2026-05-13T00:00:03.000Z",
      schemaVersion: 1,
      messages: [
        {
          id: "m1",
          role: "assistant",
          text: "Found one launch-readiness issue.",
          timestamp: "2026-05-13T00:00:03.000Z",
          isError: false,
          toolUses: [],
        },
      ],
    })
  );

  await assertSucceeds(getDoc(doc(macDb, sessionPath)));
  await assertFails(getDoc(doc(otherDb, sessionPath)));
  await assertFails(
    setDoc(doc(macDb, "users/jules/cli_sessions/thread-2"), {
      id: "thread-2",
      agent: "unknown",
      title: "Unsupported",
      preview: "Unsupported agent",
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: "2026-05-13T00:00:03.000Z",
      schemaVersion: 1,
    })
  );
});

test("conversation and session-log backup require hosted cloud entitlement", async () => {
  const db = authedDb("carol");

  await assertFails(
    setDoc(doc(db, "users/carol/conversations/device_conv"), {
      id: "conv",
      deviceId: "device",
      provider: "codex",
      sessionId: "session",
      updatedAt: serverTimestamp(),
    })
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
    setDoc(doc(db, "users/carol/conversations/device_conv"), {
      id: "conv",
      deviceId: "device",
      provider: "codex",
      sessionId: "session",
      updatedAt: serverTimestamp(),
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
      snippet: "private markdown preview",
      terms: ["private", "markdown"],
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
      facetSchemaVersion: 1,
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
      workingDirectory: "/Users/dev/project",
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

  // Plaintext string facets are length-bounded so none can smuggle a full transcript past the
  // zero-knowledge boundary (projectName is the widest at 1024 chars).
  await assertFails(
    setDoc(doc(db, "users/facet-user/session_logs/device_facets_bigproject"), {
      ...facetBase,
      projectName: "x".repeat(2048),
    })
  );

  // A bounded project path is still accepted.
  await assertSucceeds(
    setDoc(doc(db, "users/facet-user/session_logs/device_facets_okproject"), {
      ...facetBase,
      projectName: "/Users/dev/Documents/Windsurf/BurnBar",
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
      algorithm: "P256_X963_HKDF_SHA256_AESGCM",
      status: "active",
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
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

test("provider accounts preserve client-only authority boundaries", async () => {
  const db = authedDb("provider-owner");
  const localAccountPath = "users/provider-owner/provider_accounts/local-codex";
  const cloudAccountPath = "users/provider-owner/provider_accounts/cloud-codex";
  const now = Timestamp.fromDate(new Date("2026-06-01T00:00:00.000Z"));
  const baseLocalAccount = {
    id: "local-codex",
    providerID: "codex",
    label: "Local Codex",
    status: "connected",
    credentialKind: "token",
    storageScope: "device_keychain",
    redactedLabel: "sk-...abcd",
    isDefault: true,
    sortKey: 1,
    schemaVersion: 1,
    createdAt: now,
    updatedAt: now,
  };

  await assertSucceeds(setDoc(doc(db, localAccountPath), baseLocalAccount));

  await assertFails(
    setDoc(doc(db, "users/provider-owner/provider_accounts/forged-cloud"), {
      ...baseLocalAccount,
      id: "forged-cloud",
      storageScope: "cloud_refreshable",
    })
  );

  await assertFails(
    updateDoc(doc(db, localAccountPath), {
      storageScope: "cloud_refreshable",
      updatedAt: Timestamp.fromDate(new Date("2026-06-01T00:01:00.000Z")),
    })
  );

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), cloudAccountPath), {
      id: "cloud-codex",
      providerID: "codex",
      label: "Cloud Codex",
      status: "connected",
      credentialKind: "oauth",
      storageScope: "cloud_refreshable",
      redactedLabel: "cloud account",
      isDefault: false,
      sortKey: 2,
      schemaVersion: 1,
      createdAt: now,
      updatedAt: now,
    });
  });

  await assertFails(deleteDoc(doc(db, cloudAccountPath)));
  await assertSucceeds(deleteDoc(doc(db, localAccountPath)));
});

test("quota snapshots cannot carry server-verified authority from clients", async () => {
  const db = authedDb("quota-owner");
  const now = Timestamp.fromDate(new Date("2026-06-01T00:00:00.000Z"));
  const snapshotPath = "users/quota-owner/quota_snapshots/local-codex";
  const baseSnapshot = {
    sourceKind: "provider",
    sourceId: "local-codex",
    provider: "codex",
    accountID: "local-codex",
    accountLabel: "Local Codex",
    accountStorageScope: "device_keychain",
    fetchedAt: now,
    source: "local-device",
    confidence: "high",
    buckets: [],
    schemaVersion: 1,
    updatedAt: now,
  };

  await assertSucceeds(setDoc(doc(db, snapshotPath), baseSnapshot));

  await assertFails(
    setDoc(doc(db, "users/quota-owner/quota_snapshots/forged-authority"), {
      ...baseSnapshot,
      sourceId: "forged-authority",
      sourceAuthority: "server",
    })
  );

  await assertFails(
    setDoc(doc(db, "users/quota-owner/quota_snapshots/forged-verified"), {
      ...baseSnapshot,
      sourceId: "forged-verified",
      serverVerified: true,
    })
  );

  await assertFails(
    setDoc(doc(db, "users/quota-owner/quota_snapshots/forged-cloud"), {
      ...baseSnapshot,
      sourceId: "forged-cloud",
      accountStorageScope: "cloud_refreshable",
    })
  );

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "users/quota-owner/quota_snapshots/server-cloud"), {
      ...baseSnapshot,
      sourceId: "server-cloud",
      accountStorageScope: "cloud_refreshable",
      sourceAuthority: "server",
      serverVerified: true,
    });
  });

  await assertFails(
    updateDoc(doc(db, "users/quota-owner/quota_snapshots/server-cloud"), {
      updatedAt: Timestamp.fromDate(new Date("2026-06-01T00:01:00.000Z")),
    })
  );
});

test("computer-use client writes cannot set global spend or pricing evidence", async () => {
  const uid = "computer-use-owner";
  const db = authedDb(uid);
  const now = Timestamp.fromDate(new Date("2026-06-01T00:00:00.000Z"));
  await seedHostedComputerUseEntitlement(uid);

  const actionDoc = {
    id: "action-1",
    sessionId: "session-1",
    entryIndex: 1,
    toolKind: "browser",
    actionKind: "click",
    status: "executed",
    approvedBy: "mac",
    parentEntryHashHex: "a".repeat(64),
    recordedAt: now,
    schemaVersion: 1,
  };

  await assertSucceeds(
    setDoc(doc(db, `users/${uid}/computer_use_actions/action-1`), actionDoc)
  );
  await assertFails(
    setDoc(doc(db, `users/${uid}/computer_use_actions/action-cost`), {
      ...actionDoc,
      id: "action-cost",
      visionTokensCostUSD: 25,
    })
  );

  const usageDoc = {
    dayKey: "2026-06-01",
    browserActionsExecuted: 1,
    browserActionsRejected: 0,
    systemActionsExecuted: 0,
    systemActionsRejected: 0,
    phoneControlIntentsExecuted: 0,
    phoneControlIntentsRejected: 0,
    sessionsStarted: 1,
    sessionsCompleted: 0,
    totalSessionSeconds: 30,
    updatedAt: now,
    schemaVersion: 1,
  };

  await assertSucceeds(
    setDoc(doc(db, `users/${uid}/computer_use_quota_usage/2026-06-01`), usageDoc)
  );
  await assertFails(
    setDoc(doc(db, `users/${uid}/computer_use_quota_usage/2026-06-02`), {
      ...usageDoc,
      dayKey: "2026-06-02",
      visionModelSpendUSD: 25,
    })
  );
});

test("agent notification events are server-written and replies are queued by owner", async () => {
  const db = authedDb("nina");
  const otherDb = authedDb("mallory");
  const eventPath = "users/nina/agent_notification_events/event-1";
  const replyPath = "users/nina/agent_notification_replies/reply-1";

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
      replyText: "Ship it.",
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
      replyText: "Hijack",
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
      replyText: "Send somewhere else",
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
      replyText: "No backing event",
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

test("rules test environment is isolated", () => {
  assert.ok(testEnv.projectId.startsWith("openburnbar-rules-"));
});
