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

function authedDb(uid) {
  return testEnv.authenticatedContext(uid, { email: `${uid}@example.test` }).firestore();
}

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
  await assertSucceeds(
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
  await assertSucceeds(
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
  await assertSucceeds(
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
  await assertSucceeds(
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

test("rules test environment is isolated", () => {
  assert.ok(testEnv.projectId.startsWith("openburnbar-rules-"));
});
