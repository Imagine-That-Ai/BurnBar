#!/usr/bin/env node
/**
 * Fail-closed drift check: the LIVE Artifact Registry cleanup policies vs the
 * committed contract in governance/ops-artifact-retention.json (Wave 1.5).
 *
 * Cloud Run revision-pin rollback needs the previous revision's container
 * image to still exist. The Firebase-default firebase-functions-cleanup
 * policy deletes every image older than 24h, so without a KEEP
 * mostRecentVersions policy the rollback path silently rots within a day;
 * the 2026-09-23 drill measured zero servable previous revisions in both
 * projects. If the retention policy is removed or weakened out of band,
 * rollback is silently dead; this check makes that a loud red.
 *
 * Modes:
 *   (default, CI)  `gcloud artifacts repositories describe gcf-artifacts
 *                  --location=us-central1 --project=<each committed project>
 *                  --format=json`, then diff. Needs gcloud auth with
 *                  roles/artifactregistry.reader (the ops-verifier WIF has it).
 *   --live <file>  Diff a saved JSON snapshot instead (offline, used by the self-test).
 *                  Shape: { "<project>": <describe-json>, ... }.
 *   --self-test    Prove the diff reports MATCH for a faithful snapshot and DRIFT for
 *                  every mutation this guard exists to catch.
 *
 * Exit codes: 0 MATCH · 1 DRIFT · 2 could not read live/committed state.
 */
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const COMMITTED_PATH = join(HERE, "..", "..", "governance", "ops-artifact-retention.json");

export function loadCommitted(path = COMMITTED_PATH) {
  return JSON.parse(readFileSync(path, "utf8"));
}

export function diffRetentionPolicies(committed, liveByProject) {
  const differences = [];
  const projects = committed.projects ?? [];
  if (projects.length === 0) {
    return { ok: false, differences: ["committed contract names no projects"] };
  }
  for (const project of projects) {
    const live = liveByProject?.[project];
    const policies = live?.cleanupPolicies ?? null;
    if (policies === null || typeof policies !== "object") {
      differences.push(`${project}: live repository describe is missing cleanupPolicies`);
      continue;
    }
    for (const required of committed.requiredPolicies ?? []) {
      const livePolicy = policies[required.name];
      if (!livePolicy) {
        differences.push(`${project}: required policy "${required.name}" is missing live`);
        continue;
      }
      const liveAction = String(livePolicy.action ?? "").toUpperCase();
      if (liveAction !== required.action) {
        differences.push(`${project}: policy "${required.name}" action is live ${liveAction || "unset"}, committed ${required.action}`);
        continue;
      }
      if (required.keepCount !== undefined) {
        const liveKeep = Number(livePolicy.mostRecentVersions?.keepCount);
        if (!Number.isFinite(liveKeep)) {
          differences.push(`${project}: policy "${required.name}" has no mostRecentVersions.keepCount live`);
        } else if (liveKeep < required.keepCount) {
          differences.push(`${project}: policy "${required.name}" keepCount is live ${liveKeep}, committed floor ${required.keepCount}`);
        }
      }
    }
  }
  return { ok: differences.length === 0, differences };
}

export function formatResult(committed, result) {
  if (result.ok) {
    return `MATCH: live gcf-artifacts cleanup policies equal governance/ops-artifact-retention.json (${committed.projects.join(", ")})`;
  }
  return [
    `DRIFT: live gcf-artifacts cleanup policies vs governance/ops-artifact-retention.json`,
    ...result.differences.map((difference) => `  - ${difference}`),
    "  The committed file wins: re-apply the retention policy (see launch-evidence/rollback-drill-2026-09-23.json fixApplied.reversibleWith for the inverse), or change the file in a reviewed PR.",
  ].join("\n");
}

