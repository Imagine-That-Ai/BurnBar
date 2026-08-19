#!/usr/bin/env node
/**
 * Static boundary gate for the production Firebase Hosting deploy workflow.
 *
 * The hosting deploy is intentionally split into an uncredentialed artifact
 * build job and a credentialed deploy job. Manual dispatch must be main-bound:
 * a user-selected branch must not be able to build arbitrary hosting artifacts
 * and then hand them to the production WIF/OIDC deploy job.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT =
  process.env.HOSTING_DEPLOY_BOUNDARY_ROOT ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WORKFLOW = join(ROOT, ".github", "workflows", "deploy-hosting.yml");

const failures = [];
const fail = (message) => failures.push(message);

function stripYamlLineComment(line) {
  let singleQuoted = false;
  let doubleQuoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    const previous = index > 0 ? line[index - 1] : "";
    if (char === "'" && !doubleQuoted) {
      singleQuoted = !singleQuoted;
      continue;
    }
    if (char === '"' && !singleQuoted && previous !== "\\") {
      doubleQuoted = !doubleQuoted;
      continue;
    }
    if (
      char === "#" &&
      !singleQuoted &&
      !doubleQuoted &&
      (index === 0 || /\s/u.test(previous))
    ) {
      return line.slice(0, index).trimEnd();
    }
  }
  return line;
}

function stripYamlComments(source) {
  return source
    .split("\n")
    .map((line) => stripYamlLineComment(line))
    .join("\n");
}

function indent(line) {
  return /^\s*/u.exec(line)?.[0].length ?? 0;
}

function blockStartingAt(lines, start, childIndent) {
  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (lines[index].trim() && indent(lines[index]) < childIndent) {
      end = index;
      break;
    }
  }
  return lines.slice(start, end).join("\n");
}

function jobBlock(source, jobName) {
  const lines = source.split("\n");
  const start = lines.findIndex((line) => line === `  ${jobName}:`);
  return start === -1 ? "" : blockStartingAt(lines, start, 4);
}

function jobLevelCondition(jobSource) {
  const lines = jobSource.split("\n");
  const start = lines.findIndex((line) => /^ {4}if:/u.test(line));
  return start === -1 ? "" : blockStartingAt(lines, start, 6);
}

function stepBlock(jobSource, stepName) {
  const lines = jobSource.split("\n");
  const start = lines.findIndex((line) => {
    const trimmed = line.trim();
    return (
      trimmed === `- name: ${stepName}` ||
      trimmed === `name: ${stepName}` ||
      trimmed === `- name: "${stepName}"` ||
      trimmed === `name: "${stepName}"`
    );
  });
  if (start === -1) return "";

  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (lines[index].trim() && indent(lines[index]) <= 6) {
      end = index;
      break;
    }
  }
  return lines.slice(start, end).join("\n");
}

function stepRunBlock(stepSource) {
  const lines = stepSource.split("\n");
  const runIndex = lines.findIndex((line) => /^\s{8}run:\s*\|/u.test(line));
  if (runIndex === -1) return "";

  const body = [];
  for (const line of lines.slice(runIndex + 1)) {
    if (/^\s{10}/u.test(line) || /^\s*$/u.test(line)) {
      body.push(line.replace(/^\s{10}/u, ""));
      continue;
    }
    break;
  }
  return body.join("\n");
}

function requireIncludes(source, needle, message) {
  if (!source.includes(needle)) fail(message);
}

function requireNoPattern(source, pattern, message) {
  if (pattern.test(source)) fail(message);
}

function requireOrder(source, before, after, message) {
  const beforeIndex = source.indexOf(before);
  const afterIndex = source.indexOf(after);
  if (beforeIndex === -1 || afterIndex === -1 || beforeIndex > afterIndex) {
    fail(message);
  }
}

