#!/usr/bin/env node
/**
 * Ops-only alert policy gate (9 policies from ops-alert-policy-definitions.mjs).
 * Exits 0 when all are present, enabled, channel-backed, and metric-complete.
 */
import { checkOpsAlerts } from "../lib/ops-alerts-gate.mjs";

const result = checkOpsAlerts();

if (!result.ok && result.error) {
  console.error(result.error);
  process.exit(1);
}

const failing = (result.required || []).filter((p) => !p.ok);
if (failing.length > 0) {
  console.error(`FAIL: ${failing.length} ops alert policy/policies not ready (project=${result.project}):`);
  for (const policy of failing) {
    console.error(JSON.stringify({
      displayName: policy.displayName,
      present: policy.present,
      duplicateCount: policy.duplicateCount,
      enabled: policy.enabled,
      notificationChannelCount: (policy.notificationChannels || []).length,
      liveNotificationChannelCount: policy.liveNotificationChannelCount || 0,
      missingMetricTypes: policy.missingMetricTypes,
    }, null, 2));
  }
  process.exit(1);
}

console.log(`PASS: all ${result.required.length} ops alert policies OK (project=${result.project})`);
process.exit(0);
