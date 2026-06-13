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

export function notificationChannelStatus(name, channel, options = {}) {
  const blockedEmails = options.disallowedEmails || disallowedAlertEmails();
  if (!channel) {
    return {
      name,
      present: false,
      enabled: false,
      type: "",
      displayName: "",
      emailAddress: "",
      problems: ["notification channel is missing"],
      ok: false,
    };
  }

  const emailAddress = String(channel.labels?.email_address || "").trim();
  const problems = [];
  if (channel.enabled !== true) {
    problems.push("notification channel is disabled");
  }
  if (channel.type === "email" && emailAddress.length === 0) {
    problems.push("email notification channel has no email_address label");
  }
  if (emailAddress && blockedEmails.has(emailAddress.toLowerCase())) {
    problems.push(`email notification channel uses disallowed black-hole address ${emailAddress}`);
  }

  return {
    name,
    present: true,
    enabled: channel.enabled === true,
    type: channel.type || "",
    displayName: channel.displayName || "",
    emailAddress,
    problems,
    ok: problems.length === 0,
  };
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
  const blockedEmails = options.disallowedEmails || disallowedAlertEmails();
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
      notificationChannelStatus(name, channelLookup.byName.get(name), { disallowedEmails: blockedEmails }),
    );
    const notificationChannelProblems = notificationChannelStatuses.flatMap((channel) =>
      channel.problems.map((problem) => `${channel.name}: ${problem}`),
    );
    return {
      displayName: expected.displayName,
      present: matches.length === 1,
      duplicateCount: Math.max(0, matches.length - 1),
      enabled: policy?.enabled === true,
      notificationChannels,
      notificationChannelStatuses,
      notificationChannelProblems,
      metricTypes,
      missingMetricTypes,
      ok:
        matches.length === 1
        && policy?.enabled === true
        && notificationChannels.length > 0
        && notificationChannelProblems.length === 0
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