function shellIfBlock(source, ifNeedle) {
  const start = source.indexOf(ifNeedle);
  if (start === -1) return null;
  const lines = source.slice(start).split("\n");
  const block = [];
  let depth = 0;
  for (const line of lines) {
    const trimmed = line.trim();
    block.push(line);
    if (/^if(?:\s|!|\[\[)/u.test(trimmed)) depth += 1;
    if (trimmed === "fi") {
      depth -= 1;
      if (depth === 0) break;
    }
  }
  if (depth !== 0 || !/^\s*fi\s*$/u.test(block.at(-1) ?? "")) return null;
  return block.join("\n");
}

function requireShellIfExits(source, ifNeedle, message) {
  const block = shellIfBlock(source, ifNeedle);
  if (!block) {
    fail(`${message}: missing guard block`);
    return;
  }
  const bodyLines = block
    .split("\n")
    .slice(1, -1)
    .map((line) => line.trim())
    .filter(Boolean);
  if (bodyLines.at(-1) !== "exit 1") {
    fail(`${message}: guard block must end its then-branch with exit 1`);
  }
  for (const line of bodyLines.slice(0, -1)) {
    if (/^(if|elif|else|fi|for|while|until|case|function)\b/u.test(line)) {
      fail(`${message}: guard block must stay flat before exit 1`);
    } else if (
      /\b(?:exit|return)\b/u.test(line) ||
      /(?:&&|\|\||;\s*true\b)/u.test(line)
    ) {
      fail(`${message}: guard block must not contain alternate exits`);
    } else if (!/^echo\s+/u.test(line)) {
      fail(`${message}: guard block may only echo before exit 1`);
    }
  }
}

if (!existsSync(WORKFLOW)) {
  console.error(`MISCONFIGURED: workflow not found: ${WORKFLOW}`);
  process.exit(2);
}

const source = stripYamlComments(readFileSync(WORKFLOW, "utf8"));
const buildJob = jobBlock(source, "build-hosting-artifacts");
const deployJob = jobBlock(source, "deploy-hosting");
const deployJobCondition = jobLevelCondition(deployJob);
const verifyStep = stepBlock(buildJob, "Verify hosting deploy ref");
const verifyRun = stepRunBlock(verifyStep);

if (!buildJob) fail("missing build-hosting-artifacts job");
if (!deployJob) fail("missing deploy-hosting job");
if (!deployJobCondition)
  fail("deploy-hosting must declare a job-level if: condition");
if (!verifyStep) fail("missing Verify hosting deploy ref step");
if (/^\s{8}if\s*:/mu.test(verifyStep)) {
  fail("Verify hosting deploy ref step must not be conditional");
}

requireIncludes(
  source,
  "workflow_dispatch:",
  "hosting deploy must support manual dispatch",
);
requireIncludes(
  source,
  'tags: ["v*"]',
  "hosting deploy must support stable release tags",
);
requireIncludes(
  deployJobCondition,
  "!cancelled()",
  "hosting deploy must carry a status-check function so an upstream skipped gate job cannot propagate a skip onto the credentialed deploy",
);
requireIncludes(
  deployJobCondition,
  "needs.build-hosting-artifacts.result == 'success'",
  "hosting deploy must require a successful immutable-artifact build",
);
requireIncludes(
  deployJobCondition,
  "(github.event_name != 'workflow_dispatch' || inputs.dry_run != true)",
  "hosting deploy must run on push/tag events and skip only manual dry-runs",
);
requireNoPattern(
  deployJob,
  /github\.event\.inputs\.dry_run/u,
  "hosting deploy must not depend on workflow_dispatch-only event input paths",
);
requireIncludes(
  verifyStep,
  "EVENT_NAME: ${{ github.event_name }}",
  "verify step must read event name through env",
);
requireIncludes(
  verifyStep,
  "REQUESTED_PROFILE: ${{ inputs.domain_core_profile || 'public-production' }}",
  "verify step must read the requested profile through env",
);
requireIncludes(
  verifyRun,
  "set -euo pipefail",
  "verify step must run fail-closed shell mode",
);
requireIncludes(
  verifyRun,
  'if [[ "$GITHUB_REF" == "refs/heads/main" ]]; then',
  "hosting deploy must resolve main explicitly",
);
requireIncludes(
  verifyRun,
  'elif [[ "$GITHUB_REF" =~ ^refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+(\\+[0-9A-Za-z.-]+)?$ ]]; then',
  "hosting deploy must accept only stable semantic release tags",
);
requireIncludes(
  verifyRun,
  'commit="$(git rev-parse "$GITHUB_REF^{commit}")"',
  "hosting deploy must resolve the exact tag commit",
);
requireIncludes(
  verifyRun,
  '[[ "$GITHUB_SHA" == "$commit" ]] || { echo "::error::Release tag moved away from workflow commit."; exit 1; }',
  "hosting deploy must reject a moved release tag",
);
requireIncludes(
  verifyRun,
  'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"',
  "hosting deploy must fetch origin/main before reachability check",
);
requireIncludes(
  verifyRun,
  'if ! git merge-base --is-ancestor "$commit" origin/main; then',
  "hosting deploy commit must be reachable from origin/main",
);
requireShellIfExits(
  verifyRun,
  'if ! git merge-base --is-ancestor "$commit" origin/main; then',
  "hosting deploy origin/main reachability guard",
);
requireIncludes(
  verifyRun,
  'if [[ "$profile" == "public-production-rollback" ]]; then',
  "hosting rollback must have an explicit policy branch",
);
requireIncludes(
  verifyRun,
  'if [[ "$EVENT_NAME" != "workflow_dispatch" || -z "$release_tag" ]]; then',
  "hosting rollback must be manual and stable-tag-only",
);

requireOrder(
  buildJob,
  "Verify hosting deploy ref",
  "Build immutable hosting outputs",
  "hosting ref guard must run before artifact build",
);
requireOrder(
  buildJob,
  "Verify hosting deploy ref",
  "Upload immutable hosting artifact",
  "hosting ref guard must run before artifact upload",
);
requireOrder(
  deployJob,
  "Verify hosting artifact and CI config",
  "Authenticate to Google Cloud (hosting-only WIF/OIDC)",
  "credentialed hosting deploy must verify immutable artifact before auth",
);
requireOrder(
  deployJob,
  "node-version: 22",
  "Authenticate to Google Cloud (hosting-only WIF/OIDC)",
  "Node 22 setup must happen before GCP auth",
);
requireOrder(
  deployJob,
  "Authenticate to Google Cloud (hosting-only WIF/OIDC)",
  "Deploy Hosting (marketing + console)",
  "hosting deploy must authenticate before the REST deployer runs",
);

requireNoPattern(
  deployJob,
  /actions\/checkout@/u,
  "credentialed deploy-hosting job must not checkout repository source",
);
requireNoPattern(
  deployJob,
  /\bnpm\s+(?:ci|install|run)\b/u,
  "credentialed deploy-hosting job must not run npm after auth path begins",
);
requireNoPattern(
  deployJob,
  /--token(?:\s|$)/u,
  "credentialed deploy-hosting job must not use Firebase CLI legacy token auth",
);
requireNoPattern(
  deployJob,
  /\bfirebase\s+deploy\b/u,
  "credentialed deploy-hosting job must not use Firebase CLI deploy auth",
);
requireNoPattern(
  deployJob,
  /-x\s+"\$ARTIFACT_ROOT\/scripts\/ci\/deploy-firebase-hosting-rest\.mjs"/u,
  "credentialed deploy-hosting job must not require executable mode on artifact-downloaded deployer scripts",
);
requireNoPattern(
  source,
  /\brelease_hold_bypass_reason\b/u,
  "hosting deploy must not add self-authorized release hold bypass input",
);

requireIncludes(
  deployJob,
  "node-version: 22",
  "credentialed deploy-hosting job must run the REST deployer under Node 22",
);
requireIncludes(
  deployJob,
  "          token_format: access_token",
  "credentialed deploy-hosting job must request a WIF access token for the Hosting REST API",
);
requireIncludes(
  deployJob,
  "FIREBASE_HOSTING_REST_ACCESS_TOKEN: ${{ steps.hosting_auth.outputs.access_token }}",
  "credentialed deploy-hosting job must pass the WIF access token only to the REST deployer",
);
requireIncludes(
  deployJob,
  "deploy-firebase-hosting-rest.mjs",
  "credentialed deploy-hosting job must use the artifact-bundled Hosting REST deployer",
);
requireIncludes(
  deployJob,
  '--config "$FIREBASE_HOSTING_CI_CONFIG"',
  "credentialed deploy-hosting job must deploy with the generated artifact-root CI config",
);
requireIncludes(
  deployJob,
  '--firebaserc "$ARTIFACT_ROOT/.firebaserc"',
  "credentialed deploy-hosting job must deploy with the artifact-root .firebaserc",
);
requireIncludes(
  deployJob,
  "FIREBASE_HOSTING_CI_CONFIG: ${{ runner.temp }}/hosting-artifact/firebase-hosting.ci.json",
  "credentialed deploy-hosting job must keep firebase-hosting.ci.json under the artifact root",
);

// ── Release-coordinate and candidate-identity contract ───────────────────
// Main deploys are non-release builds: --expected-release-* flags must be
// omitted (not passed as empty values). Stable tag/rollback builds include
// complete non-empty release coordinates. The staged Console profile verifies
// against CANDIDATE_COMMIT (C), not RELEASE_COMMIT (R/P).
const stagingStep = stepBlock(buildJob, "Stage hosting deploy artifact");
const resolveStep = stepBlock(
  buildJob,
  "Resolve signed public domain-core profile",
);

if (!stagingStep) fail("missing Stage hosting deploy artifact step");
if (!resolveStep)
  fail("missing Resolve signed public domain-core profile step");

if (stagingStep) {
  requireIncludes(
    stagingStep,
    "CANDIDATE_COMMIT: ${{ steps.activation.outputs.candidate_commit || steps.ref.outputs.commit }}",
    "staging step must expose CANDIDATE_COMMIT from activation (with fallback to ref commit)",
  );
  requireIncludes(
    stagingStep,
    '--expected-candidate-commit "$CANDIDATE_COMMIT"',
    "staging step must verify the staged Console profile against CANDIDATE_COMMIT, not RELEASE_COMMIT",
  );
  requireNoPattern(
    stagingStep,
    /--expected-candidate-commit "\$RELEASE_COMMIT"/u,
    "staging step must not verify the staged Console profile against RELEASE_COMMIT",
  );
  requireIncludes(
    stagingStep,
    'if [[ -n "$RELEASE_TAG" ]]; then',
    "staging step must conditionally include release flags only on stable tag/rollback",
  );
}

if (resolveStep) {
  requireIncludes(
    resolveStep,
    "CANDIDATE_COMMIT: ${{ steps.activation.outputs.candidate_commit || steps.ref.outputs.commit }}",
    "resolve profile step must expose CANDIDATE_COMMIT from activation (with fallback to ref commit)",
  );
  requireIncludes(
    resolveStep,
    'if [[ -n "$RELEASE_TAG" ]]; then',
    "resolve profile step must conditionally include release flags only on stable tag/rollback",
  );
  requireNoPattern(
    resolveStep,
    /--expected-release-commit "\$RELEASE_COMMIT" --expected-release-version/u,
    "resolve profile step must not unconditionally pass release coordinates (main path omits them)",
  );
}

if (failures.length > 0) {
  console.error("Hosting deploy boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log(
  "PASS: hosting deploy manual dispatch is main-bound and artifact-bound.",
);
