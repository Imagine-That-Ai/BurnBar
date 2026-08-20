#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-pr-harness-aggregate-gates.mjs.
 */

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
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
const DAEMON_WORKFLOW = ".github/workflows/daemon-pr-gate.yml";
const DOMAIN_CORE_WORKFLOW = ".github/workflows/domain-core.yml";
const HEADLESS_WORKFLOW = ".github/workflows/headless-app-build.yml";
const FAST_WORKFLOW = ".github/workflows/fast-feedback.yml";
const NATIVE_WORKFLOW = ".github/workflows/pr-native-fast.yml";
const SECURITY_WORKFLOW = ".github/workflows/security-pr.yml";
const BRANCH_PROTECTION = "governance/branch-protection.main.json";
const CHECKOUT_TIMEOUT_FLOOR_MINUTES = 15;
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

function workflowJobs(source) {
  const jobs = /^jobs:\s*$/mu.exec(source);
  assert.ok(jobs, "missing workflow jobs map");
  const body = source.slice(jobs.index + jobs[0].length);
  const starts = [...body.matchAll(/^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$/gmu)];
  return starts.map((match, index) => {
    const end = starts[index + 1]?.index ?? body.length;
    return [match[1], body.slice(match.index, end)];
  });
}

function workflowJob(source, name) {
  const job = workflowJobs(source).find(([candidate]) => candidate === name)?.[1];
  assert.ok(job, `missing workflow job ${name}`);
  return job;
}

function checkoutTimeoutOffenders(root) {
  const dir = join(root, ".github", "workflows");
  const offenders = [];
  for (const file of readdirSync(dir).filter((name) => /\.ya?ml$/u.test(name)).sort()) {
    const source = readFileSync(join(dir, file), "utf8");
    for (const [job, body] of workflowJobs(source)) {
      const timeout = body.match(/^    timeout-minutes:\s*(\d+)\s*$/mu);
      if (
        timeout &&
        Number.parseInt(timeout[1], 10) < CHECKOUT_TIMEOUT_FLOOR_MINUTES &&
        body.includes("actions/checkout")
      ) {
        offenders.push(`${file}:${job}=${timeout[1]}`);
      }
    }
  }
  return offenders;
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

function workflowSteps(job) {
  const steps = new Map();
  for (const match of job.matchAll(/^      - name: (.+)$/gmu)) {
    const name = match[1];
    const start = match.index;
    const remainder = job.slice(start + match[0].length);
    const next = remainder.search(/^      - (?:name:|uses:)/mu);
    steps.set(
      name,
      next === -1 ? job.slice(start) : job.slice(start, start + match[0].length + next),
    );
  }
  return steps;
}

function optionalStepField(step, field) {
  const prefix = `        ${field}: `;
  const line = step.split("\n").find((candidate) => candidate.startsWith(prefix));
  return line?.slice(prefix.length);
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
  const match = /^        run: (?:\||>-)\n/mu.exec(step);
  assert.ok(match, "missing multiline run script");
  const script = [];
  for (const line of step.slice(match.index + match[0].length).split("\n")) {
    if (!line.startsWith("          ")) break;
    script.push(line.slice(10));
  }
  assert.ok(script.length > 0, "empty multiline run script");
  return `${script.join("\n")}\n`;
}

function stepRun(step) {
  const scalar = optionalStepField(step, "run");
  return scalar === "|" || scalar === ">-" ? stepScript(step) : `${scalar}\n`;
}

function bindNeedsJSON(script) {
  const bound = script.replace(
    "results='${{ toJSON(needs) }}'",
    'results="$NEEDS_JSON"',
  );
  assert.notEqual(bound, script, "aggregate script must consume toJSON(needs)");
  return bound;
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

function needsEnvironment(names, overrideName, overrideResult) {
  const needs = Object.fromEntries(names.map((name) => [name, { result: "success" }]));
  if (overrideName) {
    needs[overrideName] = overrideResult === undefined ? {} : { result: overrideResult };
  }
  return { NEEDS_JSON: JSON.stringify(needs) };
}
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

const harnessWorkflow = readFileSync(join(REPO_ROOT, WORKFLOW), "utf8");
const harnessRequired = workflowJob(harnessWorkflow, "harness-required");
const harnessInformational = workflowJob(harnessWorkflow, "harness-informational");
const requiredNames = jobNeeds(harnessRequired);
const informationalNames = jobNeeds(harnessInformational);
const requiredScript = bindNeedsJSON(stepScript(workflowStep(
  harnessRequired,
  "Check all required (deterministic) harness jobs passed",
)));
const informationalScript = bindNeedsJSON(stepScript(workflowStep(
  harnessInformational,
  "Report informational harness job results (alerts, does not block)",
)));

expectShell(
  "Harness Required accepts successful prerequisites",
  requiredScript,
  needsEnvironment(requiredNames),
  0,
);

for (const [resultName, result] of [
  ["missing", undefined],
  ["skipped", "skipped"],
  ["cancelled", "cancelled"],
  ["neutral", "neutral"],
  ["failed", "failure"],
]) {
  expectShell(
    `Harness Required rejects ${resultName} prerequisite results`,
    requiredScript,
    needsEnvironment(requiredNames, requiredNames[0], result),
    1,
  );
}

expectShell(
  "Harness Informational permits skipped prerequisites",
  informationalScript,
  needsEnvironment(informationalNames, informationalNames[0], "skipped"),
  0,
);

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
  assert.deepEqual(jobNeeds(appGate), ["classify", "app-build-test", "mobile-build-gate"]);
  assert.equal(jobField(appGate, "if"), "always() && github.event_name != 'merge_group'");
  assert.deepEqual(stepEnvironment(appStep), {
    AGENTLENS_RESULT: "${{ needs.app-build-test.result }}",
    MOBILE_RESULT: "${{ needs.mobile-build-gate.result }}",
    CLASSIFIER_RESULT: "${{ needs.classify.result }}",
    MACOS_REQUIRED: "${{ needs.classify.outputs.macos }}",
    MOBILE_REQUIRED: "${{ needs.classify.outputs.mobile }}",
  });
});

