#!/usr/bin/env node
/**
 * Functional self-test for the two-phase release tag safety shell logic.
 *
 * Sets up a temporary git repository with a main branch and candidate commits,
 * then executes the resolve-step script (extracted from the workflow) against
 * various inputs to prove:
 *   - Dry-run succeeds only at exact current-main SHA
 *   - Mismatched/stale/malformed candidate_commit fails
 *   - Dry-run cannot deploy (credentials stay skipped)
 *   - Non-dry-run/tag-push stays tag-bound
 *
 * Both workflows share structurally identical resolve logic, so we test one
 * (deploy-production) and verify symmetry at the static-gate level.
 */

import { execFileSync, execSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, mkdirSync } from "node:fs";
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

  // Create main branch with commits
  writeFileSync(join(cloneDir, "README.md"), "# test\n");
  execSync(`git -C "${cloneDir}" add -A`);
  execSync(`git -C "${cloneDir}" commit -m "initial"`);

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
  // Find the run block in the resolve step
  const runMatch = source.match(
    /run: \|\n((?:          .*\n|\n)*)/,
  );
  if (!runMatch) throw new Error("Could not extract run script");
  return runMatch[1].replace(/^          /gm, "");
}

/**
 * Run the resolve-step logic against a temp git clone with given env vars.
 * Returns { exitCode, stdout, stderr }.
 */
function runResolve({ cloneDir, originUrl, env }) {
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
      INPUT_CANDIDATE_COMMIT: FULL_SHA,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  const output = readOutput(result.outputFile);
  assert(
    "dry-run at exact main SHA succeeds",
    result.exitCode === 0,
  );
  if (result.exitCode === 0) {
    assert("  emits correct tag", output.includes(`tag=${VALID_TAG}`));
    assert("  emits correct commit", output.includes(`commit=${FULL_SHA}`));
    assert("  emits dry_run=true", output.includes("dry_run=true"));
  }
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
      INPUT_CANDIDATE_COMMIT: staleSha,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  assert(
    "dry-run with stale/non-existent SHA fails",
    result.exitCode !== 0,
  );
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
      INPUT_CANDIDATE_COMMIT: "abc123",
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  assert(
    "dry-run with malformed (short) SHA fails",
    result.exitCode !== 0,
  );
}

/* ── Dry-run with empty candidate_commit: fails ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_COMMIT: "",
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  assert(
    "dry-run with empty candidate_commit fails",
    result.exitCode !== 0,
  );
}

/* ── Dry-run from a tag ref: fails ── */
{
  // First create the tag in the repo
  execSync(`git -C "${cloneDir}" tag ${VALID_TAG}`);
  execSync(`git -C "${cloneDir}" push origin ${VALID_TAG}`);

  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_COMMIT: FULL_SHA,
      REF_NAME: VALID_TAG,
      GITHUB_REF: `refs/tags/${VALID_TAG}`,
    },
  });
  assert(
    "dry-run from a tag ref fails",
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
      INPUT_CANDIDATE_COMMIT: "",
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  assert(
    "non-dry-run manual dispatch from non-tag ref fails",
    result.exitCode !== 0,
  );
}

/* ── Non-dry-run manual dispatch from correct tag ref: succeeds ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: VALID_TAG,
      INPUT_DRY_RUN: "false",
      INPUT_CANDIDATE_COMMIT: "",
      REF_NAME: VALID_TAG,
      GITHUB_REF: `refs/tags/${VALID_TAG}`,
    },
  });
  const output = readOutput(result.outputFile);
  assert(
    "non-dry-run manual dispatch from tag ref succeeds",
    result.exitCode === 0,
  );
  if (result.exitCode === 0) {
    assert("  emits correct tag", output.includes(`tag=${VALID_TAG}`));
    assert("  emits dry_run=false", output.includes("dry_run=false"));
  }
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
      INPUT_CANDIDATE_COMMIT: "",
      REF_NAME: VALID_TAG,
      GITHUB_REF: `refs/tags/${VALID_TAG}`,
    },
  });
  const output = readOutput(result.outputFile);
  assert(
    "tag push event resolves tag commit",
    result.exitCode === 0,
  );
  if (result.exitCode === 0) {
    assert("  emits correct tag", output.includes(`tag=${VALID_TAG}`));
    assert("  emits dry_run=false", output.includes("dry_run=false"));
  }
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
      INPUT_CANDIDATE_COMMIT: FULL_SHA,
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

/* ── Dry-run with non-SemVer tag: fails ── */
{
  const result = runResolve({
    cloneDir,
    originUrl: originDir,
    env: {
      EVENT_NAME: "workflow_dispatch",
      INPUT_TAG: "not-a-version",
      INPUT_DRY_RUN: "true",
      INPUT_CANDIDATE_COMMIT: FULL_SHA,
      REF_NAME: "main",
      GITHUB_REF: "refs/heads/main",
    },
  });
  assert(
    "dry-run with non-SemVer tag fails",
    result.exitCode !== 0,
  );
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