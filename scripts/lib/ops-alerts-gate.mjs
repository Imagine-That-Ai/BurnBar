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

function parseJsonOutput(output, fallback) {
  try {
    return JSON.parse(output || JSON.stringify(fallback));
  } catch (error) {
    return { __parseError: error instanceof Error ? error.message : String(error) };
  }
}

function disallowedAlertEmails() {
  return new Set(
    (process.env.OPENBURNBAR_DISALLOWED_ALERT_EMAILS || "support@openburnbar.app")
      .split(",")
      .map((email) => email.trim().toLowerCase())
      .filter(Boolean),
  );
}

/**
 * Notification channel types that carry a GCP-managed verification handshake.
 * These must report verificationStatus === "VERIFIED" to count as live.
 */
export const VERIFIABLE_CHANNEL_TYPES = new Set(["email", "sms"]);

/**
 * Channel types accepted by the gate. Non-verifiable types still need a known,
 * non-empty, non-placeholder target.
 */
export const ALLOWED_CHANNEL_TYPES = new Set([
  "email",
  "sms",
  "slack",
  "pubsub",
  "webhook_tokenauth",
  "webhook_basicauth",
]);

const CHANNEL_TARGET_LABEL = {
  email: "email_address",
  sms: "number",
  slack: "channel_name",
  pubsub: "topic",
  webhook_tokenauth: "url",
  webhook_basicauth: "url",
};

const PLACEHOLDER_TARGET_PATTERNS = [
  /@example\.(com|org|net)$/i,
  /@example\./i,
  /@(localhost|invalid|test|local)$/i,
  /\.(example|invalid|test|local|localhost)$/i,
  /\b(changeme|todo|placeholder|noreply|donotreply|fixme)\b/i,
];

export function channelTarget(channel) {
  if (!channel) return null;
  const labelKey = CHANNEL_TARGET_LABEL[channel.type];
  const target = labelKey ? channel.labels?.[labelKey] : null;
  return typeof target === "string" && target.trim() !== "" ? target.trim() : null;
}

export function isPlaceholderTarget(target) {
  if (!target) return true;
  return PLACEHOLDER_TARGET_PATTERNS.some((pattern) => pattern.test(target));
}

function reasonMessage(reason) {
  if (reason === "missing") return "notification channel is missing";
  if (reason === "disabled") return "notification channel is disabled";
  if (reason === "empty-target") return "notification channel has no routable target label";
  if (reason.startsWith("unsupported-type:")) {
    return `notification channel has unsupported type ${reason.slice("unsupported-type:".length)}`;
  }
  if (reason.startsWith("placeholder-target:")) {
    return `notification channel uses placeholder target ${reason.slice("placeholder-target:".length)}`;
  }
  if (reason.startsWith("disallowed-email:")) {
    return `email notification channel uses disallowed black-hole address ${reason.slice("disallowed-email:".length)}`;
  }
  if (reason.startsWith("unverified:")) {
    return `notification channel is not verified (${reason.slice("unverified:".length)})`;
  }
  return reason;
}

/**
 * Decides whether a single notification channel is trustworthy enough to count
 * as live for the gate.
 */
export function evaluateChannel(channel, options = {}) {
  if (!channel.present) return { ok: false, reason: "missing" };
  if (!channel.enabled) return { ok: false, reason: "disabled" };
  if (!channel.type || !ALLOWED_CHANNEL_TYPES.has(channel.type)) {
    return { ok: false, reason: `unsupported-type:${channel.type || "null"}` };
  }
  if (!channel.target) return { ok: false, reason: "empty-target" };
  if (isPlaceholderTarget(channel.target)) {
    return { ok: false, reason: `placeholder-target:${channel.target}` };
  }
  const blockedEmails = options.disallowedEmails || disallowedAlertEmails();
  if (channel.type === "email" && blockedEmails.has(channel.target.toLowerCase())) {
    return { ok: false, reason: `disallowed-email:${channel.target}` };
  }
  if (VERIFIABLE_CHANNEL_TYPES.has(channel.type) && channel.verificationStatus !== "VERIFIED") {
    return { ok: false, reason: `unverified:${channel.verificationStatus || "null"}` };
  }
  return { ok: true, reason: null };
}

