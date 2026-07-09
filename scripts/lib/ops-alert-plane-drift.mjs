/**
 * Alert-plane drift primitives: render the EXPECTED Cloud Monitoring alert-policy
 * set from the repo manifest (functions/scripts/ops-alert-policy-definitions.mjs +
 * billing-alert-policy-definitions.mjs) and diff it against a LIVE snapshot
 * (`gcloud monitoring policies list --format=json`).
 *
 * The manifest is the source of truth: activate-production-ops-plane.sh applies it
 * out-of-band (apply-ops-alert-policies.mjs), and there was no CI diff-check that
 * live GCP == repo manifest. This module is that check's core, kept pure so it is
 * unit-testable OFFLINE with a fixture snapshot (no gcloud/network).
 *
 * Scope of the diff (intentionally structural, not cosmetic):
 *   - presence + uniqueness of each expected policy (by displayName)
 *   - enabled === true
 *   - the exact set of `combiner`
 *   - the exact set of condition filters (the metric.type + resource.type + label
 *     predicates that define WHAT the policy watches) and their comparison /
 *     thresholdValue / duration (WHEN it fires)
 *   - EXTRA live openburnbar policies not in the manifest (managed-set drift:
 *     something was created out-of-band and is not reproducible from the repo)
 *
 * Notification-channel liveness is deliberately NOT re-checked here — that is the
 * job of scripts/ops/check-ops-alerts.mjs (channels are environment state, not
 * repo state). This check answers only: does live GCP match the committed policy
 * DEFINITIONS?
 */
import {
  OPS_ALERT_POLICIES,
  materializeOpsAlertPolicy,
} from "../../functions/scripts/ops-alert-policy-definitions.mjs";

/**
 * The identifying userLabel the manifest stamps on every policy it owns. Used to
 * scope "extra live policy" detection to policies THIS repo manages, so unrelated
 * project policies don't trip the gate.
 */
export const MANAGED_APP_LABEL = "openburnbar";

/** Canonical, order-independent fingerprint of one condition. */
function conditionFingerprint(condition) {
  const t = condition.conditionThreshold || {};
  return {
    filter: normalizeFilter(t.filter || ""),
    comparison: t.comparison || null,
    thresholdValue: t.thresholdValue ?? null,
    duration: t.duration || null,
    aggregations: stableComparable(t.aggregations || []),
    trigger: stableComparable(t.trigger || null),
  };
}

/**
 * Normalize a Monitoring filter string so semantically-identical filters compare
 * equal regardless of clause ordering / whitespace. GCP may echo a filter back
 * with predicates reordered; the SET of `key=value` / regex predicates is what
 * defines the condition.
 */
function normalizeFilter(filter) {
  return filter
    .split(/\s+AND\s+/i)
    .map((clause) => clause.trim())
    .filter(Boolean)
    .sort()
    .join(" AND ");
}

function stableComparable(value) {
  if (Array.isArray(value)) return value.map(stableComparable);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map((key) => [key, stableComparable(value[key])]),
  );
}

/** Sorted list of condition fingerprints (order-independent within a policy). */
function conditionSet(policy) {
  return (policy.conditions || [])
    .map(conditionFingerprint)
    .map((c) => JSON.stringify(c))
    .sort();
}

/**
 * Render the expected, comparable view of every manifest policy. Notification
 * channels are excluded from the fingerprint (environment state), but the rest of
 * the materialized policy (enabled, combiner, conditions, userLabels) is included.
 */
export function expectedPolicySet(policies = OPS_ALERT_POLICIES) {
  return policies.map((policy) => {
    // Reuse the SAME materializer the applier uses, so we compare against exactly
    // what gets pushed. Channels are a placeholder here and dropped from the diff.
    const materialized = materializeOpsAlertPolicy(policy, ["__channel_placeholder__"]);
    return {
      displayName: materialized.displayName,
      enabled: materialized.enabled === true,
      combiner: materialized.combiner || null,
      conditionSet: conditionSet(materialized),
      appLabel: materialized.userLabels?.app || null,
    };
  });
}

/** Comparable view of one LIVE policy from `gcloud monitoring policies list`. */
function liveView(policy) {
  return {
    displayName: policy.displayName,
    enabled: policy.enabled === true,
    combiner: policy.combiner || null,
    conditionSet: conditionSet(policy),
    appLabel: policy.userLabels?.app || null,
  };
}