expectShell(
  "App aggregate passes only successful AgentLens and mobile prerequisites",
  appScript,
  {
    AGENTLENS_RESULT: "success",
    MOBILE_RESULT: "success",
    CLASSIFIER_RESULT: "success",
    MACOS_REQUIRED: "true",
    MOBILE_REQUIRED: "true",
  },
  0,
);

expectShell(
  "App aggregate accepts classifier-proven product skips",
  appScript,
  {
    AGENTLENS_RESULT: "skipped",
    MOBILE_RESULT: "skipped",
    CLASSIFIER_RESULT: "success",
    MACOS_REQUIRED: "false",
    MOBILE_REQUIRED: "false",
  },
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
        CLASSIFIER_RESULT: "success",
        MACOS_REQUIRED: "true",
        MOBILE_REQUIRED: "true",
        [prerequisite]: result,
      },
      1,
    );
  }
}

const appBuildJob = workflowJob(appWorkflow, "app-build-test");
const appBuildSteps = workflowSteps(appBuildJob);
const rafStep = appBuildSteps.get("macOS rAF pause prerequisite (P-PERF-3)");
const buildStep = appBuildSteps.get("Build AgentLens app for real-process CPU gate");
const realGateStep = appBuildSteps.get("Enforce real macOS idle/occluded CPU budget (P-PERF-3)");
const evidenceStep = appBuildSteps.get("Upload macOS idle/occlusion CPU evidence");
const appTestStep = appBuildSteps.get("Build + run bounded AgentLens app smoke tests");

