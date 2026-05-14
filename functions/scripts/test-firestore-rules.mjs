/**
 * Firestore rules regression tests for OpenBurnBar Cloud's paid backup gate.
 *
 * These tests run against the Firestore emulator. They prove that owner-scoped
 * free sync still works, while hosted cloud backup payloads require the
 * server-written `hosted_quota_sync` entitlement document.
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

function authedDb(uid) {
  return testEnv.authenticatedContext(uid, { email: `${uid}@example.test` }).firestore();
}

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
      source: "ios-insights",
      status: "pending",
      liveSummary: "Mission queued from this device.",
      events: [
        {
          timestamp: "2026-05-13T00:00:00.000Z",
          phase: "queued",
          message: "Mission queued from this device.",
          source: "ios",
        },
      ],
      createdAt: "2026-05-13T00:00:00.000Z",
      updatedAt: serverTimestamp(),
      schemaVersion: 2,
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
        events: [
          {
            timestamp: "2026-05-13T00:00:05.000Z",
            phase: "completed",
            message: "Prioritized debt mission with validation commands.",
            runtime: "codex",
            source: "mac",
          },
        ],
        resultPreview: "Prioritized debt mission with validation commands.",
        completedAt: "2026-05-13T00:00:05.000Z",
        updatedAt: serverTimestamp(),
      },
      { merge: true }
    )
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
