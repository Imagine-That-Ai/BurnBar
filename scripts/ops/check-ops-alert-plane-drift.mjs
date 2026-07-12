#!/usr/bin/env node
/**
 * Fail-closed drift check: LIVE GCP Cloud Monitoring alert policies vs the repo
 * manifest (functions/scripts/ops-alert-policy-definitions.mjs, incl. billing).
 *
 * The alert plane is applied out-of-band (scripts/ops/activate-production-ops-plane.sh
 * -> apply-ops-alert-policies.mjs) with no CI diff-check that live GCP matches the
 * committed definitions. This script + scripts/lib/ops-alert-plane-drift.mjs are
 * that check: any divergence (a policy missing, disabled, mutated conditions, an
 * out-of-band openburnbar policy) exits non-zero with a readable diff.
 *
 * This is DISTINCT from scripts/ops/check-ops-alerts.mjs: that gate proves the
 * policies are present + enabled + backed by a LIVE notification channel (runtime
 * readiness). This gate proves live policy DEFINITIONS match the repo (config
 * drift), including catching out-of-band edits and extra unmanaged policies.
 *
 * Modes:
 *   (default, CI)  Snapshot live policies with gcloud and diff. Needs gcloud auth.
 *                  Runs in ops-plane-verify.yml with creds.
 *     env GCLOUD_PROJECT / GOOGLE_CLOUD_PROJECT   project (default: burnbar)
 *
 *   --live <file>  Diff a provided snapshot (the JSON array from
 *                  `gcloud monitoring policies list --format=json`) instead of
 *                  calling gcloud. Used by the offline self-test and local repro.
 *
 *   --self-test    Offline positive+negative controls; exits 0/1. Lets CI gate the
 *                  script itself with no cloud access.
 *
 * Exit: 0 = MATCH (or self-test passed); 1 = DRIFT (or self-test failed);
 *       2 = could not read live state / bad usage.
 */
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import {
  diffAlertPlane,
  expectedPolicySet,
  formatDifferences,
} from "../lib/ops-alert-plane-drift.mjs";
import {
  OPS_ALERT_POLICIES,
  materializeOpsAlertPolicy,
} from "../../functions/scripts/ops-alert-policy-definitions.mjs";

function parseArgs(argv) {
  const args = { live: null, selfTest: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--self-test") args.selfTest = true;
    else if (arg === "--live") args.live = argv[++i];
    else {
      console.error(`unknown argument: ${arg}`);
      process.exit(2);
    }
  }
  return args;
}

function project() {
  return process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || "burnbar";
}

function fetchLive() {
  const result = spawnSync(
    "gcloud",
    ["monitoring", "policies", "list", `--project=${project()}`, "--format=json"],
    { encoding: "utf8", timeout: 120_000 },
  );
  if (result.status !== 0) {
    return {
      ok: false,
      error: result.stderr || result.stdout || result.error?.message || "gcloud failed",
    };
  }
  try {
    return { ok: true, policies: JSON.parse(result.stdout || "[]") };
  } catch (error) {
    return { ok: false, error: `unparseable gcloud output: ${error.message}` };
  }
}

/**
 * Build a faithful LIVE snapshot from the manifest — i.e. exactly what
 * apply-ops-alert-policies.mjs would push. Used by the self-test as the
 * zero-drift positive control.
 */
function snapshotFromManifest() {
  return OPS_ALERT_POLICIES.map((policy) => {
    const materialized = materializeOpsAlertPolicy(policy, [
      "projects/burnbar/notificationChannels/1",
    ]);
    // gcloud-listed policies also carry a resource name; include one so the view
    // resembles real output (the diff ignores it). Deep-clone: the materializer
    // shallow-spreads, so nested `conditions` alias the OPS_ALERT_POLICIES
    // singleton; cloning keeps the self-test's per-case mutations from corrupting
    // the shared source (and thus expectedPolicySet()).
    return structuredClone({
      name: `projects/burnbar/alertPolicies/${policy.displayName.replace(/\W+/g, "-")}`,
      ...materialized,
    });
  });
}