check("P-PERF-3 runs the deterministic rAF test before building the real OpenBurnBar app", () => {
  assert.ok(rafStep && buildStep && realGateStep && evidenceStep, "missing P-PERF-3 workflow step");
  assert.ok(appBuildJob.indexOf("macOS rAF pause prerequisite (P-PERF-3)")
    < appBuildJob.indexOf("Build AgentLens app for real-process CPU gate"));
  assert.ok(appBuildJob.indexOf("Build AgentLens app for real-process CPU gate")
    < appBuildJob.indexOf("Enforce real macOS idle/occluded CPU budget (P-PERF-3)"));
  assert.equal(stepRun(rafStep).trim(), "node --test scripts/ci/macos-idle-occlusion-gate.test.mjs");
  const build = stepRun(buildStep);
  assert.match(build, /xcodebuild build \\\n/u);
  assert.match(build, /-project OpenBurnBar\.xcodeproj/u);
  assert.match(build, /-scheme OpenBurnBar/u);
  assert.match(build, /-derivedDataPath "\$PERF_DERIVED_DATA"/u);
});

check("P-PERF-3 invokes only the real-process gate output sink and cannot continue on error", () => {
  assert.equal(
    stepRun(realGateStep).trim().replace(/\s+/gu, " "),
    'node scripts/ci/macos-idle-occlusion-gate.mjs --output "$RUNNER_TEMP/macos-idle-occlusion-evidence/result.json"',
  );
  for (const step of [rafStep, buildStep, realGateStep]) {
    assert.equal(optionalStepField(step, "continue-on-error"), undefined);
  }
});

check("P-PERF-3 always uploads required evidence and fails when evidence is absent", () => {
  assert.equal(optionalStepField(evidenceStep, "if"), "always()");
  assert.match(optionalStepField(evidenceStep, "uses"), /^actions\/upload-artifact@/u);
  assert.match(evidenceStep, /^          path: \$\{\{ runner\.temp \}\}\/macos-idle-occlusion-evidence\/result\.json$/mu);
  assert.match(evidenceStep, /^          if-no-files-found: error$/mu);
  assert.equal(optionalStepField(evidenceStep, "continue-on-error"), undefined);
});

check("app tests reuse the real-process build instead of compiling the product twice", () => {
  assert.ok(buildStep && appTestStep, "missing real-process build or app test step");
  const build = stepRun(buildStep);
  const test = stepRun(appTestStep);
  assert.match(build, /PERF_DERIVED_DATA="\$GITHUB_WORKSPACE\/\.derived-data\/macos-idle-occlusion-gate"/u);
  assert.match(
    test,
    /OPENBURNBAR_APP_TEST_DERIVED_DATA_DIR="\$GITHUB_WORKSPACE\/\.derived-data\/macos-idle-occlusion-gate"/u,
  );
  const driver = readFileSync(
    join(REPO_ROOT, "scripts/test-openburnbar-app.sh"),
    "utf8",
  );
  assert.match(driver, /OPENBURNBAR_APP_TEST_DERIVED_DATA_DIR/u);
  assert.match(driver, /derived_data_dir="\$\(create_derived_data_dir\)"/u);
});

check("PR App Gate uses the bounded smoke catalog and leaves the full suite to harness", () => {
  assert.equal(jobField(appBuildJob, "timeout-minutes"), "90");
  const test = stepRun(appTestStep);
  assert.match(
    test,
    /source scripts\/lib\/openburnbar-release-app-test-filters\.sh/u,
  );
  assert.match(
    test,
    /OPENBURNBAR_APP_TEST_FILTERS="\$\(openburnbar_release_app_test_filters_env\)"/u,
  );
  assert.match(test, /OPENBURNBAR_APP_TEST_ATTEMPTS=2/u);
  assert.match(test, /OPENBURNBAR_APP_TEST_DEFAULT_ALLOWANCE=180/u);
  assert.match(test, /OPENBURNBAR_APP_TEST_MAX_ALLOWANCE=360/u);
  assert.doesNotMatch(
    appBuildJob,
    /name: Enforce app diff coverage/u,
    "bounded smoke coverage cannot enforce full-suite diff coverage",
  );
  const harness = readFileSync(join(REPO_ROOT, WORKFLOW), "utf8");
  const harnessAppJob = workflowJob(harness, "app-xctest");
  const harnessAppTestStep = workflowStep(harnessAppJob, "Run OpenBurnBar app tests");
  assert.match(
    stepRun(harnessAppTestStep),
    /OPENBURNBAR_ENABLE_COVERAGE=YES \.\/scripts\/test-openburnbar-app\.sh/u,
  );
});

