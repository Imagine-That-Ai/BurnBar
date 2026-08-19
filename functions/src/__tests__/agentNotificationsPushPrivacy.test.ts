/**
 * F-RR09-008 — agent-reply FCM payloads must not carry stable conversation
 * correlators (`thread_id`, `threadId`) that are visible to the push provider.
 *
 * Closes OPUS-F-006.
 */
import { describe, expect, it, vi } from "vitest";
import { Timestamp } from "firebase-admin/firestore";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

import { buildFcmMessage } from "../agentNotifications.js";

type BuildFcmMessageArgs = Parameters<typeof buildFcmMessage>[0];
type AgentReplyNotificationEvent = BuildFcmMessageArgs["event"];
type DeviceNotificationState = BuildFcmMessageArgs["device"];

function makeEvent(): AgentReplyNotificationEvent {
  const now = Timestamp.fromMillis(1_700_000_000_000);
  return {
    id: "evt-123",
    uid: "user-123",
    sourceKind: "cli_session",
    sourcePath: "users/user-123/cli_sessions/thread-1",
    threadId: "thread-1",
    messageId: "msg-1",
    runtime: "codex",
    providerLabel: "Codex",
    title: "Codex replied",
    preview: "Hello",
    createdAt: now,
    createdAtMillis: now.toMillis(),
    updatedAt: now,
    updatedAtMillis: now.toMillis(),
    expireAt: Timestamp.fromMillis(now.toMillis() + 30 * 24 * 60 * 60 * 1000),
    status: "pending",
    fanoutAttemptCount: 0,
    replyEnabled: true,
    schemaVersion: 1,
  };
}

function makeDevice(): DeviceNotificationState {
  return {
    id: "device-123",
    platform: "ios",
    fcmToken: "token-123",
    notificationsEnabled: true,
    appLifecycle: "active",
    lastSeenAtMillis: 1_700_000_000_000,
    activeThreadId: "thread-1",
  };
}

describe("buildFcmMessage — push privacy", () => {
  it("does not include thread_id or threadId in the FCM data payload", () => {
    const msg = buildFcmMessage({ event: makeEvent(), device: makeDevice() });
    const data = msg.data ?? {};
    expect(data).not.toHaveProperty("thread_id");
    expect(data).not.toHaveProperty("threadId");
  });

  it("uses a constant collapse key on Android instead of thread id", () => {
    const device: DeviceNotificationState = { ...makeDevice(), platform: "android" };
    const msg = buildFcmMessage({ event: makeEvent(), device });
    expect(msg.android?.collapseKey).toBe("agent-reply");
  });

  it("does not include thread-id in the APNs payload", () => {
    const msg = buildFcmMessage({ event: makeEvent(), device: makeDevice() });
    const payload = msg.apns?.payload;
    const aps = payload && typeof payload === "object" ? Reflect.get(payload, "aps") : {};
    expect(aps).not.toHaveProperty("thread-id");
  });

  it("keeps the opaque event_id for client routing", () => {
    const msg = buildFcmMessage({ event: makeEvent(), device: makeDevice() });
    expect(msg.data?.event_id).toBe("evt-123");
  });

  it("stamps uid and expires_at_millis on every fan-out fixture", () => {
    const msg = buildFcmMessage({ event: makeEvent(), device: makeDevice() });
    expect(msg.data?.uid).toBe("user-123");
    expect(msg.data?.expires_at_millis).toMatch(/^\d+$/);
    expect(Number(msg.data?.expires_at_millis)).toBeGreaterThan(0);
  });
});
