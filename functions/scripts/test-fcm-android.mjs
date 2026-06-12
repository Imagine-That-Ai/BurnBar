import assert from "node:assert/strict";

const {
  MAX_FCM_RETRY_ATTEMPTS,
  nextFcmRetryDelayMs,
  processStuckFcmPush,
  pushAndroidFcm,
  sweepStuckFcmPushes,
} = await import("../lib/fcmAndroidSender.js");
const { macHasActiveMediaEntitlement, resolveFanOut } = await import("../lib/voipPush.js");

// ---------------------------------------------------------------------------
// pushAndroidFcm — happy path
// ---------------------------------------------------------------------------
{
  const sent = [];
  const result = await pushAndroidFcm({
    fcmToken: "token-A",
    data: {
      type: "media_incoming_call",
      connection_id: "conn-1",
      caller_name: "Albert",
    },
    documentId: "doc-1",
    sender: async (message) => {
      sent.push(message);
      return "fake-message-id";
    },
  });
  assert.equal(result.status, "sent");
  assert.equal(result.messageId, "fake-message-id");
  assert.equal(sent.length, 1);
  assert.equal(sent[0].token, "token-A");
  assert.equal(sent[0].android.priority, "high");
  assert.equal(sent[0].data.outbound_id, "doc-1");
  assert.equal(sent[0].data.type, "media_incoming_call");
  // Android-specific block carries the same data envelope so workers
  // running on devices below API 26 still see the payload.
  assert.equal(sent[0].android.data.connection_id, "conn-1");
}

// ---------------------------------------------------------------------------
// pushAndroidFcm — rejection codes are permanent
// ---------------------------------------------------------------------------
{
  const result = await pushAndroidFcm({
    fcmToken: "token-bad",
    data: { type: "media_incoming_call" },
    documentId: "doc-2",
    sender: async () => {
      const err = new Error("token wiped");
      err.code = "messaging/registration-token-not-registered";
      throw err;
    },
  });
  assert.equal(result.status, "rejected");
  assert.equal(result.errorCode, "messaging/registration-token-not-registered");
}

// ---------------------------------------------------------------------------
// pushAndroidFcm — transient errors retry
// ---------------------------------------------------------------------------
{
  const result = await pushAndroidFcm({
    fcmToken: "token-rate-limited",
    data: { type: "media_incoming_call" },
    documentId: "doc-3",
    sender: async () => {
      const err = new Error("quota exceeded");
      err.code = "messaging/server-unavailable";
      throw err;
    },
  });
  assert.equal(result.status, "retry");
  assert.equal(result.errorCode, "messaging/server-unavailable");
}

// ---------------------------------------------------------------------------
// stuck FCM retry sweeper — bounded exponential retry and terminal outcomes
// ---------------------------------------------------------------------------
{
  assert.equal(nextFcmRetryDelayMs(1), 30_000);
  assert.equal(nextFcmRetryDelayMs(2), 60_000);
  assert.equal(nextFcmRetryDelayMs(999), 15 * 60_000);
}

{
  const now = new Date("2026-06-11T12:00:00.000Z");
  const doc = makeFakeSnapshot("fcm-success", {
    status: "pending",
    fcmToken: "token-success",
    payload: { type: "media_incoming_call", connection_id: "conn-1", ignored: 42 },
    attemptCount: 2,
  });
  const pushed = [];
  const outcome = await processStuckFcmPush(
    doc,
    async (args) => {
      pushed.push(args);
      return { status: "sent", messageId: "message-123" };
    },
    now
  );
  assert.equal(outcome, "sent");
  assert.equal(pushed.length, 1);
  assert.deepEqual(pushed[0].data, { type: "media_incoming_call", connection_id: "conn-1" });
  assert.deepEqual(doc.updates[0], {
    status: "sent",
    deliveredAt: doc.updates[0].deliveredAt,
    fcmMessageId: "message-123",
  });
  assert.equal(doc.updates[0].deliveredAt.toMillis(), now.getTime());
}

