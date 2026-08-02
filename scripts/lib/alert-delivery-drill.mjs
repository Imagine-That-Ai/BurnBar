/**
 * Pure helpers for the alert-delivery drill CLI.
 *
 * The canary trigger and the human confirmation are intentionally two separate
 * steps. These helpers keep both evidence files tied to the same runId so the
 * commercial launch gate cannot pass on a confirmation for a different canary.
 */

import { createHash } from "node:crypto";

export const ALERT_DRILL_LOG_NAME = "openburnbar-alert-delivery-drill";
export const ALERT_DRILL_EVENT = "alert_delivery_drill";
export const REDACTED_PROJECT_PLACEHOLDER = "<redacted-project>";
export const REDACTED_CHANNEL_NAME_PLACEHOLDER = "<redacted-notification-channel>";
export const REDACTED_CHANNEL_TARGET_PLACEHOLDER = "<redacted-alert-target>";
export const REDACTED_OPERATOR_PLACEHOLDER = "<redacted-operator>";
export const REDACTED_EVIDENCE_URL_PLACEHOLDER = "<redacted-evidence-url>";
const RUN_ID_PATTERN = /^alert-delivery-drill-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z$/u;
const CHANNEL_FINGERPRINT_PATTERN = /^sha256:[0-9a-f]{64}$/u;

/**
 * Stable, opaque join key between live GCP channel inventory and publishable
 * delivery evidence. The fixed-key JSON serialization is part of the evidence
 * contract; changing it intentionally requires updating the golden tests and
 * regenerating evidence.
 */
export function alertDeliveryChannelFingerprint(channel) {
  const canonical = {
    name: normalizedChannelName(channel),
    type: normalizedChannelType(channel),
    target: normalizedChannelTarget(channel),
  };
  return `sha256:${createHash("sha256")
    .update(JSON.stringify(canonical), "utf8")
    .digest("hex")}`;
}

export function isAlertDeliveryChannelFingerprint(value) {
  return typeof value === "string" && CHANNEL_FINGERPRINT_PATTERN.test(value);
}

export function alertDeliveryRunId(triggeredAt) {
  if (typeof triggeredAt !== "string" || triggeredAt.trim() === "") {
    throw new Error("triggeredAt is required");
  }
  const runId = `alert-delivery-drill-${triggeredAt.replace(/[:.]/g, "-")}`;
  assertAlertDeliveryRunId(runId);
  return runId;
}

export function assertAlertDeliveryRunId(runId) {
  if (typeof runId !== "string" || !RUN_ID_PATTERN.test(runId)) {
    throw new Error("runId must be a canonical alert-delivery drill id");
  }
  return runId;
}

function normalizedChannels(channels) {
  if (!Array.isArray(channels)) {
    throw new Error("channels must be an array");
  }
  return channels.map((channel) => ({
    name: normalizedChannelName(channel),
    type: normalizedChannelType(channel),
    target: normalizedChannelTarget(channel),
    policyDisplayNames: Array.isArray(channel.policyDisplayNames)
      ? [...channel.policyDisplayNames]
      : [],
  }));
}

function normalizedChannelName(channel) {
  if (typeof channel?.name !== "string" || channel.name.trim() === "") {
    throw new Error("channel.name is required");
  }
  return channel.name.trim();
}

function normalizedChannelType(channel) {
  if (typeof channel?.type !== "string" || channel.type.trim() === "") {
    throw new Error("channel.type is required");
  }
  return channel.type.trim().toLowerCase();
}

function normalizedChannelTarget(channel) {
  const target = channel?.target || channel?.emailAddress;
  if (typeof target !== "string" || target.trim() === "") {
    throw new Error("channel.target is required");
  }
  return target.trim().toLowerCase();
}

export function buildPendingAlertDeliveryTrigger({
  project,
  runId,
  triggeredAt,
  channels,
  recordedAt = new Date().toISOString(),
}) {
  if (typeof project !== "string" || project.trim() === "") {
    throw new Error("project is required");
  }
  assertAlertDeliveryRunId(runId);
  if (typeof triggeredAt !== "string" || triggeredAt.trim() === "") {
    throw new Error("triggeredAt is required");
  }
  const normalized = normalizedChannels(channels);
  if (normalized.length === 0) {
    throw new Error("at least one channel is required");
  }

  return {
    schemaVersion: 1,
    generatedAt: recordedAt,
    // Pending evidence is local and ignored so drift can compare the exact
    // channel identity before the public artifact is redacted.
    project: project.trim(),
    runId,
    canary: {
      logName: ALERT_DRILL_LOG_NAME,
      event: ALERT_DRILL_EVENT,
      triggeredAt,
      triggerSkipped: false,
    },
    channels: normalized,
  };
}

export function alertDeliveryChannelDrift(pendingChannels, currentChannels) {
  const pendingByName = new Map(normalizedChannels(pendingChannels).map((channel) => [channel.name, channel]));
  const currentByName = new Map(normalizedChannels(currentChannels).map((channel) => [channel.name, channel]));
  const pendingNames = new Set(pendingByName.keys());
  const currentNames = new Set(currentByName.keys());
  const missing = [...currentNames].filter((name) => !pendingNames.has(name)).sort();
  const stale = [...pendingNames].filter((name) => !currentNames.has(name)).sort();
  const changed = [...currentNames]
    .filter((name) => pendingNames.has(name))
    .filter((name) => {
      const pending = pendingByName.get(name);
      const current = currentByName.get(name);
      return pending.type !== current.type || pending.target !== current.target;
    })
    .sort();
  return {
    ok: missing.length === 0 && stale.length === 0 && changed.length === 0,
    missing,
    stale,
    changed,
  };
}

export function buildAlertDeliveryEvidence({
  pending,
  operator,
  evidenceUrl = "",
  deliveredAt = new Date().toISOString(),
  generatedAt = deliveredAt,
}) {
  if (!pending || typeof pending !== "object") {
    throw new Error("pending trigger evidence is required");
  }
  if (pending.canary?.triggerSkipped === true) {
    throw new Error("cannot confirm delivery for a skipped canary trigger");
  }
  const operatorName = typeof operator === "string" ? operator.trim() : "";
  if (operatorName === "") {
    throw new Error("operator is required");
  }
  const channels = normalizedChannels(pending.channels);
  if (channels.length === 0) {
    throw new Error("pending trigger has no channels");
  }

  return {
    generatedAt,
    // Re-redact defensively in case an older pending file carried the raw id.
    project: REDACTED_PROJECT_PLACEHOLDER,
    runId: assertAlertDeliveryRunId(pending.runId),
    canary: {
      logName: pending.canary?.logName || ALERT_DRILL_LOG_NAME,
      event: pending.canary?.event || ALERT_DRILL_EVENT,
      triggeredAt: pending.canary?.triggeredAt,
      triggerSkipped: false,
    },
    channels: channels.map((channel) => ({
      name: REDACTED_CHANNEL_NAME_PLACEHOLDER,
      channelFingerprint: alertDeliveryChannelFingerprint(channel),
      type: channel.type,
      target: REDACTED_CHANNEL_TARGET_PLACEHOLDER,
      policyDisplayNames: channel.policyDisplayNames,
      deliveryConfirmed: true,
      deliveredAt,
      verifiedBy: REDACTED_OPERATOR_PLACEHOLDER,
      evidenceUri:
        typeof evidenceUrl === "string" && evidenceUrl.trim() !== ""
          ? REDACTED_EVIDENCE_URL_PLACEHOLDER
          : undefined,
    })),
  };
}