// ── Offline self-test ──────────────────────────────────────────────────────
function selfTest() {
  const failures = [];
  const expected = expectedPolicySet();

  function expect(label, snapshot, wantOk) {
    const result = diffAlertPlane(snapshot, expected);
    if (result.ok !== wantOk) {
      failures.push(
        `${label}: expected ${wantOk ? "MATCH" : "DRIFT"} but got ${result.ok ? "MATCH" : "DRIFT"}\n${formatDifferences(result)}`,
      );
    }
  }

  // 1. Positive control: a faithful render of the manifest reports MATCH.
  expect("identical-manifest", snapshotFromManifest(), true);

  // 2. Negative controls.
  const mutations = {
    "policy-missing": (snap) => snap.slice(1),
    "policy-disabled": (snap) => {
      const copy = structuredClone(snap);
      copy[0].enabled = false;
      return copy;
    },
    "policy-duplicated": (snap) => {
      const copy = structuredClone(snap);
      copy.push(structuredClone(copy[0]));
      return copy;
    },
    "combiner-mutated": (snap) => {
      const copy = structuredClone(snap);
      copy[0].combiner = "AND";
      return copy;
    },
    "condition-threshold-mutated": (snap) => {
      const copy = structuredClone(snap);
      const cond = copy.find((p) => p.conditions?.[0]?.conditionThreshold);
      cond.conditions[0].conditionThreshold.thresholdValue += 1;
      return copy;
    },
    "condition-filter-mutated": (snap) => {
      const copy = structuredClone(snap);
      const cond = copy.find((p) => p.conditions?.[0]?.conditionThreshold);
      cond.conditions[0].conditionThreshold.filter += ' AND resource.labels.tampered="yes"';
      return copy;
    },
    "extra-condition-added": (snap) => {
      const copy = structuredClone(snap);
      const target = copy[0];
      target.conditions.push({
        displayName: "rogue",
        conditionThreshold: {
          filter: 'metric.type="rogue"',
          comparison: "COMPARISON_GT",
          thresholdValue: 1,
          duration: "60s",
        },
      });
      return copy;
    },
    "out-of-band-openburnbar-policy": (snap) => {
      const copy = structuredClone(snap);
      copy.push({
        name: "projects/burnbar/alertPolicies/rogue",
        displayName: "OpenBurnBar Rogue out-of-band policy",
        enabled: true,
        combiner: "OR",
        conditions: [],
        userLabels: { app: "openburnbar" },
      });
      return copy;
    },
    "empty-live-plane": () => [],
    "bad-snapshot-not-array": () => ({ not: "an array" }),
  };
  for (const [label, mutate] of Object.entries(mutations)) {
    expect(label, mutate(snapshotFromManifest()), false);
  }

  // 3. Clean control: an UNRELATED (non-openburnbar) live policy must NOT trip the
  //    gate — we only manage our own labelled policies.
  const withForeign = snapshotFromManifest();
  withForeign.push({
    name: "projects/burnbar/alertPolicies/foreign",
    displayName: "Some Other Team Policy",
    enabled: true,
    combiner: "OR",
    conditions: [],
    userLabels: { app: "someoneelse" },
  });
  expect("foreign-policy-ignored", withForeign, true);

  if (failures.length > 0) {
    console.error("FAIL: ops alert-plane drift self-test");
    for (const failure of failures) console.error(`  - ${failure}`);
    return 1;
  }
  console.log(
    `PASS: ops alert-plane drift self-test (2 positive controls + ${Object.keys(mutations).length} drift controls)`,
  );
  return 0;
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.selfTest) {
    process.exit(selfTest());
  }

  let livePolicies;
  if (args.live) {
    try {
      livePolicies = JSON.parse(readFileSync(args.live, "utf8"));
    } catch (error) {
      console.error(`could not read live snapshot: ${error.message}`);
      process.exit(2);
    }
  } else {
    const fetched = fetchLive();
    if (!fetched.ok) {
      console.error(`could not read live alert policies (project=${project()}): ${fetched.error}`);
      process.exit(2);
    }
    livePolicies = fetched.policies;
  }

  const result = diffAlertPlane(livePolicies);
  console.log(formatDifferences(result));
  process.exit(result.ok ? 0 : 1);
}

main();