{
  const now = new Date("2026-06-11T12:01:00.000Z");
  const doc = makeFakeSnapshot("fcm-retry", {
    status: "pending",
    fcmToken: "token-retry",
    payload: { type: "media_incoming_call" },
    attemptCount: 2,
  });
  const outcome = await processStuckFcmPush(
    doc,
    async () => ({ status: "retry", errorCode: "messaging/server-unavailable", reason: "server unavailable" }),
    now
  );
  assert.equal(outcome, "rescheduled");
  assert.equal(doc.updates[0].status, "pending");
  assert.equal(doc.updates[0].attemptCount, 3);
  assert.equal(doc.updates[0].lastAttemptAt.toMillis(), now.getTime());
  assert.equal(doc.updates[0].retryAt.toMillis(), now.getTime() + nextFcmRetryDelayMs(3));
}

{
  const now = new Date("2026-06-11T12:02:00.000Z");
  const doc = makeFakeSnapshot("fcm-exhausted", {
    status: "pending",
    fcmToken: "token-exhausted",
    payload: { type: "media_incoming_call" },
    attemptCount: MAX_FCM_RETRY_ATTEMPTS - 1,
  });
  const outcome = await processStuckFcmPush(
    doc,
    async () => ({ status: "retry", errorCode: "messaging/quota-exceeded", reason: "quota" }),
    now
  );
  assert.equal(outcome, "rejected");
  assert.equal(doc.updates[0].status, "rejected");
  assert.equal(doc.updates[0].attemptCount, MAX_FCM_RETRY_ATTEMPTS);
  assert.equal(doc.updates[0].errorCode, "messaging/quota-exceeded");
}

{
  const now = new Date("2026-06-11T12:03:00.000Z");
  const doc = makeFakeSnapshot("fcm-missing-token", {
    status: "pending",
    payload: { type: "media_incoming_call" },
  });
  const outcome = await processStuckFcmPush(
    doc,
    async () => {
      throw new Error("should not push without a token");
    },
    now
  );
  assert.equal(outcome, "rejected");
  assert.equal(doc.updates[0].status, "rejected");
  assert.equal(doc.updates[0].reason, "missing fcmToken");
}

{
  const now = new Date("2026-06-11T12:04:00.000Z");
  const docs = [
    makeFakeSnapshot("fcm-sweep-sent", {
      status: "pending",
      fcmToken: "token-a",
      payload: { type: "media_incoming_call" },
    }),
    makeFakeSnapshot("fcm-sweep-skip", {
      status: "sent",
      fcmToken: "token-b",
      payload: { type: "media_incoming_call" },
    }),
  ];
  const db = makeFakeCollectionGroupDb(docs);
  const tally = await sweepStuckFcmPushes(db, async () => ({ status: "sent", messageId: "ok" }), now);
  assert.deepEqual(tally, { sent: 1, rejected: 0, rescheduled: 0, skipped: 1 });
}

// ---------------------------------------------------------------------------
// resolveFanOut — reads tokens from paired device doc only (no client APNs/FCM)
// ---------------------------------------------------------------------------
{
  const firestore = makeFakeFirestore({
    [`users/u1/devices/device-A`]: {
      platform: "android",
      fcm_token: "fcm-token-A",
    },
  });
  const fanOut = await resolveFanOut({
    uid: "u1",
    pairedDeviceId: "device-A",
    firestore,
  });
  assert.equal(fanOut.apnsToken, undefined);
  assert.equal(fanOut.fcmToken, "fcm-token-A");
  assert.equal(fanOut.androidDeviceId, "device-A");
}

