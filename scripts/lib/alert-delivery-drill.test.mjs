import assert from "node:assert/strict";
import test from "node:test";

import {
  alertDeliveryChannelDrift,
  alertDeliveryRunId,
  buildAlertDeliveryEvidence,
  buildPendingAlertDeliveryTrigger,
} from "./alert-delivery-drill.mjs";

const channel = {
  name: "projects/burnbar/notificationChannels/email",
  type: "email",
  target: "ops@burnbar.ai",
  policyDisplayNames: ["OpenBurnBar alert-delivery drill canary"],
};

test("alert delivery confirmation preserves the triggered canary run id", () => {
  const triggeredAt = "2026-06-17T15:00:00.000Z";
  const runId = alertDeliveryRunId(triggeredAt);
  const pending = buildPendingAlertDeliveryTrigger({
    project: "burnbar",
    runId,
    triggeredAt,
    channels: [channel],
    recordedAt: "2026-06-17T15:00:01.000Z",
  });

  const evidence = buildAlertDeliveryEvidence({
    pending,
    operator: "operator",
    evidenceUrl: "https://example.test/proof",
    deliveredAt: "2026-06-17T15:03:00.000Z",
  });

  assert.equal(evidence.runId, runId);
  assert.equal(evidence.canary.triggeredAt, triggeredAt);
  assert.equal(evidence.canary.triggerSkipped, false);
  assert.equal(evidence.channels[0].deliveryConfirmed, true);
  assert.equal(evidence.channels[0].verifiedBy, "operator");
  assert.equal(evidence.channels[0].evidenceUri, "https://example.test/proof");
});

test("alert delivery evidence refuses skipped triggers and blank operators", () => {
  const pending = buildPendingAlertDeliveryTrigger({
    project: "burnbar",
    runId: "alert-delivery-drill-2026-06-17T15-00-00-000Z",
    triggeredAt: "2026-06-17T15:00:00.000Z",
    channels: [channel],
  });

  assert.throws(() => buildAlertDeliveryEvidence({ pending, operator: " " }), /operator is required/);
  assert.throws(
    () => buildAlertDeliveryEvidence({
      pending: { ...pending, canary: { ...pending.canary, triggerSkipped: true } },
      operator: "operator",
    }),
    /skipped canary trigger/,
  );
});

test("alert delivery pending channel drift catches stale and missing channels", () => {
  assert.deepEqual(alertDeliveryChannelDrift([channel], [channel]), {
    ok: true,
    missing: [],
    stale: [],
    changed: [],
  });
  assert.deepEqual(
    alertDeliveryChannelDrift([channel], [{ ...channel, name: "projects/burnbar/notificationChannels/sms" }]),
    {
      ok: false,
      missing: ["projects/burnbar/notificationChannels/sms"],
      stale: ["projects/burnbar/notificationChannels/email"],
      changed: [],
    },
  );
  assert.deepEqual(
    alertDeliveryChannelDrift([channel], [{ ...channel, target: "ops2@burnbar.ai" }]),
    {
      ok: false,
      missing: [],
      stale: [],
      changed: ["projects/burnbar/notificationChannels/email"],
    },
  );
});
