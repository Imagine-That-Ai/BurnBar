/**
 * Shared GCP Monitoring ops-alert verification for launch gate and ops scripts.
 */
import { spawnSync } from "node:child_process";
import { BILLING_ALERT_POLICIES } from "../../functions/scripts/billing-alert-policy-definitions.mjs";
import { OPS_ALERT_POLICIES } from "../../functions/scripts/ops-alert-policy-definitions.mjs";

const PROJECT = process.env.OPENBURNBAR_FIREBASE_PROJECT
  || process.env.GCLOUD_PROJECT
  || process.env.GOOGLE_CLOUD_PROJECT
  || "burnbar";

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || process.cwd(),
    env: options.env || process.env,
    encoding: "utf8",
    timeout: options.timeout ?? 120_000,
  });
  return {
    ok: result.status === 0,
    status: result.status,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error?.message,
  };
}

/**
 * Notification channel types that carry a GCP-managed verification handshake
 * (a real human/endpoint had to confirm the target). For these we require
 * verificationStatus === "VERIFIED" so an audited NXDOMAIN email channel —
 * which stays enabled in GCP but never verifies — fails closed.
 */
export const VERIFIABLE_CHANNEL_TYPES = new Set(["email", "sms"]);

/**
 * Channel types we accept without a verification handshake. For these we still
 * assert the type is known and the target is a non-empty, non-placeholder value.
 */
export const ALLOWED_CHANNEL_TYPES = new Set([
  "email",
  "sms",
  "slack",
  "pubsub",
  "webhook_tokenauth",
  "webhook_basicauth",
]);

/**
 * Channel-label keys that hold the routable target, by channel type. Used to
 * read the address/endpoint out of `gcloud monitoring channels list` JSON.
 */
const CHANNEL_TARGET_LABEL = {
  email: "email_address",
  sms: "number",
  slack: "channel_name",
  pubsub: "topic",
  webhook_tokenauth: "url",
  webhook_basicauth: "url",
};

/**
 * Known-bad / unresolvable placeholder domains that an enabled-but-dead email
 * channel parks on (the Cure53-audited NXDOMAIN case). A target on any of these
 * is rejected even before verificationStatus is consulted, so a placeholder can
 * never read as a live page even if GCP somehow reports it VERIFIED.
 */
const PLACEHOLDER_TARGET_PATTERNS = [
  /@example\.(com|org|net)$/i,
  /@example\./i,
  /@(localhost|invalid|test|local)$/i,
  /\.(example|invalid|test|local|localhost)$/i,
  /\b(changeme|todo|placeholder|noreply|donotreply|fixme)\b/i,
];

/** Reads the routable target (email address, phone, url, …) from a channel. */
export function channelTarget(channel) {
  if (!channel) return null;
  const labelKey = CHANNEL_TARGET_LABEL[channel.type];
  const target = labelKey ? channel.labels?.[labelKey] : null;
  return typeof target === "string" && target.trim() !== "" ? target.trim() : null;
}

/** True when a target is empty or matches a known placeholder/unresolvable pattern. */
export function isPlaceholderTarget(target) {
  if (!target) return true;
  return PLACEHOLDER_TARGET_PATTERNS.some((pattern) => pattern.test(target));
}

/**
 * Decides whether a single notification channel is trustworthy enough to count
 * as live for the gate. Returns { ok, reason }; reason is null when ok.
 * Fails closed on: missing channel, disabled, unknown type, empty/placeholder
 * target, and — for verifiable types (email/sms) — verificationStatus !== VERIFIED.
 */
export function evaluateChannel(channel) {
  if (!channel.present) return { ok: false, reason: "missing" };
  if (!channel.enabled) return { ok: false, reason: "disabled" };
  if (!channel.type || !ALLOWED_CHANNEL_TYPES.has(channel.type)) {
    return { ok: false, reason: `unsupported-type:${channel.type || "null"}` };
  }
  if (!channel.target) return { ok: false, reason: "empty-target" };
  if (isPlaceholderTarget(channel.target)) {
    return { ok: false, reason: `placeholder-target:${channel.target}` };
  }
  if (VERIFIABLE_CHANNEL_TYPES.has(channel.type) && channel.verificationStatus !== "VERIFIED") {
    return { ok: false, reason: `unverified:${channel.verificationStatus || "null"}` };
  }
  return { ok: true, reason: null };
}

