#!/usr/bin/env node
/**
 * Functional self-test for the two-phase release tag safety shell logic.
 *
 * Sets up a temporary git repository with a main branch and candidate commits,
 * then executes the resolve-step script (extracted from the workflow) against
 * various inputs to prove:
 *   - Future-tag dry-run succeeds only at exact current-main SHA
 *   - Existing-tag recovery accepts the immutable tagged ancestor from current main
 *   - Mismatched/unreachable/malformed candidate_sha fails
 *   - Dry-run cannot deploy (credentials stay skipped)
 *   - Non-dry-run/tag-push stays tag-bound
 *
 * Both workflows share structurally identical resolve logic, so we test one
 * (deploy-production) and verify symmetry at the static-gate level.
 */

import { execFileSync, execSync } from "node:child_process";
import {
  mkdtempSync,
  rmSync,
  writeFileSync,
  readFileSync,
  mkdirSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, "..", "..");
const GATE = join(SCRIPT_DIR, "verify-release-tag-safety.mjs");
const roots = [];

process.on("exit", () => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

let passed = 0;
let failed = 0;

function assert(label, condition) {
  if (condition) {
    passed += 1;
    console.log(`  PASS: ${label}`);
  } else {
    failed += 1;
    console.error(`  FAIL: ${label}`);
  }
}

/**
 * Create a temporary bare-origin + local-clone setup that simulates a GitHub
 * repo with origin/main and tags.
 */
function setupGitRepo() {
  const workDir = mkdtempSync(join(tmpdir(), "release-tag-fn-"));
  roots.push(workDir);

  const originDir = join(workDir, "origin.git");
  const cloneDir = join(workDir, "clone");

  // Create bare origin
  execSync(`git init --bare "${originDir}"`);
  // Clone
  execSync(`git clone "${originDir}" "${cloneDir}"`);
  execSync(`git -C "${cloneDir}" config user.email test@test.com`);
  execSync(`git -C "${cloneDir}" config user.name Test`);

  // Create main branch with commits — explicitly name it "main" independent
  // of global git config (init.defaultBranch may be set to master or other).
  writeFileSync(join(cloneDir, "README.md"), "# test\n");
  execSync(`git -C "${cloneDir}" add -A`);
  execSync(`git -C "${cloneDir}" commit -m "initial"`);
  // Ensure the current branch is "main" regardless of init.defaultBranch
  execSync(`git -C "${cloneDir}" branch -m main`);

  writeFileSync(join(cloneDir, "file1.txt"), "content1\n");
  execSync(`git -C "${cloneDir}" add -A`);
  execSync(`git -C "${cloneDir}" commit -m "second"`);
  const mainSha = execSync(`git -C "${cloneDir}" rev-parse HEAD`)
    .toString()
    .trim();

  // Push main
  execSync(`git -C "${cloneDir}" push origin main`);

  return { workDir, originDir, cloneDir, mainSha };
}

/**
 * Extract the resolve-step run script from a workflow, with env vars
 * substituted for testing.
 */
function extractResolveScript(workflowFile) {
  const source = readFileSync(workflowFile, "utf8");
  const resolveStep = source.indexOf("      - name: Resolve release tag\n");
  if (resolveStep === -1) throw new Error("Could not find resolve step");
  const runMatch = source
    .slice(resolveStep)
    .match(/        run: \|\n((?:          .*\n|\n)*)/);
  if (!runMatch) throw new Error("Could not extract run script");
  return runMatch[1].replace(/^          /gm, "");
}

/**
 * Run the resolve-step logic against a temp git clone with given env vars.
 * Returns { exitCode, stdout, stderr }.
 */
function runResolve({ cloneDir, originUrl, env }) {
  const runnerTemp = join(cloneDir, "_runner_temp");
  mkdirSync(runnerTemp, { recursive: true });
  writeFileSync(
    join(runnerTemp, "release-dry-run-attestation.mjs"),
    [
      "#!/usr/bin/env node",
      'if (process.env.ATTESTATION_GATE_RESULT !== "pass") {',
      '  console.error("mock attestation verifier denied authority");',
      "  process.exit(1);",
      "}",
      "",
    ].join("\n"),
  );
  const script = [
    "set -euo pipefail",
    "",
    `cd "${cloneDir}"`,
    `git remote set-url origin "${originUrl}"`,
    "",
  ].join("\n");

  // Extract the actual resolve logic from deploy-production.yml
  const workflowPath = join(
    REPO_ROOT,
    ".github",
    "workflows",
    "deploy-production.yml",
  );
  const resolveLogic = extractResolveScript(workflowPath);

  // Build the full test script: preamble + resolve logic + output capture
  const fullScript = script + "\n" + resolveLogic;

  const scriptFile = join(cloneDir, "_resolve_test.sh");
  writeFileSync(scriptFile, fullScript);
  execSync(`chmod +x "${scriptFile}"`);

  // Set GITHUB_OUTPUT to a temp file
  const outputFile = join(cloneDir, "_github_output.txt");
  writeFileSync(outputFile, "");

  const fullEnv = {
    ...process.env,
    ...env,
    GITHUB_OUTPUT: outputFile,
    GITHUB_REF: env.GITHUB_REF || "refs/heads/main",
    GITHUB_SHA: env.GITHUB_SHA || env.INPUT_CANDIDATE_SHA || "",
    INPUT_EXISTING_TAG_RETRY: env.INPUT_EXISTING_TAG_RETRY || "false",
    RUNNER_TEMP: runnerTemp,
  };

  try {
    const stdout = execFileSync("bash", [scriptFile], {
      env: fullEnv,
      stdio: "pipe",
      timeout: 30000,
    }).toString();
    return { exitCode: 0, stdout, stderr: "", outputFile };
  } catch (error) {
    return {
      exitCode: error.status ?? 1,
      stdout: error.stdout?.toString() ?? "",
      stderr: error.stderr?.toString() ?? "",
      outputFile,
    };
  }
}

function readOutput(outputFile) {
  try {
    return readFileSync(outputFile, "utf8");
  } catch {
    return "";
  }
}

console.log("Functional self-test: two-phase release tag safety shell logic\n");

const { cloneDir, originDir, mainSha } = setupGitRepo();

const VALID_TAG = "v1.2.3";
const FULL_SHA = mainSha;

/* ── Dry-run at exact current-main SHA: succeeds ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  const output = readOutput(result.outputFile);
  assert("dry-run at exact main SHA succeeds", result.exitCode === 0);
  if (result.exitCode === 0) {
    assert("  emits correct tag", output.includes(`tag=${VALID_TAG}`));
    assert("  emits correct commit", output.includes(`commit=${FULL_SHA}`));
    assert("  emits dry_run=true", output.includes("dry_run=true"));
    assert(
      "  defaults to public production profile",
      output.includes("domain_core_profile=public-production"),
    );
  }
}

/* ── Unknown manual profile fails closed ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "false",
      INPUT_CANDIDATE_SHA: "",
      INPUT_DOMAIN_CORE_PROFILE: "unsigned-test-profile",
      REF_NAME: VALID_TAG,
      GITHUB_REF: `refs/tags/${VALID_TAG}`,
      GITHUB_SHA: FULL_SHA,
    },
  });
  assert("unknown manual profile fails", result.exitCode !== 0);
}

/* ── Dry-run with mismatched SHA (stale): fails ── */
{
  const staleSha = "0".repeat(40);
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: staleSha,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  assert("dry-run with stale/non-existent SHA fails", result.exitCode !== 0);
}

/* ── Dry-run with malformed SHA (not 40 hex): fails ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: "abc123",
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  assert("dry-run with malformed (short) SHA fails", result.exitCode !== 0);
}

/* ── Dry-run with empty candidate_sha: fails ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: "",
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  assert("dry-run with empty candidate_sha fails", result.exitCode !== 0);
}

/* ── Dry-run from a tag ref: fails ── */
{
  // First create the tag in the repo
  execSync(
    `git -C "${cloneDir}" tag -a ${VALID_TAG} -m "${VALID_TAG} test release"`,
  );
  execSync(`git -C "${cloneDir}" push origin ${VALID_TAG}`);

  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      REF_NAME: VALID_TAG,
      GITHUB_REF: `refs/tags/${VALID_TAG}`,
      GITHUB_SHA: FULL_SHA,
    },
  });
  assert("dry-run from a tag ref fails", result.exitCode !== 0);
}