/**
 * Diff expected (manifest) vs live (snapshot array).
 * @returns {{ ok: boolean, differences: Array }}
 */
export function diffAlertPlane(livePolicies, expected = expectedPolicySet()) {
  if (!Array.isArray(livePolicies)) {
    return {
      ok: false,
      differences: [
        { kind: "bad-snapshot", detail: "live snapshot is not a JSON array of policies" },
      ],
    };
  }

  const differences = [];
  const liveByName = new Map();
  for (const policy of livePolicies) {
    const name = policy?.displayName;
    if (!name) continue;
    const bucket = liveByName.get(name) || [];
    bucket.push(policy);
    liveByName.set(name, bucket);
  }

  const expectedNames = new Set(expected.map((p) => p.displayName));

  for (const want of expected) {
    const matches = liveByName.get(want.displayName) || [];
    if (matches.length === 0) {
      differences.push({ kind: "missing", displayName: want.displayName });
      continue;
    }
    if (matches.length > 1) {
      differences.push({
        kind: "duplicate",
        displayName: want.displayName,
        count: matches.length,
      });
    }
    const live = liveView(matches[0]);
    if (!live.enabled) {
      differences.push({ kind: "disabled", displayName: want.displayName });
    }
    if (live.combiner !== want.combiner) {
      differences.push({
        kind: "combiner",
        displayName: want.displayName,
        desired: want.combiner,
        live: live.combiner,
      });
    }
    const wantConds = new Set(want.conditionSet);
    const liveConds = new Set(live.conditionSet);
    const missingConds = want.conditionSet.filter((c) => !liveConds.has(c));
    const extraConds = live.conditionSet.filter((c) => !wantConds.has(c));
    if (missingConds.length > 0 || extraConds.length > 0) {
      differences.push({
        kind: "conditions",
        displayName: want.displayName,
        missingFromLive: missingConds.map((c) => JSON.parse(c)),
        extraInLive: extraConds.map((c) => JSON.parse(c)),
      });
    }
  }

  // Managed-set drift: an openburnbar-labelled policy live that the manifest does
  // not declare (created out-of-band; not reproducible from the repo).
  for (const [name, bucket] of liveByName) {
    if (expectedNames.has(name)) continue;
    const managed = bucket.some((p) => p.userLabels?.app === MANAGED_APP_LABEL);
    if (managed) {
      differences.push({ kind: "unmanaged", displayName: name });
    }
  }

  return { ok: differences.length === 0, differences };
}

/** Human-readable rendering of the diff for CI logs. */
export function formatDifferences(result) {
  if (result.ok) {
    return "MATCH: live Cloud Monitoring alert policies equal the repo manifest (ops-alert-policy-definitions.mjs)";
  }
  const lines = [
    "DRIFT: live Cloud Monitoring alert policies diverge from the repo manifest (ops-alert-policy-definitions.mjs)",
  ];
  for (const diff of result.differences) {
    switch (diff.kind) {
      case "bad-snapshot":
        lines.push(`  [drift] ${diff.detail}`);
        break;
      case "missing":
        lines.push(`  [drift] policy MISSING live: ${JSON.stringify(diff.displayName)}`);
        break;
      case "duplicate":
        lines.push(`  [drift] policy DUPLICATED live (${diff.count}x): ${JSON.stringify(diff.displayName)}`);
        break;
      case "disabled":
        lines.push(`  [drift] policy DISABLED live: ${JSON.stringify(diff.displayName)}`);
        break;
      case "combiner":
        lines.push(
          `  [drift] combiner drift for ${JSON.stringify(diff.displayName)}: desired=${diff.desired} live=${diff.live}`,
        );
        break;
      case "conditions":
        if (diff.missingFromLive.length > 0) {
          lines.push(
            `  [drift] ${JSON.stringify(diff.displayName)} conditions MISSING live: ${JSON.stringify(diff.missingFromLive)}`,
          );
        }
        if (diff.extraInLive.length > 0) {
          lines.push(
            `  [drift] ${JSON.stringify(diff.displayName)} conditions EXTRA live: ${JSON.stringify(diff.extraInLive)}`,
          );
        }
        break;
      case "unmanaged":
        lines.push(
          `  [drift] openburnbar-labelled policy live but NOT in manifest (out-of-band): ${JSON.stringify(diff.displayName)}`,
        );
        break;
      default:
        lines.push(`  [drift] ${JSON.stringify(diff)}`);
    }
  }
  return lines.join("\n");
}
