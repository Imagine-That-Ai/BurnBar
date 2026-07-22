#!/usr/bin/env node
/**
 * Self-test for scripts/ops/check-branch-protection-drift.mjs and its diff lib.
 *
 * Two layers, both OFFLINE (no gh / no network):
 *   1. Unit-diff the pure primitives in scripts/lib/branch-protection-drift.mjs
 *      (canonicalize + diff) for the ruleset shape, the classic shape, and the
 *      union-of-both shape — proving MATCH on a faithful mirror and DRIFT on each
 *      dangerous mutation.
 *   2. Drive the CLI end-to-end via `--self-test` and via `--live-ruleset`/
 *      `--live-classic` fixture files, asserting exit 0 on MATCH and exit 1 on
 *      DRIFT — proving the wired script (not just the lib) gates correctly.
 *
 * Run:  node --test scripts/ops/check-branch-protection-drift.test.mjs
 *   or: node scripts/ops/check-branch-protection-drift.mjs --self-test
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  canonicalizeDesired,
  canonicalizeLive,
  diffBranchProtection,
  loadDesired,
} from "../lib/branch-protection-drift.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const CLI = join(HERE, "check-branch-protection-drift.mjs");
const desiredJson = loadDesired();
const desired = canonicalizeDesired(desiredJson);

function matchingRuleset() {
  const contexts = desiredJson.required_status_checks.contexts;
  return {
    enforcement: "active",
    bypass_actors: [],
    rules: [
      {
        type: "required_status_checks",
        ruleset_id: 42,
        parameters: {
          strict_required_status_checks_policy:
            desiredJson.required_status_checks.strict === true,
          required_status_checks: contexts.map((context) => ({ context })),
        },
      },
      {
        type: "pull_request",
        ruleset_id: 42,
        parameters: {
          required_approving_review_count:
            desiredJson.required_pull_request_reviews.required_approving_review_count,
          require_code_owner_review:
            desiredJson.required_pull_request_reviews.require_code_owner_reviews === true,
          dismiss_stale_reviews_on_push:
            desiredJson.required_pull_request_reviews.dismiss_stale_reviews === true,
          require_last_push_approval:
            desiredJson.required_pull_request_reviews.require_last_push_approval === true,
        },
      },
      { type: "required_conversation_resolution", ruleset_id: 42 },
      { type: "non_fast_forward", ruleset_id: 42 },
      { type: "deletion", ruleset_id: 42 },
    ],
  };
}

function matchingClassic() {
  const contexts = desiredJson.required_status_checks.contexts;
  return {
    required_status_checks: {
      strict: desiredJson.required_status_checks.strict === true,
      contexts,
    },
    enforce_admins: { enabled: true },
    required_pull_request_reviews: {
      required_approving_review_count:
        desiredJson.required_pull_request_reviews.required_approving_review_count,
      require_code_owner_reviews:
        desiredJson.required_pull_request_reviews.require_code_owner_reviews === true,
      dismiss_stale_reviews:
        desiredJson.required_pull_request_reviews.dismiss_stale_reviews === true,
      require_last_push_approval:
        desiredJson.required_pull_request_reviews.require_last_push_approval === true,
      bypass_pull_request_allowances: { users: [], teams: [], apps: [] },
    },
    required_conversation_resolution: { enabled: true },
    allow_force_pushes: { enabled: false },
    allow_deletions: { enabled: false },
  };
}

test("ruleset mirror of the file reports MATCH", () => {
  const live = canonicalizeLive({ ruleset: matchingRuleset() });
  const result = diffBranchProtection(live, desired);
  assert.equal(result.ok, true, JSON.stringify(result.differences, null, 2));
});

test("classic mirror of the file reports MATCH", () => {
  const live = canonicalizeLive({ classic: matchingClassic() });
  const result = diffBranchProtection(live, desired);
  assert.equal(result.ok, true, JSON.stringify(result.differences, null, 2));
});

test("merge-queue-only ruleset layers over classic governance", () => {
  const live = canonicalizeLive({
    classic: matchingClassic(),
    ruleset: {
      enforcement: "active",
      bypass_actors: [],
      rules: [{ type: "merge_queue", ruleset_id: 99, parameters: { merge_method: "squash" } }],
    },
  });
  const result = diffBranchProtection(live, desired);
  assert.equal(result.ok, true, JSON.stringify(result.differences, null, 2));
});

test("empty live protection (nothing enforcing main) reports DRIFT with critical reviews-wiped", () => {
  const live = canonicalizeLive({ classic: null, ruleset: null });
  const result = diffBranchProtection(live, desired);
  assert.equal(result.ok, false);
  assert.ok(
    result.differences.some((d) => d.field === "reviewsPresent" && d.severity === "critical"),
    "reviews-wiped must be critical",
  );
});

test("ruleset-only bypass actor is caught even when classic protection looks clean", () => {
  // Classic endpoint returns a fully-clean protection, but the org ruleset carries
  // a bypass actor. Reading classic alone would MISS this — the union must catch it.
  const live = canonicalizeLive({
    classic: matchingClassic(),
    ruleset: {
      ...matchingRuleset(),
      bypass_actors: [{ actor_id: 99, actor_type: "Team", bypass_mode: "always" }],
    },
  });
  const result = diffBranchProtection(live, desired);
  assert.equal(result.ok, false);
  const bypass = result.differences.find((d) => d.field === "bypassActors");
  assert.ok(bypass && bypass.added.length === 1 && bypass.severity === "critical");
});

test("each dangerous mutation reports DRIFT", () => {
  const mutations = {
    reviewsWiped: (r) => {
      r.rules = r.rules.filter((x) => x.type !== "pull_request");
    },
    reviewCountChanged: (r) => {
      r.rules.find((x) => x.type === "pull_request").parameters.required_approving_review_count =
        desiredJson.required_pull_request_reviews.required_approving_review_count + 1;
    },
    codeOwnerChanged: (r) => {
      r.rules.find((x) => x.type === "pull_request").parameters.require_code_owner_review =
        desiredJson.required_pull_request_reviews.require_code_owner_reviews !== true;
    },
    forcePushAllowed: (r) => {
      r.rules = r.rules.filter((x) => x.type !== "non_fast_forward");
    },
    deletionAllowed: (r) => {
      r.rules = r.rules.filter((x) => x.type !== "deletion");
    },
    convoResolutionOff: (r) => {
      r.rules = r.rules.filter((x) => x.type !== "required_conversation_resolution");
    },
    requiredCheckDropped: (r) => {
      const rule = r.rules.find((x) => x.type === "required_status_checks");
      rule.parameters.required_status_checks = rule.parameters.required_status_checks.slice(1);
    },
    extraCheckAdded: (r) => {
      const rule = r.rules.find((x) => x.type === "required_status_checks");
      rule.parameters.required_status_checks.push({ context: "Rogue Gate" });
    },
    strictToggled: (r) => {
      const rule = r.rules.find((x) => x.type === "required_status_checks");
      rule.parameters.strict_required_status_checks_policy =
        !desiredJson.required_status_checks.strict;
    },
  };
  for (const [label, mutate] of Object.entries(mutations)) {
    const ruleset = matchingRuleset();
    mutate(ruleset);
    const live = canonicalizeLive({ ruleset });
    const result = diffBranchProtection(live, desired);
    assert.equal(result.ok, false, `${label} should have reported DRIFT`);
  }
});

test("CLI --self-test exits 0", () => {
  const run = spawnSync(process.execPath, [CLI, "--self-test"], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /PASS: branch-protection drift self-test/);
});

test("CLI --live-ruleset exits 0 on MATCH and 1 on DRIFT", () => {
  const dir = mkdtempSync(join(tmpdir(), "bp-drift-cli-"));
  try {
    const matchFile = join(dir, "match.json");
    const driftFile = join(dir, "drift.json");
    writeFileSync(matchFile, JSON.stringify(matchingRuleset()));
    const drifted = matchingRuleset();
    drifted.bypass_actors = [{ actor_id: 1, actor_type: "Integration", bypass_mode: "always" }];
    writeFileSync(driftFile, JSON.stringify(drifted));

    const ok = spawnSync(process.execPath, [CLI, "--live-ruleset", matchFile], { encoding: "utf8" });
    assert.equal(ok.status, 0, ok.stdout + ok.stderr);
    assert.match(ok.stdout, /MATCH/);

    const bad = spawnSync(process.execPath, [CLI, "--live-ruleset", driftFile], { encoding: "utf8" });
    assert.equal(bad.status, 1, bad.stdout + bad.stderr);
    assert.match(bad.stdout, /DRIFT/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