const fastWorkflow = readFileSync(join(REPO_ROOT, FAST_WORKFLOW), "utf8");
const rustJob = workflowJob(fastWorkflow, "rust-deny-fast");
const fastGate = workflowJob(fastWorkflow, "fast-feedback-gate");
const fastStep = workflowStep(fastGate, "Check all fast jobs passed");
const fastScript = stepScript(fastStep);
const fastNeeds = jobNeeds(fastGate);

check("every checkout-bearing CI job tolerates a slow checkout", () => {
  // A job whose budget expires during actions/checkout is reported by GitHub as
  // CANCELLED, and the CI Gate aggregator fails closed on a cancelled component
  // -- so an ordinary slow checkout ejects the whole merge-queue candidate. The
  // pack is ~866MB. On 2026-08-10, required jobs were cancelled after spending
  // their entire 8- and 10-minute budgets inside checkout, while the Firestore
  // rules job took 10m27s and still passed under a larger cap. This originally
  // guarded one job (SQLCipher), was widened to fast-feedback.yml, and is now
  // repo-wide. Any job that runs actions/checkout must budget at least 15
  // minutes so checkout can finish and the actual check still gets time to run.
  const offenders = checkoutTimeoutOffenders(REPO_ROOT);
  assert.deepEqual(
    offenders,
    [],
    `checkout-bearing jobs must budget >=${CHECKOUT_TIMEOUT_FLOOR_MINUTES} min: ${JSON.stringify(offenders)}`,
  );
});

check("checkout timeout guard catches a ten-minute OSV budget", () => {
  const root = mkdtempSync(join(tmpdir(), "checkout-timeout-guard-"));
  roots.push(root);
  const workflows = join(root, ".github", "workflows");
  mkdirSync(workflows, { recursive: true });

  const source = readFileSync(join(REPO_ROOT, SECURITY_WORKFLOW), "utf8");
  const osvJob = workflowJob(source, "osv-scanner");
  const mutatedJob = osvJob.replace(
    /^    timeout-minutes:\s*\d+\s*$/mu,
    "    timeout-minutes: 10\n",
  );
  assert.notEqual(mutatedJob, osvJob, "OSV timeout mutation must change the job");
  writeFileSync(
    join(root, SECURITY_WORKFLOW),
    source.replace(osvJob, mutatedJob),
  );

  assert.deepEqual(checkoutTimeoutOffenders(root), ["security-pr.yml:osv-scanner=10"]);
});

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
    FUNCTIONS_REQUIRED: "${{ needs.classify.outputs.functions }}",
    MACOS_REQUIRED: "${{ needs.classify.outputs.macos }}",
    WEB_REQUIRED: "${{ needs.classify.outputs.web }}",
    CONSOLE_REQUIRED: "${{ needs.classify.outputs.console }}",
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
  return {
    NEEDS_JSON: JSON.stringify(needs),
    RUST_CHANGED: rustChanged,
    FUNCTIONS_REQUIRED: "true",
    WEB_REQUIRED: "true",
    CONSOLE_REQUIRED: "true",
  };
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

const packageLintJob = workflowJob(fastWorkflow, "typescript-surfaces-lint");
const packageLintSteps = workflowSteps(packageLintJob);

