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
        productID: "com.openburnbar.hostedQuotaSync.monthly",
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

test("rules test environment is isolated", () => {
  assert.ok(testEnv.projectId.startsWith("openburnbar-rules-"));
});
