#!/usr/bin/env node
/**
 * Structural tests for the deploy-production product-preflight contract.
 *
 * The Functions lane must run check_burnbar_release_preflight.py with the
 * owner-emergency profile (same flags as release.yml): without it the lane
 * demands full product-launch readiness (libsignal runtime cutover + signed
 * counsel) on every tag push and deadlocks — every v1.0.40+repair.40/.41 tag
 * push failed in "BurnBar product release preflight" while the app release
 * train, which passes the flags, proceeded.
 *
 * Invariants:
 *
 *  1. The product preflight invocation (the non---source-provenance-only
 *     call) passes --allow-owner-emergency-approval,
 *     --allow-owner-emergency-runtime-hold, and --expected-release-tag bound
 *     to the resolved tag output (steps.tag.outputs.tag), so the per-train
 *     owner packet is validated against the tag being deployed.
 *  2. The step still runs for real tag deploys only: the dry_run /
 *     break_glass guard is intact (dry-runs prove tag binding without
 *     claiming launch readiness; break-glass defers to the environment
 *     reviewer).
 *  3. The engagement is audited: the step records the owner-emergency
 *     profile and tag in GITHUB_STEP_SUMMARY.
 *
 * The tests use semantic anchors (specific patterns, not whole-file
 * snapshots) and include negative controls: each test also verifies that a
 * known-bad mutation would be detected.
 *
 * Usage:
 *   node scripts/ci/verify-deploy-production-preflight.test.mjs
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, "..", "..");

const DEPLOY_PRODUCTION_YML = process.env.TEST_DEPLOY_PRODUCTION_YML
  ? process.env.TEST_DEPLOY_PRODUCTION_YML
  : join(REPO_ROOT, ".github/workflows/deploy-production.yml");

const body = readFileSync(DEPLOY_PRODUCTION_YML, "utf8");

let passed = 0;
let failed = 0;

function assert(label, condition) {
  if (condition) {
    passed++;
  } else {
    failed++;
    console.error(`  FAIL: ${label}`);
  }
}

/**
 * Extract the "BurnBar product release preflight" step block: from the step
 * name line through the next same-indent "- name:" step (or EOF).
 */
function extractProductPreflightStep(workflowBody) {
  const anchor = "- name: BurnBar product release preflight";
  const start = workflowBody.indexOf(anchor);
  if (start === -1) return null;
  const rest = workflowBody.slice(start + anchor.length);
  const nextStep = rest.search(/\n      - name: /u);
  return nextStep === -1 ? rest : rest.slice(0, nextStep);
}

const step = extractProductPreflightStep(body);

assert(
  "deploy-production.yml has a BurnBar product release preflight step",
  step !== null,
);

if (step !== null) {
  // ── Invariant 1: owner-emergency profile flags + tag binding ──────────────
  assert(
    "product preflight passes --allow-owner-emergency-approval",
    step.includes("--allow-owner-emergency-approval"),
  );
  assert(
    "product preflight passes --allow-owner-emergency-runtime-hold",
    step.includes("--allow-owner-emergency-runtime-hold"),
  );
  assert(
    "product preflight binds --expected-release-tag to steps.tag.outputs.tag",
    /--expected-release-tag\s+"\$\{\{\s*steps\.tag\.outputs\.tag\s*\}\}"/u.test(
      step,
    ),
  );
  assert(
    "product preflight is the full (non-source-provenance-only) invocation",
    !step.includes("--source-provenance-only"),
  );

  // ── Invariant 2: real-tag-deploys-only guard ──────────────────────────────
  assert(
    "product preflight keeps the dry_run/break_glass guard",
    /if:\s*steps\.tag\.outputs\.dry_run\s*!=\s*'true'\s*&&\s*steps\.tag\.outputs\.break_glass\s*!=\s*'true'/u.test(
      step,
    ),
  );

  // ── Invariant 3: audited engagement ───────────────────────────────────────
  assert(
    "product preflight records the owner-emergency engagement in the step summary",
    step.includes("product-preflight=owner-emergency") &&
      step.includes("GITHUB_STEP_SUMMARY"),
  );

  // ── Negative controls: each mutation must be detected ─────────────────────
  assert(
    "negative control: dropping --allow-owner-emergency-approval is detected",
    !step
      .replace("--allow-owner-emergency-approval", "")
      .includes("--allow-owner-emergency-approval"),
  );
  assert(
    "negative control: dropping --allow-owner-emergency-runtime-hold is detected",
    !step
      .replace("--allow-owner-emergency-runtime-hold", "")
      .includes("--allow-owner-emergency-runtime-hold"),
  );
  assert(
    "negative control: unbinding --expected-release-tag is detected",
    !/--expected-release-tag\s+"\$\{\{\s*steps\.tag\.outputs\.tag\s*\}\}"/u.test(
      step.replace("steps.tag.outputs.tag", "inputs.tag"),
    ),
  );
  assert(
    "negative control: dropping the summary audit line is detected",
    !(
      step.replace("product-preflight=owner-emergency", "").includes(
        "product-preflight=owner-emergency",
      )
    ),
  );
  assert(
    "negative control: dropping the dry_run/break_glass guard is detected",
    !/if:\s*steps\.tag\.outputs\.dry_run\s*!=\s*'true'\s*&&\s*steps\.tag\.outputs\.break_glass\s*!=\s*'true'/u.test(
      step.replace("break_glass != 'true'", "break_glass != 'never'"),
    ),
  );
}

// ──────────────────────────────────────────────────────────────────────────
// Summary
// ──────────────────────────────────────────────────────────────────────────

if (failed > 0) {
  console.error(`\nFAIL: ${failed} assertion(s) failed.`);
  process.exit(1);
}

console.log(
  `\nPASS: ${passed} deploy-production preflight contract assertion(s) passed.`,
);
