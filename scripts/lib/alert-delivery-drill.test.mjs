import assert from "node:assert/strict";
import test from "node:test";

import {
  REDACTED_CHANNEL_NAME_PLACEHOLDER,
  REDACTED_CHANNEL_TARGET_PLACEHOLDER,
  REDACTED_EVIDENCE_URL_PLACEHOLDER,
  REDACTED_OPERATOR_PLACEHOLDER,
  REDACTED_PROJECT_PLACEHOLDER,
  alertDeliveryChannelDrift,
  alertDeliveryChannelFingerprint,
  alertDeliveryRunId,
  assertAlertDeliveryRunId,
  buildAlertDeliveryEvidence,
  buildPendingAlertDeliveryTrigger,
  isAlertDeliveryChannelFingerprint,
} from "./alert-delivery-drill.mjs";

const channel = {
  name: "projects/burnbar/notificationChannels/email",
  type: "email",
  target: "ops@burnbar.ai",
  policyDisplayNames: ["OpenBurnBar alert-delivery drill canary"],
};
const channelFingerprint =
  "sha256:a5bf8bcf8c1e0be32e3adc18bb620c6eb22a699f494baff384a0c792eb0ac194";

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
  assert.equal(evidence.channels[0].verifiedBy, REDACTED_OPERATOR_PLACEHOLDER);
  assert.equal(evidence.channels[0].evidenceUri, REDACTED_EVIDENCE_URL_PLACEHOLDER);
});

test("alert delivery evidence redacts public identity fields and emits a stable fingerprint", () => {
  const pending = buildPendingAlertDeliveryTrigger({
    project: "burnbar",
    runId: "alert-delivery-drill-2026-06-17T15-00-00-000Z",
    triggeredAt: "2026-06-17T15:00:00.000Z",
    channels: [channel],
  });
  assert.equal(pending.project, "burnbar");
  assert.equal(pending.channels[0].name, channel.name);
  assert.equal(pending.channels[0].target, channel.target);

  const evidence = buildAlertDeliveryEvidence({
    pending,
    operator: "operator",
    evidenceUrl: "https://example.test/proof",
  });
  assert.equal(evidence.project, REDACTED_PROJECT_PLACEHOLDER);
  assert.equal(evidence.channels[0].name, REDACTED_CHANNEL_NAME_PLACEHOLDER);
  assert.equal(evidence.channels[0].target, REDACTED_CHANNEL_TARGET_PLACEHOLDER);
  assert.equal(evidence.channels[0].verifiedBy, REDACTED_OPERATOR_PLACEHOLDER);
  assert.equal(evidence.channels[0].evidenceUri, REDACTED_EVIDENCE_URL_PLACEHOLDER);
  assert.equal(evidence.channels[0].channelFingerprint, channelFingerprint);
  assert.equal(alertDeliveryChannelFingerprint(channel), channelFingerprint);
  assert.equal(
    alertDeliveryChannelFingerprint({
      ...channel,
      type: " EMAIL ",
      target: "OPS@BURNBAR.AI",
    }),
    channelFingerprint,
  );
  assert.equal(isAlertDeliveryChannelFingerprint(channelFingerprint), true);
  assert.equal(isAlertDeliveryChannelFingerprint("sha256:not-a-digest"), false);
  assert.notEqual(
    alertDeliveryChannelFingerprint({ ...channel, target: "ops2@burnbar.ai" }),
    channelFingerprint,
  );
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

test("alert delivery run ids must remain canonical and filename-safe", () => {
  const runId = alertDeliveryRunId("2026-06-17T15:00:00.000Z");
  assert.equal(assertAlertDeliveryRunId(runId), "alert-delivery-drill-2026-06-17T15-00-00-000Z");

  for (const unsafeRunId of [
    "../alert-delivery-drill-2026-06-17T15-00-00-000Z",
    "alert-delivery-drill-2026-06-17T15-00-00-000Z/escape",
    "alert-delivery-drill-2026-06-17T15-00-00-000Z.json",
    "alert-delivery-drill-2026-06-17T15-00-00Z",
    "",
  ]) {
    assert.throws(
      () => assertAlertDeliveryRunId(unsafeRunId),
      /canonical alert-delivery drill id/,
      unsafeRunId,
    );
    assert.throws(
      () => buildPendingAlertDeliveryTrigger({
        project: "burnbar",
        runId: unsafeRunId,
        triggeredAt: "2026-06-17T15:00:00.000Z",
        channels: [channel],
      }),
      /canonical alert-delivery drill id/,
      unsafeRunId,
    );
    assert.throws(
      () => buildAlertDeliveryEvidence({
        pending: {
          schemaVersion: 1,
          project: "burnbar",
          runId: unsafeRunId,
          canary: {
            logName: "openburnbar-alert-delivery-drill",
            event: "alert_delivery_drill",
            triggeredAt: "2026-06-17T15:00:00.000Z",
            triggerSkipped: false,
          },
          channels: [channel],
        },
        operator: "operator",
      }),
      /canonical alert-delivery drill id/,
      unsafeRunId,
    );
  }
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
      stale: [channel.name],
      changed: [],
    },
  );
  assert.deepEqual(
    alertDeliveryChannelDrift([channel], [{ ...channel, target: "ops2@burnbar.ai" }]),
    {
      ok: false,
      missing: [],
      stale: [],
      changed: [channel.name],
    },
  );
});