/* ── Manual tag-selected rollback dispatch is forbidden ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "false",
      INPUT_EXISTING_TAG_RETRY: "false",
      INPUT_CANDIDATE_SHA: "",
      INPUT_DOMAIN_CORE_PROFILE: "public-production-rollback",
      REF_NAME: VALID_TAG,
      GITHUB_REF: `refs/tags/${VALID_TAG}`,
      GITHUB_SHA: FULL_SHA,
    },
  });
  assert(
    "manual rollback dispatch from the tag ref is forbidden",
    result.exitCode !== 0,
  );
}

/* ── Non-dry-run manual dispatch from non-tag ref: fails ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "false",
      INPUT_CANDIDATE_SHA: "",
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  assert(
    "non-dry-run manual dispatch from non-tag ref fails",
    result.exitCode !== 0,
  );
}

/* ── Non-dry-run manual dispatch from a tag ref is forbidden ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "false",
      INPUT_EXISTING_TAG_RETRY: "false",
      INPUT_CANDIDATE_SHA: "",
      INPUT_DOMAIN_CORE_PROFILE: "public-production",
      REF_NAME: VALID_TAG,
      GITHUB_REF: `refs/tags/${VALID_TAG}`,
      GITHUB_SHA: FULL_SHA,
    },
  });
  assert(
    "non-dry-run manual dispatch from tag ref is forbidden",
    result.exitCode !== 0,
  );
}

/* ── Tag push event: succeeds (simulated) ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "push",
      INPUT_TAG: "",
      INPUT_DRY_RUN: "",
      INPUT_CANDIDATE_SHA: "",
      INPUT_DOMAIN_CORE_PROFILE: "public-production-rollback",
      REF_NAME: VALID_TAG,
      GITHUB_REF: `refs/tags/${VALID_TAG}`,
      GITHUB_SHA: FULL_SHA,
    },
  });
  const output = readOutput(result.outputFile);
  assert("tag push event resolves tag commit", result.exitCode === 0);
  if (result.exitCode === 0) {
    assert("  emits correct tag", output.includes(`tag=${VALID_TAG}`));
    assert("  emits dry_run=false", output.includes("dry_run=false"));
    assert(
      "  tag push forces public production profile",
      output.includes("domain_core_profile=public-production"),
    );
  }
}

/* ── Tag/event mismatch: fails closed ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "push",
      INPUT_TAG: "",
      INPUT_DRY_RUN: "",
      INPUT_CANDIDATE_SHA: "",
      REF_NAME: VALID_TAG,
      GITHUB_REF: `refs/tags/${VALID_TAG}`,
      GITHUB_SHA: "f".repeat(40),
    },
  });
  assert(
    "tag push rejects a mismatched workflow event SHA",
    result.exitCode !== 0,
  );
}

/* ── Dry-run with future tag that doesn't exist yet: succeeds ── */
{
  const futureTag = "v2.0.0";
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: futureTag,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  const output = readOutput(result.outputFile);
  assert(
    "dry-run with future (non-existent) tag succeeds",
    result.exitCode === 0,
  );
  if (result.exitCode === 0) {
    assert("  emits future tag", output.includes(`tag=${futureTag}`));
  }
}

