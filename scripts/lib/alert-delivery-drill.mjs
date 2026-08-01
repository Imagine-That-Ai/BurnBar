/**
 * Pure helpers for the alert-delivery drill CLI.
 *
 * The canary trigger and the human confirmation are intentionally two separate
 * steps. These helpers keep both evidence files tied to the same runId so the
 * commercial launch gate cannot pass on a confirmation for a different canary.
 */

export const ALERT_DRILL_LOG_NAME = "openburnbar-alert-delivery-drill";
export const ALERT_DRILL_EVENT = "alert_delivery_drill";
export const REDACTED_PROJECT_PLACEHOLDER = "<redacted-project>";
const RUN_ID_PATTERN = /^alert-delivery-drill-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z$/u;

/**
 * Canonical redaction for GCP notification-channel resource names. Committed
 * launch evidence must not carry the raw project segment (the public evidence
 * redaction guard rejects `projects/<id>/notificationChannels/...`), so both
 * the evidence writers and the launch-gate matcher normalize names through
 * this helper. Idempotent: already-redacted names pass through unchanged.
 */
export function redactedAlertChannelName(name) {
  if (typeof name !== "string") return name;
  return name.replace(/^projects\/[^/<][^/]*\//u, `projects/${REDACTED_PROJECT_PLACEHOLDER}/`);
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
    type: channel.type,
    target: channel.target,
    policyDisplayNames: Array.isArray(channel.policyDisplayNames)
      ? [...channel.policyDisplayNames]
      : [],
  }));
}

function normalizedChannelName(channel) {
  if (typeof channel?.name !== "string" || channel.name.trim() === "") {
    throw new Error("channel.name is required");
  }
  return redactedAlertChannelName(channel.name);
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
    // Committed evidence is public; the concrete project id stays out of it.
    project: REDACTED_PROJECT_PLACEHOLDER,
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
  const verifiedBy = typeof operator === "string" ? operator.trim() : "";
  if (verifiedBy === "") {
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
      ...channel,
      deliveryConfirmed: true,
      deliveredAt,
      verifiedBy,
      evidenceUri: evidenceUrl || undefined,
    })),
  };
}
