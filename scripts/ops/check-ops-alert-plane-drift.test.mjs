#!/usr/bin/env node
/**
 * Self-test for scripts/ops/check-ops-alert-plane-drift.mjs and its diff lib.
 *
 * OFFLINE (no gcloud / no network):
 *   1. Unit-diff the pure primitives in scripts/lib/ops-alert-plane-drift.mjs:
 *      a manifest-faithful snapshot reports MATCH; each drift (missing, disabled,
 *      duplicated, mutated combiner/condition, extra condition, out-of-band
 *      openburnbar policy, empty plane) reports DRIFT; an unrelated foreign policy
 *      is ignored; a filter with reordered clauses still MATCHes (normalization).
 *   2. Drive the CLI end-to-end via `--self-test` and via `--live <file>`,
 *      asserting exit 0 on MATCH and exit 1 on DRIFT.
 *
 * Run:  node --test scripts/ops/check-ops-alert-plane-drift.test.mjs
 *   or: node scripts/ops/check-ops-alert-plane-drift.mjs --self-test
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { diffAlertPlane, expectedPolicySet } from "../lib/ops-alert-plane-drift.mjs";
import {
  OPS_ALERT_POLICIES,
  materializeOpsAlertPolicy,
} from "../../functions/scripts/ops-alert-policy-definitions.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const CLI = join(HERE, "check-ops-alert-plane-drift.mjs");

function manifestSnapshot() {
  // Deep-clone: materializeOpsAlertPolicy shallow-spreads, so `conditions` aliases
  // the OPS_ALERT_POLICIES module singleton. Cloning keeps each fixture mutation
  // (threshold/filter bumps below) from corrupting the shared source — and thus
  // expectedPolicySet() — across tests.
  return OPS_ALERT_POLICIES.map((policy) =>
    structuredClone({
      name: `projects/burnbar/alertPolicies/${policy.displayName.replace(/\W+/g, "-")}`,
      ...materializeOpsAlertPolicy(policy, ["projects/burnbar/notificationChannels/1"]),
    }),
  );
}

test("manifest-faithful snapshot reports MATCH", () => {
  const result = diffAlertPlane(manifestSnapshot(), expectedPolicySet());
  assert.equal(result.ok, true, JSON.stringify(result.differences, null, 2));
});

test("missing / disabled / duplicated / mutated policies report DRIFT", () => {
  const cases = {
    missing: (snap) => snap.slice(1),
    disabled: (snap) => {
      snap[0].enabled = false;
      return snap;
    },
    duplicated: (snap) => {
      snap.push(structuredClone(snap[0]));
      return snap;
    },
    combiner: (snap) => {
      snap[0].combiner = "AND";
      return snap;
    },
    threshold: (snap) => {
      const p = snap.find((x) => x.conditions?.[0]?.conditionThreshold);
      p.conditions[0].conditionThreshold.thresholdValue += 7;
      return snap;
    },
    filter: (snap) => {
      const p = snap.find((x) => x.conditions?.[0]?.conditionThreshold);
      p.conditions[0].conditionThreshold.filter += ' AND resource.labels.x="y"';
      return snap;
    },
    aggregation: (snap) => {
      const p = snap.find((x) => x.conditions?.[0]?.conditionThreshold);
      p.conditions[0].conditionThreshold.aggregations = [
        {
          alignmentPeriod: "300s",
          perSeriesAligner: "ALIGN_RATE",
          crossSeriesReducer: "REDUCE_SUM",
        },
      ];
      return snap;
    },
    trigger: (snap) => {
      const p = snap.find((x) => x.conditions?.[0]?.conditionThreshold);
      p.conditions[0].conditionThreshold.trigger = { count: 2 };
      return snap;
    },
  };
  for (const [label, mutate] of Object.entries(cases)) {
    const result = diffAlertPlane(mutate(manifestSnapshot()), expectedPolicySet());
    assert.equal(result.ok, false, `${label} should have reported DRIFT`);
  }
});

test("out-of-band openburnbar policy is flagged; foreign policy is ignored", () => {
  const withRogue = manifestSnapshot();
  withRogue.push({
    name: "projects/burnbar/alertPolicies/rogue",
    displayName: "OpenBurnBar Rogue",
    enabled: true,
    combiner: "OR",
    conditions: [],
    userLabels: { app: "openburnbar" },
  });
  const rogueResult = diffAlertPlane(withRogue, expectedPolicySet());
  assert.equal(rogueResult.ok, false);
  assert.ok(rogueResult.differences.some((d) => d.kind === "unmanaged"));

  const withForeign = manifestSnapshot();
  withForeign.push({
    name: "projects/burnbar/alertPolicies/foreign",
    displayName: "Some Other Team Policy",
    enabled: true,
    combiner: "OR",
    conditions: [],
    userLabels: { app: "someoneelse" },
  });
  const foreignResult = diffAlertPlane(withForeign, expectedPolicySet());
  assert.equal(foreignResult.ok, true, JSON.stringify(foreignResult.differences, null, 2));
});

test("filter clause reordering still MATCHes (normalization is order-independent)", () => {
  const snap = manifestSnapshot();
  const p = snap.find((x) => x.conditions?.[0]?.conditionThreshold?.filter?.includes(" AND "));
  assert.ok(p, "need a policy whose filter has multiple AND clauses");
  const filter = p.conditions[0].conditionThreshold.filter;
  const reordered = filter.split(/\s+AND\s+/i).reverse().join(" AND ");
  assert.notEqual(reordered, filter, "reversed filter should differ textually");
  p.conditions[0].conditionThreshold.filter = reordered;
  const result = diffAlertPlane(snap, expectedPolicySet());
  assert.equal(result.ok, true, JSON.stringify(result.differences, null, 2));
});

test("empty plane and non-array snapshot report DRIFT", () => {
  assert.equal(diffAlertPlane([], expectedPolicySet()).ok, false);
  assert.equal(diffAlertPlane({ not: "array" }, expectedPolicySet()).ok, false);
});

test("CLI --self-test exits 0", () => {
  const run = spawnSync(process.execPath, [CLI, "--self-test"], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /PASS: ops alert-plane drift self-test/);
});

test("CLI --live exits 0 on MATCH and 1 on DRIFT", () => {
  const dir = mkdtempSync(join(tmpdir(), "alert-drift-cli-"));
  try {
    const matchFile = join(dir, "match.json");
    const driftFile = join(dir, "drift.json");
    writeFileSync(matchFile, JSON.stringify(manifestSnapshot()));
    writeFileSync(driftFile, JSON.stringify(manifestSnapshot().slice(1)));

    const ok = spawnSync(process.execPath, [CLI, "--live", matchFile], { encoding: "utf8" });
    assert.equal(ok.status, 0, ok.stdout + ok.stderr);
    assert.match(ok.stdout, /MATCH/);

    const bad = spawnSync(process.execPath, [CLI, "--live", driftFile], { encoding: "utf8" });
    assert.equal(bad.status, 1, bad.stdout + bad.stderr);
    assert.match(bad.stdout, /DRIFT/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