{
  const firestore = makeFakeFirestore({
    [`users/u1/devices/device-ios`]: {
      platform: "ios",
      voipDeviceToken: "apns-hex",
    },
  });
  const fanOut = await resolveFanOut({
    uid: "u1",
    pairedDeviceId: "device-ios",
    firestore,
  });
  assert.equal(fanOut.apnsToken, "apns-hex");
  assert.equal(fanOut.fcmToken, undefined);
}

{
  const firestore = makeFakeFirestore({
    [`users/u1/devices/device-A`]: {
      platform: "ios",
      fcm_token: "fcm-token-A",
      voipDeviceToken: "apns-hex",
    },
  });
  const fanOut = await resolveFanOut({
    uid: "u1",
    pairedDeviceId: "device-A",
    firestore,
  });
  assert.equal(fanOut.apnsToken, "apns-hex");
  assert.equal(fanOut.fcmToken, undefined);
}

{
  const firestore = makeFakeFirestore({});
  const fanOut = await resolveFanOut({
    uid: "u1",
    pairedDeviceId: "device-Missing",
    firestore,
  });
  assert.equal(fanOut.apnsToken, undefined);
  assert.equal(fanOut.fcmToken, undefined);
}

{
  const firestore = makeFakeFirestore({
    [`users/u1/devices/device-A`]: { fcm_token: "fcm-only" },
  });
  const fanOut = await resolveFanOut({
    uid: "u1",
    pairedDeviceId: "",
    firestore,
  });
  assert.deepEqual(fanOut, {});
}

// ---------------------------------------------------------------------------
// macHasActiveMediaEntitlement — Cloud Pro gates Mercury media, Cloud does not
// ---------------------------------------------------------------------------
{
  const future = { toMillis: () => Date.now() + 86_400_000 };
  const firestore = makeFakeFirestore({
    "users/u1/entitlements/burnbar_pro": {
      active: true,
      expireAt: future,
    },
  });
  assert.equal(await macHasActiveMediaEntitlement("u1", firestore), false);
}

{
  const future = { toMillis: () => Date.now() + 86_400_000 };
  const firestore = makeFakeFirestore({
    "users/u1/entitlements/burnbar_pro_max": {
      active: true,
      productID: "com.openburnbar.proMax.v2.monthly",
      expireAt: future,
    },
  });
  assert.equal(await macHasActiveMediaEntitlement("u1", firestore), true);
}

{
  const future = { toMillis: () => Date.now() + 86_400_000 };
  const firestore = makeFakeFirestore({
    "users/u1/entitlements/burnbar_pro_max": {
      active: true,
      productID: "com.openburnbar.pro.monthly",
      expireAt: future,
    },
  });
  assert.equal(await macHasActiveMediaEntitlement("u1", firestore), false);
}

{
  const future = { toMillis: () => Date.now() + 86_400_000 };
  const firestore = makeFakeFirestore({
    "users/u1/entitlements/hosted_media_sync": {
      active: true,
      expireAt: future,
    },
  });
  assert.equal(await macHasActiveMediaEntitlement("u1", firestore), true);
}

console.log("Android FCM sender + fan-out resolver ok");

function makeFakeSnapshot(id, initialData) {
  const data = { ...initialData };
  const updates = [];
  return {
    id,
    updates,
    data: () => data,
    ref: {
      path: `fcm_outbound/${id}`,
      async update(update) {
        updates.push(update);
        Object.assign(data, update);
      },
    },
  };
}

function makeFakeCollectionGroupDb(docs) {
  const query = {
    where() {
      return query;
    },
    orderBy() {
      return query;
    },
    limit(limit) {
      assert.equal(limit, 50);
      return query;
    },
    async get() {
      return { docs };
    },
  };
  return {
    collectionGroup(name) {
      assert.equal(name, "fcm_outbound");
      return query;
    },
  };
}

function makeFakeFirestore(docs) {
  return {
    doc(path) {
      return {
        async get() {
          const data = docs[path];
          return {
            exists: data !== undefined,
            data: () => data,
          };
        },
      };
    },
  };
}