check("TypeScript package lint floors install, lint, and typecheck linux-desktop", () => {
  const fakeBin = mkdtempSync(join(tmpdir(), "typescript-lint-floor-npm-"));
  roots.push(fakeBin);
  const calls = join(fakeBin, "npm-calls.txt");
  const fakeNpm = join(fakeBin, "npm");
  writeFileSync(fakeNpm, '#!/usr/bin/env bash\nprintf \'%s\\n\' "$*" >> "$NPM_CALLS"\n');
  chmodSync(fakeNpm, 0o755);

  const install = packageLintSteps.get("Install TypeScript package dependencies");
  const lint = packageLintSteps.get("ESLint + typecheck package floors");
  const typecheck = packageLintSteps.get("Linux desktop TypeScript typecheck floor");
  assert.ok(install && lint && typecheck, "missing TypeScript package lint floor step");
  const status = runShell(
    `${stepRun(install)}\n${stepRun(lint)}\n${stepRun(typecheck)}`,
    { PATH: `${fakeBin}:${process.env.PATH}`, NPM_CALLS: calls },
  );
  assert.equal(status, 0);
  const invocations = readFileSync(calls, "utf8").trim().split("\n");
  assert.ok(invocations.includes("ci --prefix apps/linux-desktop"));
  assert.ok(invocations.includes("run lint --prefix apps/linux-desktop"));
  assert.ok(invocations.includes("run typecheck --prefix apps/linux-desktop"));
});

check("desired main branch protection keeps immutable security checks beside the umbrella gate", () => {
  const protection = JSON.parse(readFileSync(join(REPO_ROOT, BRANCH_PROTECTION), "utf8"));
  const gate = JSON.parse(
    readFileSync(join(REPO_ROOT, "governance/burnbar-ci-gate.json"), "utf8"),
  );
  for (const context of [
    "BurnBar CI Gate",
    "Dependency Review (CVE check)",
    "Firestore Security Rules Tests",
    "Functions (security vitest)",
    "OSV Scanner (open source vulnerabilities)",
    "Secret Detection (gitleaks)",
  ]) {
    assert.ok(protection.required_status_checks.contexts.includes(context), `${context} must remain required`);
  }
  assert.equal(protection.required_pull_request_reviews.required_approving_review_count, 1);
  assert.equal(protection.required_pull_request_reviews.require_code_owner_reviews, true);
  assert.equal(protection.required_pull_request_reviews.dismiss_stale_reviews, true);
  assert.equal(protection.required_pull_request_reviews.require_last_push_approval, true);
  assert.ok(
    !gate.required_contexts.includes("App build + test (AgentLens)"),
    "merge_group full set must not wait on post-merge AgentLens",
  );
  assert.ok(
    !gate.required_contexts.includes("Mobile build + unit test"),
    "merge_group full set must not wait on post-merge mobile",
  );
  assert.ok(
    gate.required_contexts.includes("Domain Core PR Gate"),
    "merge_group full set must keep Domain Core PR Gate",
  );

  const fastGate = JSON.parse(
    readFileSync(join(REPO_ROOT, "governance/burnbar-ci-gate.fast.json"), "utf8"),
  );
  // Fast PR eligibility (#2230) drops the slow walls. Domain Core PR Gate is a
  // wall when rust=true (~60m with Apple app spool); keep it on merge_group /
  // classic BP, not the 45m PR umbrella.
  for (const slowWall of [
    "App build + test (AgentLens)",
    "Mobile build + unit test",
    "Daemon PR Gate",
    "Android PR Gate",
    "PR Windows Full Gate",
    "Domain Core PR Gate",
  ]) {
    assert.ok(
      !fastGate.required_contexts.includes(slowWall),
      `fast gate must not require slow wall: ${slowWall}`,
    );
  }
  assert.ok(
    fastGate.required_contexts.includes("Domain Core Trusted Deletion Guard"),
    "fast gate must keep the always-on trusted deletion guard",
  );

  const umbrella = readFileSync(join(REPO_ROOT, ".github/workflows/burnbar-ci-gate.yml"), "utf8");
  assert.match(
    umbrella,
    /ref: \$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.event\.merge_group\.base_sha \|\| github\.sha \}\}/,
  );
  assert.match(umbrella, /persist-credentials: false/);
});

function workflowOn(source) {
  const match = /^on:\n([\s\S]*?)^(?:permissions|concurrency|jobs|env|defaults):/mu.exec(
    source,
  );
  assert.ok(match, "missing workflow on: block");
  return match[1];
}

