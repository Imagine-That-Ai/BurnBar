#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-pr-harness-aggregate-gates.mjs.
 */

import assert from "node:assert/strict";
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
const APP_WORKFLOW = ".github/workflows/app-pr-gate.yml";
const FAST_WORKFLOW = ".github/workflows/fast-feedback.yml";
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

function workflowJob(source, name) {
  const start = source.indexOf(`  ${name}:\n`);
  assert.notEqual(start, -1, `missing workflow job ${name}`);
  const remainder = source.slice(start + 2);
  const next = remainder.search(/^  [A-Za-z0-9_-]+:\n/mu);
  return next === -1
    ? source.slice(start)
    : source.slice(start, start + 2 + next);
}

function workflowStep(job, name) {
  const marker = `      - name: ${name}\n`;
  const start = job.indexOf(marker);
  assert.notEqual(start, -1, `missing workflow step ${name}`);
  const remainder = job.slice(start + marker.length);
  const next = remainder.search(/^      - (?:name:|uses:)/mu);
  return next === -1
    ? job.slice(start)
    : job.slice(start, start + marker.length + next);
}

function jobField(job, field) {
  const prefix = `    ${field}: `;
  const line = job.split("\n").find((candidate) => candidate.startsWith(prefix));
  assert.ok(line, `missing ${field} field`);
  return line.slice(prefix.length);
}

function jobNeeds(job) {
  const lines = job.split("\n");
  const scalarPrefix = "    needs: ";
  const scalar = lines.find((line) => line.startsWith(scalarPrefix));
  if (scalar) return [scalar.slice(scalarPrefix.length)];

  const start = lines.indexOf("    needs:");
  assert.notEqual(start, -1, "missing needs list");
  const needs = [];
  for (const line of lines.slice(start + 1)) {
    if (!line.startsWith("      - ")) break;
    needs.push(line.slice("      - ".length));
  }
  return needs;
}

function stepEnvironment(step) {
  const lines = step.split("\n");
  const start = lines.indexOf("        env:");
  assert.notEqual(start, -1, "missing step environment");
  const values = {};
  for (const line of lines.slice(start + 1)) {
    const match = /^ {10}([A-Z0-9_]+): (.+)$/u.exec(line);
    if (!match) break;
    values[match[1]] = match[2];
  }
  return values;
}

function stepScript(step) {
  const marker = "        run: |\n";
  const start = step.indexOf(marker);
  assert.notEqual(start, -1, "missing multiline run script");
  const script = [];
  for (const line of step.slice(start + marker.length).split("\n")) {
    if (!line.startsWith("          ")) break;
    script.push(line.slice(10));
  }
  assert.ok(script.length > 0, "empty multiline run script");
  return `${script.join("\n")}\n`;
}

