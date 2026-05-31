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

  const policies = JSON.parse(result.stdout || "[]");
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
    return {
      displayName: expected.displayName,
      present: matches.length === 1,
      duplicateCount: Math.max(0, matches.length - 1),
      enabled: policy?.enabled === true,
      notificationChannels: policy?.notificationChannels || [],
      metricTypes,
      missingMetricTypes,
      ok:
        matches.length === 1
        && policy?.enabled === true
        && (policy.notificationChannels || []).length > 0
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