export function metricTypesForPolicy(policy) {
  const filters = (policy.conditions || [])
    .map((condition) => condition.conditionThreshold?.filter || "")
    .filter(Boolean);
  const metricTypes = new Set();
  for (const filter of filters) {
    for (const match of filter.matchAll(/metric\.type="([^"]+)"/g)) {
      metricTypes.add(match[1]);
    }
  }
  return [...metricTypes].sort();
}

/** Returns per-policy status; ok is true only when all required policies pass. */
export function checkAlertPolicies(expectedPolicies) {
  const result = run("gcloud", [
    "monitoring",
    "policies",
    "list",
    "--project",
    PROJECT,
    "--format=json",
  ]);
  if (!result.ok) return { ok: false, error: result.stderr || result.stdout, project: PROJECT };

  const channelResult = run("gcloud", [
    "monitoring",
    "channels",
    "list",
    "--project",
    PROJECT,
    "--format=json",
  ]);
  if (!channelResult.ok) return { ok: false, error: channelResult.stderr || channelResult.stdout, project: PROJECT };

  const policies = JSON.parse(result.stdout || "[]");
  const channels = JSON.parse(channelResult.stdout || "[]");
  const channelsByName = new Map(channels.map((channel) => [channel.name, channel]));
  const byDisplayName = new Map();
  for (const policy of policies) {
    const entries = byDisplayName.get(policy.displayName) || [];
    entries.push(policy);
    byDisplayName.set(policy.displayName, entries);
  }

  const required = expectedPolicies.map((expected) => {
    const matches = byDisplayName.get(expected.displayName) || [];
    const policy = matches[0];
    const metricTypes = policy ? metricTypesForPolicy(policy) : [];
    const notificationChannels = policy?.notificationChannels || [];
    const notificationChannelStatuses = notificationChannels.map((name) => {
      const channel = channelsByName.get(name);
      const status = {
        name,
        present: Boolean(channel),
        enabled: channel?.enabled === true,
        type: channel?.type || null,
        displayName: channel?.displayName || null,
        verificationStatus: channel?.verificationStatus || null,
        target: channelTarget(channel),
      };
      const { ok, reason } = evaluateChannel(status);
      status.live = ok;
      status.reason = reason;
      return status;
    });
    // A channel is "live" only when enabled, a known/targeted type, and — for
    // verifiable types — VERIFIED. Disabled/unverified/placeholder channels do
    // not count, so a policy backed solely by them fails closed.
    const liveNotificationChannelCount = notificationChannelStatuses.filter((channel) => channel.live).length;
    const unhealthyNotificationChannels = notificationChannelStatuses
      .filter((channel) => !channel.live)
      .map((channel) => ({ name: channel.name, type: channel.type, reason: channel.reason }));
    const missingMetricTypes = expected.requiredMetricTypes.filter(
      (metricType) => !metricTypes.includes(metricType),
    );
    return {
      displayName: expected.displayName,
      present: matches.length === 1,
      duplicateCount: Math.max(0, matches.length - 1),
      enabled: policy?.enabled === true,
      notificationChannels,
      notificationChannelStatuses,
      liveNotificationChannelCount,
      unhealthyNotificationChannels,
      metricTypes,
      missingMetricTypes,
      ok:
        matches.length === 1
        && policy?.enabled === true
        && liveNotificationChannelCount > 0
        && missingMetricTypes.length === 0,
    };
  });

  return {
    ok: required.every((policy) => policy.ok),
    project: PROJECT,
    required,
  };
}

export function checkOpsAlerts() {
  return checkAlertPolicies(OPS_ALERT_POLICIES);
}

export function checkBillingAlerts() {
  return checkAlertPolicies(BILLING_ALERT_POLICIES);
}