function runShell(script, env) {
  try {
    execFileSync("bash", ["-c", script], {
      env: { ...process.env, GITHUB_STEP_SUMMARY: "/dev/null", ...env },
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

function check(label, body) {
  try {
    body();
    console.log(`  PASS ${label}`);
    passed += 1;
  } catch (error) {
    console.error(`  FAIL ${label}: ${error.stack ?? error}`);
    failed += 1;
  }
}

function expectShell(label, script, env, wantExit) {
  check(label, () => {
    assert.equal(runShell(script, env), wantExit);
  });
}

const appWorkflow = readFileSync(join(REPO_ROOT, APP_WORKFLOW), "utf8");
const appGate = workflowJob(appWorkflow, "app-pr-gate");
const appStep = workflowStep(
  appGate,
  "Require every Rust and Swift prerequisite job",
);
const appScript = stepScript(appStep);

check("App aggregate emits its exact required context once and binds both prerequisites", () => {
  assert.equal(jobField(appGate, "name"), "App build + test (AgentLens)");
  assert.equal(
    [...appWorkflow.matchAll(/^    name: App build \+ test \(AgentLens\)$/gmu)]
      .length,
    1,
  );
  assert.deepEqual(jobNeeds(appGate), ["app-build-test", "mobile-build-gate"]);
  assert.equal(jobField(appGate, "if"), "always()");
  assert.deepEqual(stepEnvironment(appStep), {
    AGENTLENS_RESULT: "${{ needs.app-build-test.result }}",
    MOBILE_RESULT: "${{ needs.mobile-build-gate.result }}",
  });
});

expectShell(
  "App aggregate passes only successful AgentLens and mobile prerequisites",
  appScript,
  { AGENTLENS_RESULT: "success", MOBILE_RESULT: "success" },
  0,
);

for (const prerequisite of ["AGENTLENS_RESULT", "MOBILE_RESULT"]) {
  for (const [resultName, result] of [
    ["missing", ""],
    ["skipped", "skipped"],
    ["cancelled", "cancelled"],
    ["failed", "failure"],
  ]) {
    expectShell(
      `App aggregate rejects ${resultName} ${prerequisite}`,
      appScript,
      {
        AGENTLENS_RESULT: "success",
        MOBILE_RESULT: "success",
        [prerequisite]: result,
      },
      1,
    );
  }
}

const fastWorkflow = readFileSync(join(REPO_ROOT, FAST_WORKFLOW), "utf8");
const rustJob = workflowJob(fastWorkflow, "rust-deny-fast");
const fastGate = workflowJob(fastWorkflow, "fast-feedback-gate");
const fastStep = workflowStep(fastGate, "Check all fast jobs passed");
const fastScript = stepScript(fastStep);
const fastNeeds = jobNeeds(fastGate);

check("Rust path detector is mandatory and only a proven unchanged path may skip Rust", () => {
  assert.deepEqual(jobNeeds(rustJob), ["fast-feedback-path-filter"]);
  assert.equal(
    jobField(rustJob, "if"),
    "always() && (needs.fast-feedback-path-filter.result != 'success' || needs.fast-feedback-path-filter.outputs.rust_changed != 'false')",
  );
  assert.equal(jobField(fastGate, "if"), "always()");
  assert.ok(fastNeeds.includes("fast-feedback-path-filter"));
  assert.ok(fastNeeds.includes("rust-deny-fast"));
  assert.equal(
    [...fastWorkflow.matchAll(/^    name: Fast Feedback Gate$/gmu)].length,
    1,
  );
  assert.equal(
    [...fastWorkflow.matchAll(/^    name: Rust \(fmt \+ clippy \+ cargo-deny\)$/gmu)]
      .length,
    1,
  );
  assert.deepEqual(stepEnvironment(fastStep), {
    NEEDS_JSON: "${{ toJSON(needs) }}",
    RUST_CHANGED:
      "${{ needs.fast-feedback-path-filter.outputs.rust_changed }}",
  });
});

function fastEnvironment({
  detectorResult = "success",
  rustChanged = "true",
  rustResult = "success",
  ordinaryResult = "success",
  omitDetectorResult = false,
  omitRustResult = false,
  omitOrdinaryResult = false,
} = {}) {
  const needs = Object.fromEntries(
    fastNeeds.map((name) => [name, { result: "success" }]),
  );
  needs["fast-feedback-path-filter"] = omitDetectorResult
    ? {}
    : { result: detectorResult };
  needs["rust-deny-fast"] = omitRustResult ? {} : { result: rustResult };
  needs["functions-fast"] = omitOrdinaryResult
    ? {}
    : { result: ordinaryResult };
  return { NEEDS_JSON: JSON.stringify(needs), RUST_CHANGED: rustChanged };
}

for (const [label, options] of [
  ["runs and passes Rust when Rust paths changed", {}],
  [
    "permits Rust skip after detector success proves rust_changed=false",
    { rustChanged: "false", rustResult: "skipped" },
  ],
  [
    "passes after Rust runs when detector output is missing",
    { rustChanged: "", rustResult: "success" },
  ],
]) {
  expectShell(`Fast aggregate ${label}`, fastScript, fastEnvironment(options), 0);
}

for (const [resultName, options] of [
  ["skipped", { rustResult: "skipped" }],
  ["failed", { rustResult: "failure" }],
  ["cancelled", { rustResult: "cancelled" }],
  ["missing", { omitRustResult: true }],
]) {
  expectShell(
    `Fast aggregate rejects ${resultName} Rust result when changes are not proven absent`,
    fastScript,
    fastEnvironment(options),
    1,
  );
}

expectShell(
  "Fast aggregate rejects skipped Rust when detector output is missing",
  fastScript,
  fastEnvironment({ rustChanged: "", rustResult: "skipped" }),
  1,
);

for (const [resultName, options] of [
  ["failed", { detectorResult: "failure" }],
  ["cancelled", { detectorResult: "cancelled" }],
  ["skipped", { detectorResult: "skipped" }],
  ["missing", { omitDetectorResult: true }],
]) {
  expectShell(
    `Fast aggregate rejects ${resultName} path detector result even after Rust succeeds`,
    fastScript,
    fastEnvironment(options),
    1,
  );
}

for (const [resultName, options] of [
  ["skipped", { ordinaryResult: "skipped" }],
  ["failed", { ordinaryResult: "failure" }],
  ["cancelled", { ordinaryResult: "cancelled" }],
  ["missing", { omitOrdinaryResult: true }],
]) {
  expectShell(
    `Fast aggregate rejects ${resultName} ordinary prerequisite result`,
    fastScript,
    fastEnvironment(options),
    1,
  );
}

if (failed > 0) {
  console.error(`\nFAIL: ${failed} PR harness aggregate gate self-test case(s) failed.`);
  process.exit(1);
}

console.log(`\nPASS: ${passed} PR harness aggregate gate self-test case(s) passed.`);