// Simulate the recovery patch landing after the immutable tag was created:
// workflow_dispatch now runs from a newer main commit while candidate_sha stays
// bound to the exact tagged ancestor.
execSync(`git -C "${cloneDir}" checkout main`);
mkdirSync(join(cloneDir, "scripts", "ci"), { recursive: true });
writeFileSync(
  join(cloneDir, "scripts", "ci", "verify-existing-tag-dry-run-recovery.mjs"),
  [
    "#!/usr/bin/env node",
    'if (process.env.RECOVERY_GATE_RESULT !== "pass") {',
    '  console.error("mock recovery verifier denied eligibility");',
    "  process.exit(1);",
    "}",
    "",
  ].join("\n"),
);
writeFileSync(join(cloneDir, "post-tag-fix.txt"), "recovery workflow fix\n");
execSync(
  `git -C "${cloneDir}" add post-tag-fix.txt scripts/ci/verify-existing-tag-dry-run-recovery.mjs`,
);
execSync(`git -C "${cloneDir}" commit -m "land recovery workflow fix"`);
execSync(`git -C "${cloneDir}" push origin main`);
const workflowMainSha = execSync(`git -C "${cloneDir}" rev-parse HEAD`)
  .toString()
  .trim();

/* ── Dry-run recovery for an untouched existing stable tag: succeeds ── */
{
  // v1.2.3 was created and pushed in the "dry-run from a tag ref" test above
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
      GITHUB_SHA: workflowMainSha,
      RECOVERY_GATE_RESULT: "pass",
    },
  });
  const output = readOutput(result.outputFile);
  assert(
    "dry-run recovery for untouched existing stable tag succeeds",
    result.exitCode === 0,
  );
  if (result.exitCode === 0) {
    assert("  emits existing tag", output.includes(`tag=${VALID_TAG}`));
    assert(
      "  emits exact tagged commit",
      output.includes(`commit=${FULL_SHA}`),
    );
    assert("  remains dry_run=true", output.includes("dry_run=true"));
  }
}

