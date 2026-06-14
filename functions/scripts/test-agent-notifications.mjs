import assert from "node:assert/strict";

import { Timestamp } from "firebase-admin/firestore";

import {
  buildFcmMessage,
  createEventFromThreadWrite,
  eventIdFor,
  fanoutAgentReplyEvent,
  latestAssistantReply,
  providerLabel,
  shouldCreateNotificationEvent,
  shouldSuppressForDevice,
  sweepStuckAgentReplyEvents,
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

// ---------------------------------------------------------------------------
// T-PRV-06: createEventFromThreadWrite stamps a Firestore TTL anchor (`expireAt`)
// on every agent_notification_events doc so it self-expires.
// ---------------------------------------------------------------------------
{
  const created = {};
  const firestore = {
    collection: () => ({
      doc: () => ({
        collection: () => ({
          doc: () => ({
            async create(doc) {
              Object.assign(created, doc);
            },
          }),
        }),
      }),
    }),
  };
  const eventId = await createEventFromThreadWrite({
    uid: "u1",
    threadId: "thread-ttl",
    sourceKind: "cli_session",
    sourcePath: "users/u1/cli_sessions/thread-ttl",
    before,
    after,
    firestore,
  });
  assert.ok(eventId);
  // The TTL field exists and is a Firestore Timestamp roughly 7 days out.
  assert.ok(created.expireAt, "event must carry an expireAt TTL anchor");
  assert.equal(typeof created.expireAt.toMillis, "function");
  const ttlDeltaMs = created.expireAt.toMillis() - created.createdAtMillis;
  const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
  assert.ok(Math.abs(ttlDeltaMs - sevenDaysMs) < 5_000, "expireAt should be ~7 days after creation");
}

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

// ---------------------------------------------------------------------------
// Fan-out resilience (H21): a transient send error on ONE device must not abort
// the whole fan-out, the event must stay `pending` for the sweeper, and the
// scheduled sweeper must recover it once the push plane heals.
// ---------------------------------------------------------------------------

function makeFakeFirestore(initial) {
  // Minimal Firestore stand-in supporting the exact surface fanout/sweep use:
  // users/{uid}/agent_notification_events/{id}, users/{uid}/devices, and a
  // collectionGroup query over the event collection.
  const events = new Map(); // path -> data
  const devices = new Map(); // `${uid}/${deviceId}` -> data
  for (const [uid, evt] of initial.events) events.set(`users/${uid}/agent_notification_events/${evt.id}`, { ...evt });
  for (const [uid, dev] of initial.devices) devices.set(`users/${uid}/devices/${dev.id}`, { ...dev });

  function eventRef(uid, id) {
    const path = `users/${uid}/agent_notification_events/${id}`;
    return {
      path,
      async get() {
        const data = events.get(path);
        return { exists: data !== undefined, data: () => data };
      },
      async set(patch, opts) {
        const prior = events.get(path) ?? {};
        events.set(path, opts?.merge ? { ...prior, ...patch } : { ...patch });
      },
    };
  }
  function deviceRef(uid, id) {
    const path = `users/${uid}/devices/${id}`;
    return {
      path,
      async set(patch, opts) {
        const prior = devices.get(path) ?? {};
        devices.set(path, opts?.merge ? { ...prior, ...patch } : { ...patch });
      },
    };
  }

  return {
    _events: events,
    _devices: devices,
    collection(name) {
      assert.equal(name, "users");
      return {
        doc(uid) {
          return {
            collection(sub) {
              if (sub === "agent_notification_events") {
                return { doc: (id) => eventRef(uid, id) };
              }
              return {
                async get() {
                  const docs = [];
                  for (const [path, data] of devices) {
                    if (!path.startsWith(`users/${uid}/devices/`)) continue;
                    const id = path.slice(`users/${uid}/devices/`.length);
                    docs.push({ id, data: () => data, ref: deviceRef(uid, id) });
                  }
                  return { docs };
                },
              };
            },
          };
        },
      };
    },
    collectionGroup(name) {
      assert.equal(name, "agent_notification_events");
      const filters = [];
      const query = {
        where(field, op, value) {
          filters.push({ field, op, value });
          return query;
        },
        orderBy() {
          return query;
        },
        limit() {
          return query;
        },
        async get() {
          const docs = [];
          for (const [path, data] of events) {
            const ok = filters.every((f) => {
              if (f.op === "==") return data[f.field] === f.value;
              if (f.op === "<=") return data[f.field] <= f.value;
              return true;
            });
            if (!ok) continue;
            const parts = path.split("/");
            const uid = parts[1];
            const id = parts[3];
            docs.push({ id, data: () => data, ref: eventRef(uid, id) });
          }
          return { docs };
        },
      };
      return query;
    },
  };
}

// parseNotificationEvent requires real Timestamp instances on createdAt/updatedAt.
const ts = Timestamp.now();

// One device errors transiently (e.g. APNs not yet provisioned), one succeeds.
{
  const stuckEvent = {
    ...event,
    id: "fan-1",
    uid: "u",
    status: "pending",
    createdAt: ts,
    updatedAt: ts,
    updatedAtMillis: Date.now(),
  };
  const firestore = makeFakeFirestore({
    events: [["u", stuckEvent]],
    devices: [
      ["u", { id: "ios", platform: "ios", fcm_token: "good", appLifecycle: "background", lastSeenAtMillis: 0 }],
      ["u", { id: "android", platform: "android", fcm_token: "bad", appLifecycle: "background", lastSeenAtMillis: 0 }],
    ],
  });
  let attempts = 0;
  const messaging = {
    async send(message) {
      attempts += 1;
      if (message.token === "bad") {
        const err = new Error("APNs auth key not configured");
        err.code = "messaging/authentication-error";
        throw err;
      }
      return "ok";
    },
  };

  const result = await fanoutAgentReplyEvent({ uid: "u", eventId: "fan-1", firestore, messaging });
  // The good device was delivered; the bad device did NOT abort the loop.
  assert.equal(result.sent, 1, "good device should deliver despite a sibling failure");
  assert.equal(result.failed, 1, "the transient error is captured, not thrown");
  assert.equal(attempts, 2, "the loop continued to every device");
  const afterEvent = firestore._events.get("users/u/agent_notification_events/fan-1");
  assert.equal(afterEvent.status, "pending", "an unresolved failure keeps the event pending for the sweeper");
  const badDevice = firestore._devices.get("users/u/devices/android");
  assert.ok(badDevice.lastPushErrorReason, "the failure reason is recorded on the device doc");

  // The scheduled sweeper picks up the still-pending event once the push plane
  // heals (now both sends succeed) and delivers it.
  const healed = {
    async send() {
      return "ok";
    },
  };
  const tally = await sweepStuckAgentReplyEvents({
    firestore,
    messaging: healed,
    now: Date.now() + 5 * 60_000,
  });
  assert.equal(tally.delivered, 1, "sweeper recovers and delivers the stuck event");
  const healedEvent = firestore._events.get("users/u/agent_notification_events/fan-1");
  assert.equal(healedEvent.status, "fanout_complete", "sweeper completes the event after a clean send");
}

// A permanently-failing event is sealed `fanout_failed` after the attempt budget
// so it stops churning the sweeper and becomes operator-visible.
{
  const exhausted = {
    ...event,
    id: "fan-2",
    uid: "u",
    status: "pending",
    fanoutAttemptCount: 8,
    createdAt: ts,
    updatedAt: ts,
    updatedAtMillis: Date.now(),
  };
  const firestore = makeFakeFirestore({
    events: [["u", exhausted]],
    devices: [["u", { id: "ios", platform: "ios", fcm_token: "good", appLifecycle: "background", lastSeenAtMillis: 0 }]],
  });
  const messaging = {
    async send() {
      throw new Error("should not be called once the budget is exhausted");
    },
  };
  const tally = await sweepStuckAgentReplyEvents({ firestore, messaging, now: Date.now() + 5 * 60_000 });
  assert.equal(tally.failed_sealed, 1, "budget-exhausted events are sealed, not retried");
  const sealed = firestore._events.get("users/u/agent_notification_events/fan-2");
  assert.equal(sealed.status, "fanout_failed");
}

// Keep the import used so bundlers/treeshakers don't drop the firestore types
// (the fake never constructs a real Timestamp, but the symbol must resolve).
assert.equal(typeof Timestamp, "function");

console.log("agent notification tests passed");
