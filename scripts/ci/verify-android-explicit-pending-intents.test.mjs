import assert from "node:assert/strict";
import test from "node:test";

import {
  verifyAndroidPendingIntents,
  verifyPendingIntentContract,
} from "./verify-android-explicit-pending-intents.mjs";

test("all production Android PendingIntents have explicit components and package pins", () => {
  const result = verifyAndroidPendingIntents();
  // 11 after the OS-routed quota/mission notification tap in
  // MercuryFcmServiceSupport. This literal is the tripwire: a new
  // PendingIntent must be registered in pendingIntentContracts and
  // counted here deliberately, never absorbed silently.
  assert.equal(result.callCount, 11);
});

test("the contract rejects a zero-argument implicit Intent", () => {
  const source = `
    val replyIntent = Intent().apply {
        action = AgentReplyNotificationReceiver.ACTION_REPLY
    }
    PendingIntent.getBroadcast(context, 0, replyIntent, PendingIntent.FLAG_MUTABLE)
  `;

  assert.throws(
    () =>
      verifyPendingIntentContract(source, {
        file: "fixture.kt",
        variable: "replyIntent",
        component: "AgentReplyNotificationReceiver",
        sink: "getBroadcast",
      }),
    /explicit component constructor/,
  );
});

test("the contract rejects an explicit component without a direct package pin", () => {
  const source = `
    val launchIntent = Intent(context, MainActivity::class.java)
    PendingIntent.getActivity(context, 0, launchIntent, PendingIntent.FLAG_IMMUTABLE)
  `;

  assert.throws(
    () =>
      verifyPendingIntentContract(source, {
        file: "fixture.kt",
        variable: "launchIntent",
        component: "MainActivity",
        sink: "getActivity",
      }),
    /pinned directly to the application package/,
  );
});