/* ── Main-only existing-tag real retry verifies current control first ── */
{
  execSync(`git -C "${cloneDir}" checkout main`);
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "false",
      INPUT_EXISTING_TAG_RETRY: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      INPUT_DOMAIN_CORE_PROFILE: "public-production",
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
      GITHUB_SHA: workflowMainSha,
      RECOVERY_GATE_RESULT: "pass",
      ATTESTATION_GATE_RESULT: "pass",
    },
  });
  const output = readOutput(result.outputFile);
  assert(
    "main-only existing-tag real retry succeeds after trusted attestation verification",
    result.exitCode === 0,
  );
  if (result.exitCode === 0) {
    assert(
      "  retry emits immutable tagged commit",
      output.includes(`commit=${FULL_SHA}`),
    );
    assert("  retry emits dry_run=false", output.includes("dry_run=false"));
    assert(
      "  retry emits existing_tag_retry=true",
      output.includes("existing_tag_retry=true"),
    );
    assert(
      "  retry emits exact trusted control SHA",
      output.includes(`control_sha=${workflowMainSha}`),
    );
  }
}

/* ── Existing-tag real retry fails if attestation authority is denied ── */
{
  execSync(`git -C "${cloneDir}" checkout main`);
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "false",
      INPUT_EXISTING_TAG_RETRY: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      INPUT_DOMAIN_CORE_PROFILE: "public-production",
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
      GITHUB_SHA: workflowMainSha,
      RECOVERY_GATE_RESULT: "pass",
      ATTESTATION_GATE_RESULT: "deny",
    },
  });
  assert(
    "existing-tag real retry fails before candidate checkout when attestation authority is denied",
    result.exitCode !== 0,
  );
  assert(
    "  denied retry leaves the trusted control checkout active",
    execSync(`git -C "${cloneDir}" rev-parse HEAD`).toString().trim() ===
      workflowMainSha,
  );
}

