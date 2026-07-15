#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-pr-harness-aggregate-gates.mjs.
 */

import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, "..", "..");
const GATE = join(SCRIPT_DIR, "verify-pr-harness-aggregate-gates.mjs");
const WORKFLOW = ".github/workflows/openburnbar-pr-harness.yml";
const roots = [];

process.on("exit", () => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

function buildTree(mutator = () => {}) {
  const root = mkdtempSync(join(tmpdir(), "pr-harness-aggregate-gate-"));
  roots.push(root);
  mkdirSync(join(root, ".github", "workflows"), { recursive: true });
  copyFileSync(join(REPO_ROOT, WORKFLOW), join(root, WORKFLOW));
  mutator(root);
  return root;
}

function mutate(root, edit) {
  const path = join(root, WORKFLOW);
  const original = readFileSync(path, "utf8");
  const updated = edit(original);
  if (updated === original) throw new Error("mutation did not change workflow");
  writeFileSync(path, updated);
}

function runGate(root) {
  try {
    execFileSync("node", [GATE], {
      env: { ...process.env, PR_HARNESS_AGGREGATE_GATE_ROOT: root },
      stdio: "pipe",
    });
    return 0;
  } catch (error) {
    return error.status ?? 1;
  }
}

let passed = 0;
let failed = 0;

function expect(label, mutator, wantExit) {
  const root = buildTree(mutator);
  const got = runGate(root);
  if (got === wantExit) {
    console.log(`  PASS ${label} (exit ${got})`);
    passed += 1;
  } else {
    console.error(`  FAIL ${label}: expected exit ${wantExit}, got ${got}`);
    failed += 1;
  }
}

console.log("Self-test: verify-pr-harness-aggregate-gates.mjs\n");

expect("current PR harness aggregate gates pass", () => {}, 0);

for (const job of ["platform-confidence-gate", "targeted-e2e-gate", "harness-required", "harness-informational", "openburnbar-pr"]) {
  expect(
    `${job} with !cancelled() fails`,
    (root) =>
      mutate(root, (text) =>
        text.replace(
          new RegExp(`(  ${job}:[\\s\\S]*?\\n    if: )always\\(\\)`, "u"),
          "$1always() && !cancelled()",
        ),
      ),
    1,
  );
}

expect(
  "missing aggregate gate fails",
  (root) =>
    mutate(root, (text) =>
      text.replace("  targeted-e2e-gate:\n    name: Targeted E2E Gate\n", ""),
    ),
  1,
);

expect(
  "gate without needs result JSON fails",
  (root) =>
    mutate(root, (text) =>
      text.replace("          results='${{ toJSON(needs) }}'\n", "          results='{}'\n"),
    ),
  1,
);

expect(
  "gate accepting cancelled upstream results fails",
  (root) =>
    mutate(root, (text) =>
      text.replace(
        "not in ('success', 'skipped')",
        "not in ('success', 'skipped', 'cancelled')",
      ),
    ),
  1,
);

if (failed > 0) {
  console.error(`\nFAIL: ${failed} PR harness aggregate gate self-test case(s) failed.`);
  process.exit(1);
}

console.log(`\nPASS: ${passed} PR harness aggregate gate self-test case(s) passed.`);