export function notificationChannelStatus(name, channel, options = {}) {
  const status = {
    name,
    present: Boolean(channel),
    enabled: channel?.enabled === true,
    type: channel?.type || null,
    displayName: channel?.displayName || null,
    verificationStatus: channel?.verificationStatus || null,
    target: channelTarget(channel),
    emailAddress: channel?.type === "email" ? channelTarget(channel) || "" : "",
    live: false,
    reason: null,
    problems: [],
    ok: false,
  };
  const { ok, reason } = evaluateChannel(status, options);
  status.live = ok;
  status.reason = reason;
  status.problems = ok ? [] : [reasonMessage(reason)];
  status.ok = ok;
  return status;
}

function loadNotificationChannels(runner, project) {
  const attempts = [
    ["monitoring", "channels", "list", "--project", project, "--format=json"],
    ["alpha", "monitoring", "channels", "list", "--project", project, "--format=json"],
    ["beta", "monitoring", "channels", "list", "--project", project, "--format=json"],
  ];
  let result;
  for (const args of attempts) {
    result = runner("gcloud", args);
    if (result.ok) break;
  }
  if (!result.ok) {
    return {
      ok: false,
      error: result.stderr || result.stdout || result.error || "unable to list notification channels",
      byName: new Map(),
    };
  }

  const channels = parseJsonOutput(result.stdout, []);
  if (channels.__parseError) {
    return {
      ok: false,
      error: `unable to parse notification channels JSON: ${channels.__parseError}`,
      byName: new Map(),
    };
  }
  if (!Array.isArray(channels)) {
    return {
      ok: false,
      error: "notification channels JSON was not an array",
      byName: new Map(),
    };
  }

  return {
    ok: true,
    byName: new Map(channels.map((channel) => [channel.name, channel])),
  };
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
export function checkAlertPolicies(expectedPolicies, options = {}) {
  const project = options.project || PROJECT;
  const runner = options.runner || run;
  const disallowedEmails = options.disallowedEmails || disallowedAlertEmails();
  const result = runner("gcloud", [
    "monitoring",
    "policies",
    "list",
    "--project",
    project,
    "--format=json",
  ]);
  if (!result.ok) return { ok: false, error: result.stderr || result.stdout, project };

  const policies = parseJsonOutput(result.stdout, []);
  if (policies.__parseError) {
    return { ok: false, error: `unable to parse alert policies JSON: ${policies.__parseError}`, project };
  }
  if (!Array.isArray(policies)) {
    return { ok: false, error: "alert policies JSON was not an array", project };
  }

  const channelLookup = loadNotificationChannels(runner, project);
  if (!channelLookup.ok) {
    return { ok: false, error: channelLookup.error, project };
  }

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
    const missingMetricTypes = expected.requiredMetricTypes.filter(
      (metricType) => !metricTypes.includes(metricType),
    );
    const notificationChannels = policy?.notificationChannels || [];
    const notificationChannelStatuses = notificationChannels.map((name) =>
      notificationChannelStatus(name, channelLookup.byName.get(name), { disallowedEmails }),
    );
    const notificationChannelProblems = notificationChannelStatuses.flatMap((channel) =>
      channel.problems.map((problem) => `${channel.name}: ${problem}`),
    );
    const liveNotificationChannelCount = notificationChannelStatuses.filter((channel) => channel.live).length;
    const unhealthyNotificationChannels = notificationChannelStatuses
      .filter((channel) => !channel.live)
      .map((channel) => ({ name: channel.name, type: channel.type, reason: channel.reason }));
    return {
      displayName: expected.displayName,
      present: matches.length === 1,
      duplicateCount: Math.max(0, matches.length - 1),
      enabled: policy?.enabled === true,
      notificationChannels,
      notificationChannelStatuses,
      notificationChannelProblems,
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
    project,
    required,
  };
}

export function checkOpsAlerts() {
  return checkAlertPolicies(OPS_ALERT_POLICIES);
}

export function checkBillingAlerts() {
  return checkAlertPolicies(BILLING_ALERT_POLICIES);
}