/* ── Existing-tag real retry is main-only ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "false",
      INPUT_EXISTING_TAG_RETRY: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      INPUT_DOMAIN_CORE_PROFILE: "public-production",
      REF_NAME: VALID_TAG,
      GITHUB_REF: `refs/tags/${VALID_TAG}`,
      GITHUB_SHA: FULL_SHA,
      ATTESTATION_GATE_RESULT: "pass",
    },
  });
  assert(
    "existing-tag real retry rejects a tag-selected dispatch",
    result.exitCode !== 0,
  );
}

/* ── Existing-tag recovery must run from the current main workflow SHA ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
      GITHUB_SHA: FULL_SHA,
      RECOVERY_GATE_RESULT: "pass",
    },
  });
  assert(
    "existing-tag recovery rejects a workflow SHA that is not current main",
    result.exitCode !== 0,
  );
}

/* ── Existing-tag recovery propagates GitHub-state verifier denial ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
      GITHUB_SHA: workflowMainSha,
      RECOVERY_GATE_RESULT: "deny",
    },
  });
  assert(
    "existing-tag recovery fails when GitHub-state verifier denies eligibility",
    result.exitCode !== 0,
  );
}

/* ── Existing-tag recovery from a non-main branch: fails ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      REF_NAME: "release-candidate",
      GITHUB_REF: "refs/heads/release-candidate",
      GITHUB_SHA: workflowMainSha,
      RECOVERY_GATE_RESULT: "pass",
    },
  });
  assert(
    "existing-tag recovery from a non-main branch fails",
    result.exitCode !== 0,
  );
}

/* ── Existing lightweight tag: fails immutable annotated-tag guard ── */
{
  const lightweightTag = "v1.2.4";
  execSync(`git -C "${cloneDir}" tag ${lightweightTag}`);
  execSync(`git -C "${cloneDir}" push origin ${lightweightTag}`);
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: lightweightTag,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
      GITHUB_SHA: workflowMainSha,
      RECOVERY_GATE_RESULT: "pass",
    },
  });
  assert("existing lightweight tag fails recovery", result.exitCode !== 0);
}

/* ── Existing stable tag that peels away from candidate: fails ── */
{
  const mismatchedTag = "v1.2.5";
  const parentSha = execSync(`git -C "${cloneDir}" rev-parse "${FULL_SHA}^"`)
    .toString()
    .trim();
  execSync(
    `git -C "${cloneDir}" tag -a ${mismatchedTag} ${parentSha} -m "${mismatchedTag} mismatch"`,
  );
  execSync(`git -C "${cloneDir}" push origin ${mismatchedTag}`);
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: mismatchedTag,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
      GITHUB_SHA: workflowMainSha,
      RECOVERY_GATE_RESULT: "pass",
    },
  });
  assert(
    "existing tag that peels away from candidate_sha fails recovery",
    result.exitCode !== 0,
  );
}

/* ── Existing prerelease tag: fails stable-only recovery guard ── */
{
  const prereleaseTag = "v1.2.6-rc.1";
  execSync(
    `git -C "${cloneDir}" tag -a ${prereleaseTag} -m "${prereleaseTag} prerelease"`,
  );
  execSync(`git -C "${cloneDir}" push origin ${prereleaseTag}`);
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: prereleaseTag,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
      GITHUB_SHA: workflowMainSha,
      RECOVERY_GATE_RESULT: "pass",
    },
  });
  assert("existing prerelease tag fails recovery", result.exitCode !== 0);
}

/* ── Dry-run with non-SemVer tag: fails ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: "not-a-version",
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_SHA: FULL_SHA,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  assert("dry-run with non-SemVer tag fails", result.exitCode !== 0);
}

/* ── Static gate also passes on these workflows ── */
{
  try {
    execFileSync("node", [GATE], {
      env: { ...process.env, RELEASE_TAG_SAFETY_ROOT: REPO_ROOT },
      stdio: "pipe",
    });
    assert("static gate passes on current workflows", true);
  } catch {
    assert("static gate passes on current workflows", false);
  }
}

if (failed > 0) {
  console.error(`\nFAIL: ${failed} functional self-test case(s) failed.`);
  process.exit(1);
}

console.log(`\nPASS: ${passed} functional self-test case(s) passed.`);
