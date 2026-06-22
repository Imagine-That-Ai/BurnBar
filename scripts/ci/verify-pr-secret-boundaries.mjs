#!/usr/bin/env node
/**
 * Static boundary gate for PR-adjacent workflow secrets.
 *
 * Pull-request workflows may run untrusted repository code. Any lane that
 * exposes real runtime secrets to that code must first prove the PR is a
 * same-repository branch from a trusted actor, and must provide a non-secret
 * fallback for untrusted PRs. This verifier covers the current QA and Android
 * dependency-health secret surfaces and is wired through workflow-lint.
 *
 * Usage: node scripts/ci/verify-pr-secret-boundaries.mjs
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = process.env.PR_SECRET_BOUNDARY_ROOT
  ? process.env.PR_SECRET_BOUNDARY_ROOT
  : join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const TRUSTED_PR_EXPR =
  'github.event_name != \'pull_request\' || (github.event.pull_request.head.repo.full_name == github.repository && contains(fromJSON(\'["OWNER","MEMBER","COLLABORATOR"]\'), github.event.pull_request.author_association))';

const failures = [];

function fail(file, message) {
  failures.push(`${file}: ${message}`);
}

function readRepoFile(path) {
  const absolute = join(REPO_ROOT, path);
  if (!existsSync(absolute)) {
    fail(path, "file is missing");
    return "";
  }
  return readFileSync(absolute, "utf8");
}

function indentOf(line) {
  return line.match(/^(\s*)/u)[1].length;
}

function isBlank(line) {
  return line.trim().length === 0;
}

function extractJob(source, jobName) {
  const lines = source.split("\n");
  const start = lines.findIndex((line) =>
    line.match(new RegExp(`^  ${jobName}:\\s*$`, "u")),
  );
  if (start === -1) return "";

  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line)) continue;
    if (indentOf(line) === 2 && /^  [A-Za-z0-9_-]+:\s*$/u.test(line)) {
      end = index;
      break;
    }
  }
  return lines.slice(start, end).join("\n");
}

function extractStep(job, stepName) {
  const lines = job.split("\n");
  const start = lines.findIndex((line) =>
    line.match(
      new RegExp(`^      - name:\\s*${escapeRegex(stepName)}\\s*$`, "u"),
    ),
  );
  if (start === -1) return "";

  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line)) continue;
    if (indentOf(line) === 6 && /^      - (?:name|uses|run):/u.test(line)) {
      end = index;
      break;
    }
  }
  return lines.slice(start, end).join("\n");
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function countNeedle(source, needle) {
  let count = 0;
  let index = source.indexOf(needle);
  while (index !== -1) {
    count += 1;
    index = source.indexOf(needle, index + needle.length);
  }
  return count;
}

function requireIncludes(file, source, needle, message) {
  if (!source.includes(needle)) fail(file, message);
}

function requireSingleOccurrence(file, source, needle, message) {
  const count = countNeedle(source, needle);
  if (count !== 1) fail(file, `${message} (found ${count})`);
}

function validateQaWorkflow() {
  const file = ".github/workflows/qa.yml";
  const source = readRepoFile(file);
  const job = extractJob(source, "functional-qa");
  const runQa = extractStep(job, "Run QA");

  requireIncludes(
    file,
    source,
    `INTERNAL_RUN: \${{ ${TRUSTED_PR_EXPR} }}`,
    "functional QA must require trusted same-repo PR authors before exposing QA secrets",
  );
  requireIncludes(
    file,
    runQa,
    "if: env.INTERNAL_RUN == 'true'",
    "Run QA secret-bearing step must be gated by INTERNAL_RUN",
  );

  for (const secret of [
    "FACTORY_API_KEY: ${{ secrets.FACTORY_API_KEY }}",
    "FIREBASE_PLIST_BASE64: ${{ secrets.FIREBASE_PLIST_BASE64 }}",
    "FIREBASE_APP_CHECK_DEBUG_TOKEN: ${{ secrets.FIREBASE_APP_CHECK_DEBUG_TOKEN }}",
    "QA_FIREBASE_EMAIL: ${{ secrets.QA_FIREBASE_EMAIL }}",
    "QA_FIREBASE_PASSWORD: ${{ secrets.QA_FIREBASE_PASSWORD }}",
  ]) {
    requireIncludes(file, runQa, secret, `Run QA is missing ${secret}`);
    requireSingleOccurrence(
      file,
      source,
      secret,
      `${secret} must only appear in the Run QA step`,
    );
  }
}

function validateCodeQualityWorkflow() {
  const file = ".github/workflows/code-quality.yml";
  const source = readRepoFile(file);
  const job = extractJob(source, "android-dependency-health");
  const templateStep = extractStep(
    job,
    "Use Android Firebase template for untrusted PRs",
  );
  const injectStep = extractStep(job, "Inject Android Firebase config");
  const androidSecret =
    "GOOGLE_SERVICES_JSON_BASE64: ${{ secrets.GOOGLE_SERVICES_JSON_BASE64 }}";

  requireIncludes(
    file,
    job,
    `TRUSTED_PR_SECRET_RUN: \${{ ${TRUSTED_PR_EXPR} }}`,
    "Android dependency health must require trusted same-repo PR authors before injecting Firebase secrets",
  );
  requireIncludes(
    file,
    job,
    "HAS_ANDROID_FIREBASE_SECRET: ${{ secrets.GOOGLE_SERVICES_JSON_BASE64 != '' }}",
    "Android dependency health must probe Firebase secret availability without exposing its value",
  );
  requireIncludes(
    file,
    templateStep,
    "if: env.TRUSTED_PR_SECRET_RUN != 'true' || env.HAS_ANDROID_FIREBASE_SECRET != 'true'",
    "untrusted or secretless PRs must use the non-secret Android Firebase template",
  );
  requireIncludes(
    file,
    templateStep,
    "cp android/app/google-services.json.template android/app/google-services.json",
    "untrusted or secretless PRs must materialize the non-secret Android Firebase template",
  );
  requireIncludes(
    file,
    injectStep,
    "if: env.TRUSTED_PR_SECRET_RUN == 'true' && env.HAS_ANDROID_FIREBASE_SECRET == 'true'",
    "real Android Firebase config injection must be trusted-author and secret-availability gated",
  );
  requireIncludes(
    file,
    injectStep,
    androidSecret,
    "real Android Firebase config injection step is missing its Firebase secret",
  );
  requireSingleOccurrence(
    file,
    source,
    androidSecret,
    "Android Firebase secret must only appear in the guarded injection step",
  );
}

function validateWorkflowLintWiring() {
  const file = ".github/workflows/workflow-lint.yml";
  const source = readRepoFile(file);
  for (const needle of [
    "scripts/ci/verify-pr-secret-boundaries.mjs",
    "scripts/ci/verify-pr-secret-boundaries.test.mjs",
    "node scripts/ci/verify-pr-secret-boundaries.test.mjs",
    "node scripts/ci/verify-pr-secret-boundaries.mjs",
  ]) {
    requireIncludes(
      file,
      source,
      needle,
      `workflow-lint must include ${needle}`,
    );
  }
}

validateQaWorkflow();
validateCodeQualityWorkflow();
validateWorkflowLintWiring();

if (failures.length > 0) {
  console.error("PR secret boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log(
  "PASS: PR-adjacent QA and Android secret surfaces are trusted-author gated with non-secret fallbacks.",
);
