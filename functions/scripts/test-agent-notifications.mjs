import assert from "node:assert/strict";

import {
  buildFcmMessage,
  eventIdFor,
  latestAssistantReply,
  providerLabel,
  shouldCreateNotificationEvent,
  shouldSuppressForDevice,
} from "../lib/agentNotifications.js";

const before = {
  messages: [
    { id: "u1", role: "user", text: "hello" },
  ],
};
const after = {
  agent: "claude",
  messages: [
    { id: "u1", role: "user", text: "hello" },
    { id: "a1", role: "assistant", text: "Done with the fix." },
  ],
};

assert.equal(latestAssistantReply(after)?.id, "a1");
assert.equal(shouldCreateNotificationEvent({ before, after }), true);
assert.equal(shouldCreateNotificationEvent({ before: after, after }), false);
assert.equal(providerLabel("pi_agent"), "Pi");
assert.equal(
  eventIdFor({ sourceKind: "cli_session", threadId: "thread/1", messageId: "a.1" }),
  "cli_session_thread_1_a_1"
);
assert.equal(
  eventIdFor({ sourceKind: "mobile_assistant_chat", threadId: "thread/1", messageId: "a.1" }),
  "mobile_assistant_chat_thread_1_a_1"
);

const event = {
  id: "event-1",
  uid: "u",
  sourceKind: "cli_session",
  sourcePath: "users/u/cli_sessions/t",
  threadId: "thread-1",
  messageId: "a1",
  runtime: "claude",
  providerLabel: "Claude",
  title: "Claude replied",
  preview: "OpenBurnBar has a new agent reply.",
  createdAt: {},
  createdAtMillis: Date.now(),
  updatedAt: {},
  updatedAtMillis: Date.now(),
  status: "pending",
  fanoutAttemptCount: 0,
  replyEnabled: true,
  schemaVersion: 1,
};

const activeDevice = {
  id: "iphone",
  platform: "ios",
  fcmToken: "token",
  notificationsEnabled: true,
  appLifecycle: "active",
  activeThreadId: "thread-1",
  activeRuntime: "claude",
  lastSeenAtMillis: Date.now(),
};

assert.equal(shouldSuppressForDevice(activeDevice, event), true);
assert.equal(
  shouldSuppressForDevice({ ...activeDevice, activeThreadId: "other-thread" }, event),
  false
);
assert.equal(
  shouldSuppressForDevice({ ...activeDevice, appLifecycle: "background" }, event),
  false
);
assert.equal(
  shouldSuppressForDevice({ ...activeDevice, lastSeenAtMillis: Date.now() - 120_000 }, event),
  false
);

const message = buildFcmMessage({ event, device: activeDevice });
assert.equal(message.data.type, "agent_reply");
assert.equal(message.apns.payload.aps.category, "AGENT_REPLY");

const androidMessage = buildFcmMessage({
  event,
  device: { ...activeDevice, platform: "android" },
});
assert.equal(androidMessage.data.type, "agent_reply");
assert.equal(androidMessage.notification, undefined);
assert.equal(androidMessage.android.notification, undefined);

console.log("agent notification tests passed");
