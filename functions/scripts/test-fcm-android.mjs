import assert from "node:assert/strict";

const { pushAndroidFcm } = await import("../lib/fcmAndroidSender.js");
const { resolveFanOut } = await import("../lib/voipPush.js");

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
// resolveFanOut — Android-only when no APNs token is provided
// ---------------------------------------------------------------------------
{
  const firestore = makeFakeFirestore({
    [`users/u1/devices/device-A`]: {
      fcm_token: "fcm-token-A",
      updated_at_millis: 1_000,
    },
  });
  const fanOut = await resolveFanOut({
    uid: "u1",
    androidDeviceId: "device-A",
    firestore,
  });
  assert.equal(fanOut.apnsToken, undefined);
  assert.equal(fanOut.fcmToken, "fcm-token-A");
  assert.equal(fanOut.androidDeviceId, "device-A");
}

// ---------------------------------------------------------------------------
// resolveFanOut — fresher Android token wins over older APNs
// ---------------------------------------------------------------------------
{
  const firestore = makeFakeFirestore({
    [`users/u1/devices/device-A`]: {
      fcm_token: "fcm-token-A",
      updated_at_millis: 2_000,
    },
  });
  const fanOut = await resolveFanOut({
    uid: "u1",
    apnsToken: "apns-hex",
    apnsTokenUpdatedAtMillis: 1_500,
    androidDeviceId: "device-A",
    firestore,
  });
  assert.equal(fanOut.apnsToken, undefined);
  assert.equal(fanOut.fcmToken, "fcm-token-A");
}

// ---------------------------------------------------------------------------
// resolveFanOut — older Android token loses to fresher APNs
// ---------------------------------------------------------------------------
{
  const firestore = makeFakeFirestore({
    [`users/u1/devices/device-A`]: {
      fcm_token: "fcm-token-A",
      updated_at_millis: 1_000,
    },
  });
  const fanOut = await resolveFanOut({
    uid: "u1",
    apnsToken: "apns-hex",
    apnsTokenUpdatedAtMillis: 5_000,
    androidDeviceId: "device-A",
    firestore,
  });
  assert.equal(fanOut.apnsToken, "apns-hex");
  assert.equal(fanOut.fcmToken, undefined);
  assert.equal(fanOut.androidDeviceId, undefined);
}

// ---------------------------------------------------------------------------
// resolveFanOut — missing device doc drops the Android branch entirely
// ---------------------------------------------------------------------------
{
  const firestore = makeFakeFirestore({});
  const fanOut = await resolveFanOut({
    uid: "u1",
    apnsToken: "apns-hex",
    androidDeviceId: "device-Missing",
    firestore,
  });
  assert.equal(fanOut.apnsToken, "apns-hex");
  assert.equal(fanOut.fcmToken, undefined);
}

console.log("Android FCM sender + fan-out resolver ok");

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