check("App and Headless AgentLens builds are post-merge/nightly, not PR walls", () => {
  const appOn = workflowOn(appWorkflow);
  const headlessSource = readFileSync(join(REPO_ROOT, HEADLESS_WORKFLOW), "utf8");
  const headlessOn = workflowOn(headlessSource);

  assert.doesNotMatch(appOn, /^  pull_request:\s*$/mu);
  assert.doesNotMatch(headlessOn, /^  pull_request:\s*$/mu);
  assert.doesNotMatch(headlessOn, /^  merge_group:\s*$/mu);
  assert.match(appOn, /^  push:\s*$/mu);
  assert.match(appOn, /^  schedule:\s*$/mu);
  assert.match(appOn, /^  workflow_dispatch:\s*$/mu);
  assert.match(headlessOn, /^  push:\s*$/mu);
  assert.match(headlessOn, /^  schedule:\s*$/mu);
  assert.match(headlessOn, /^  workflow_dispatch:\s*$/mu);

  const classify = workflowJob(appWorkflow, "classify");
  const appBuild = workflowJob(appWorkflow, "app-build-test");
  const mobile = workflowJob(appWorkflow, "mobile-build-gate");
  assert.match(jobField(classify, "if"), /github\.event_name != 'merge_group'/u);
  assert.match(jobField(appBuild, "if"), /github\.event_name != 'merge_group'/u);
  assert.match(jobField(mobile, "if"), /github\.event_name != 'merge_group'/u);

  assert.match(
    appWorkflow,
    /group: app-pr-gate-\$\{\{ github\.event_name \}\}-\$\{\{ github\.event_name == 'push' && github\.sha \|\| github\.ref \}\}/u,
  );
  assert.match(
    appWorkflow,
    /cancel-in-progress: \$\{\{ github\.event_name != 'push' \}\}/u,
  );
  assert.match(
    headlessSource,
    /group: headless-app-build-\$\{\{ github\.event_name \}\}-\$\{\{ github\.event_name == 'push' && github\.sha \|\| github\.ref \}\}/u,
  );
  assert.match(
    headlessSource,
    /cancel-in-progress: \$\{\{ github\.event_name != 'push' \}\}/u,
  );
});

check("macOS gates never run pull-request or merge-group code on persistent self-hosted runners", () => {
  // A merge-group ref is still pre-merge candidate code. It receives the same
  // isolation boundary as pull_request: GitHub-hosted macos-26, or the
  // explicitly selected isolated paid runner group.
  for (const [workflow, expectedCount] of [
    [APP_WORKFLOW, 2],
    [DAEMON_WORKFLOW, 2],
    [DOMAIN_CORE_WORKFLOW, 2],
    [HEADLESS_WORKFLOW, 1],
    [NATIVE_WORKFLOW, 2],
  ]) {
    const source = readFileSync(join(REPO_ROOT, workflow), "utf8");
    // Paid opt-in arm present and still the isolated capped pool (never inline group:).
    assert.equal(source.split("vars.MACOS_GATE_POOL == 'paid'").length - 1, expectedCount);
    assert.equal(source.split('{"group":"burnbar-ci-paid"}').length - 1, expectedCount);
    assert.equal(source.split("group: burnbar-ci-paid").length - 1, 0);
    assert.doesNotMatch(source, /burnbar-turbo-ephemeral|BurnBar-macos-26-xlarge/);
    const selfHosted = source.split('"self-hosted","macOS","ARM64","burnbar-swift"').length - 1;
    assert.equal(selfHosted, 0, `${workflow}: candidate code must not reach persistent self-hosted runners`);
    assert.equal(source.split("|| 'macos-26'").length - 1, expectedCount);
  }
});

if (failed > 0) {
  console.error(`\nFAIL: ${failed} PR harness aggregate gate self-test case(s) failed.`);
  process.exit(1);
}

console.log(`\nPASS: ${passed} PR harness aggregate gate self-test case(s) passed.`);