/** A live describe-output that is faithful to the committed contract (test fixture). */
export function faithfulSnapshot(committed) {
  const snapshot = {};
  for (const project of committed.projects) {
    const cleanupPolicies = {
      "firebase-functions-cleanup": {
        id: "firebase-functions-cleanup",
        action: "DELETE",
        condition: { olderThan: "86400s", tagState: "ANY" },
      },
    };
    for (const required of committed.requiredPolicies) {
      cleanupPolicies[required.name] = {
        id: required.name,
        action: required.action,
        mostRecentVersions: { keepCount: required.keepCount },
      };
    }
    snapshot[project] = { name: `projects/${project}/locations/${committed.location}/repositories/${committed.repository}`, cleanupPolicies };
  }
  return snapshot;
}

function fetchLive(committed) {
  const liveByProject = {};
  for (const project of committed.projects) {
    const result = spawnSync(
      "gcloud",
      ["artifacts", "repositories", "describe", committed.repository, `--location=${committed.location}`, `--project=${project}`, "--format=json"],
      { encoding: "utf8" },
    );
    if (result.status !== 0) {
      return { ok: false, error: `${project}: ${result.stderr || result.stdout || result.error?.message || "gcloud failed"}` };
    }
    try {
      liveByProject[project] = JSON.parse(result.stdout || "{}");
    } catch (error) {
      return { ok: false, error: `${project}: unparseable gcloud output: ${error.message}` };
    }
  }
  return { ok: true, liveByProject };
}

function selfTest() {
  const committed = loadCommitted();
  const failures = [];
  const check = (label, live, expectOk) => {
    const result = diffRetentionPolicies(committed, live);
    if (result.ok !== expectOk) failures.push(`${label}: expected ${expectOk ? "MATCH" : "DRIFT"}, got ${result.ok ? "MATCH" : "DRIFT"}`);
  };
  check("faithful snapshot", faithfulSnapshot(committed), true);
  const firstProject = committed.projects[0];
  const mutate = (apply) => { const snapshot = faithfulSnapshot(committed); apply(snapshot[firstProject].cleanupPolicies); return snapshot; };
  check("retention policy removed", mutate((policies) => { delete policies["rollback-retention"]; }), false);
  check("keepCount lowered", mutate((policies) => { policies["rollback-retention"].mostRecentVersions.keepCount = 1; }), false);
  check("action flipped to DELETE", mutate((policies) => { policies["rollback-retention"].action = "DELETE"; }), false);
  check("keepCount missing", mutate((policies) => { delete policies["rollback-retention"].mostRecentVersions; }), false);
  const noBlock = faithfulSnapshot(committed);
  delete noBlock[firstProject].cleanupPolicies;
  check("cleanupPolicies block missing", noBlock, false);
  const missingProject = faithfulSnapshot(committed);
  delete missingProject[firstProject];
  check("project describe missing", missingProject, false);
  // keepCount above the floor must still match (floor, not exact).
  check("keepCount raised", mutate((policies) => { policies["rollback-retention"].mostRecentVersions.keepCount = 10; }), true);
  if (failures.length > 0) {
    console.error("FAIL: artifact retention drift self-test");
    for (const failure of failures) console.error(`  - ${failure}`);
    return 1;
  }
  console.log("PASS: artifact retention drift self-test (2 positive controls + 6 drift controls)");
  return 0;
}

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--self-test") args.selfTest = true;
    else if (argv[index] === "--live") args.live = argv[index + 1], index += 1;
    else { console.error(`unknown argument: ${argv[index]}`); process.exit(2); }
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.selfTest) process.exit(selfTest());
  const committed = loadCommitted();
  let liveByProject;
  if (args.live) {
    try {
      liveByProject = JSON.parse(readFileSync(args.live, "utf8"));
    } catch (error) {
      console.error(`could not read live snapshot: ${error.message}`);
      process.exit(2);
    }
  } else {
    const fetched = fetchLive(committed);
    if (!fetched.ok) {
      console.error(`could not read live cleanup policies: ${fetched.error}`);
      process.exit(2);
    }
    liveByProject = fetched.liveByProject;
  }
  const result = diffRetentionPolicies(committed, liveByProject);
  console.log(formatResult(committed, result));
  process.exit(result.ok ? 0 : 1);
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) main();
