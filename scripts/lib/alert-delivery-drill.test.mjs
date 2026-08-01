import assert from "node:assert/strict";
import test from "node:test";

import {
  REDACTED_PROJECT_PLACEHOLDER,
  alertDeliveryChannelDrift,
  alertDeliveryRunId,
  assertAlertDeliveryRunId,
  buildAlertDeliveryEvidence,
  buildPendingAlertDeliveryTrigger,
  redactedAlertChannelName,
} from "./alert-delivery-drill.mjs";

const channel = {
  name: "projects/burnbar/notificationChannels/email",
  type: "email",
  target: "ops@burnbar.ai",
  policyDisplayNames: ["OpenBurnBar alert-delivery drill canary"],
};
const redactedChannelName = `projects/${REDACTED_PROJECT_PLACEHOLDER}/notificationChannels/email`;

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

test("alert delivery evidence redacts the project id and channel resource paths", () => {
  const pending = buildPendingAlertDeliveryTrigger({
    project: "burnbar",
    runId: "alert-delivery-drill-2026-06-17T15-00-00-000Z",
    triggeredAt: "2026-06-17T15:00:00.000Z",
    channels: [channel],
  });
  assert.equal(pending.project, REDACTED_PROJECT_PLACEHOLDER);
  assert.equal(pending.channels[0].name, redactedChannelName);

  const evidence = buildAlertDeliveryEvidence({ pending, operator: "operator" });
  assert.equal(evidence.project, REDACTED_PROJECT_PLACEHOLDER);
  assert.equal(evidence.channels[0].name, redactedChannelName);

  // Redaction is idempotent so gate-side normalization can run on both raw
  // live names and already-redacted committed evidence.
  assert.equal(redactedAlertChannelName(channel.name), redactedChannelName);
  assert.equal(redactedAlertChannelName(redactedChannelName), redactedChannelName);
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
      missing: [`projects/${REDACTED_PROJECT_PLACEHOLDER}/notificationChannels/sms`],
      stale: [redactedChannelName],
      changed: [],
    },
  );
  assert.deepEqual(
    alertDeliveryChannelDrift([channel], [{ ...channel, target: "ops2@burnbar.ai" }]),
    {
      ok: false,
      missing: [],
      stale: [],
      changed: [redactedChannelName],
    },
  );
});
