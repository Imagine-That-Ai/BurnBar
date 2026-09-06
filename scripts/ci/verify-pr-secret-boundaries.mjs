#!/usr/bin/env node
/**
 * Static boundary gate for PR-adjacent workflow secrets.
 *
 * Pull-request workflows may run untrusted repository code. QA must keep
 * secret-backed functional flows off pull_request entirely, and other lanes
 * that expose real runtime secrets must prove the PR is a same-repository
 * branch from a trusted actor with a non-secret fallback for untrusted PRs.
 * This verifier covers the current QA and Android dependency-health secret
 * surfaces and is wired through workflow-lint.
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
  '(github.event_name == \'schedule\' || github.event_name == \'workflow_dispatch\') || (github.event_name == \'pull_request\' && github.event.pull_request.head.repo.full_name == github.repository && contains(fromJSON(\'["OWNER","MEMBER","COLLABORATOR"]\'), github.event.pull_request.author_association))';
const MAIN_PUSH_OR_SCHEDULE_EXPR =
  "github.ref == 'refs/heads/main' && (github.event_name == 'push' || github.event_name == 'schedule')";

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

function stripYamlComment(line) {
  let singleQuoted = false;
  let doubleQuoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    const previous = line[index - 1];
    if (char === "'" && !doubleQuoted) singleQuoted = !singleQuoted;
    if (char === '"' && !singleQuoted && previous !== "\\") {
      doubleQuoted = !doubleQuoted;
    }
    if (char === "#" && !singleQuoted && !doubleQuoted) {
      return line.slice(0, index).trimEnd();
    }
  }
  return line;
}

function stripYamlComments(source) {
  return source.split("\n").map(stripYamlComment).join("\n");
}

function indentOf(line) {
  return line.match(/^(\s*)/u)[1].length;
}

function isBlank(line) {
  return line.trim().length === 0;
}

function extractJob(source, jobName) {
  const lines = stripYamlComments(source).split("\n");
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
  const lines = stripYamlComments(job).split("\n");
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

function requireOccurrenceCount(file, source, needle, expected, message) {
  const count = countNeedle(source, needle);
  if (count !== expected) fail(file, `${message} (found ${count})`);
}

function fieldValue(block, key, indent) {
  const prefix = `${" ".repeat(indent)}${key}:`;
  const line = stripYamlComments(block)
    .split("\n")
    .find((candidate) => candidate.startsWith(prefix));
  return line ? line.slice(prefix.length).trim() : null;
}

function requireFieldEquals(file, block, key, indent, expected, message) {
  const actual = fieldValue(block, key, indent);
  if (actual !== expected) {
    fail(file, `${message} (found ${actual ?? "missing"})`);
  }
}

function hasEnvEntry(block, envIndent, name, expectedValue) {
  const prefix = `${" ".repeat(envIndent)}env:`;
  const lines = stripYamlComments(block).split("\n");
  const envStart = lines.findIndex((line) => line === prefix);
  if (envStart === -1) return false;
  for (let index = envStart + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line)) continue;
    if (indentOf(line) <= envIndent) break;
    if (
      line.trim() === `${name}: ${expectedValue}` ||
      line.trim() === `${name}: "${expectedValue}"`
    ) {
      return true;
    }
  }
  return false;
}

function requireEnvEntry(file, block, envIndent, name, expectedValue, message) {
  if (!hasEnvEntry(block, envIndent, name, expectedValue)) {
    fail(file, message);
  }
}

function secretReferenceLines(block) {
  return stripYamlComments(block)
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => /\$\{\{\s*secrets\.[A-Za-z0-9_]+/u.test(line));
}

function requireOnlyAllowedSecretLines(file, block, allowedLines, message) {
  const allowed = new Set(allowedLines);
  for (const line of secretReferenceLines(block)) {
    if (!allowed.has(line)) fail(file, `${message}: ${line}`);
  }
}

function extractTriggerPaths(source, triggerName) {
  const lines = stripYamlComments(source).split("\n");
  const triggerStart = lines.findIndex((line) => line === `  ${triggerName}:`);
  if (triggerStart === -1) return [];

  let triggerEnd = lines.length;
  for (let index = triggerStart + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line)) continue;
    if (indentOf(line) <= 2) {
      triggerEnd = index;
      break;
    }
  }

  const block = lines.slice(triggerStart, triggerEnd);
  const pathsStart = block.findIndex((line) => line === "    paths:");
  if (pathsStart === -1) return [];

  const paths = [];
  for (let index = pathsStart + 1; index < block.length; index += 1) {
    const line = block[index];
    if (isBlank(line)) continue;
    if (indentOf(line) <= 4) break;
    const match = line.match(/^\s*-\s*["']?([^"']+)["']?\s*$/u);
    if (match) paths.push(match[1]);
  }
  return paths;
}

function validateQaWorkflow() {
  const file = ".github/workflows/qa.yml";
  const runnerFile = "tools/qa/run-functional-qa.sh";
  const source = stripYamlComments(readRepoFile(file));
  const runner = readRepoFile(runnerFile);
  const job = extractJob(source, "functional-qa");
  const resolvePr = extractStep(job, "Resolve PR metadata");
  const runPrSafeQa = extractStep(job, "Run PR-safe QA");
  const runSecretBackedQa = extractStep(job, "Run secret-backed QA");
  const postQa = extractStep(job, "Post QA report as PR comment");
  const githubToken = "GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}";
  const requiredQaSecrets = [
    "FACTORY_API_KEY: ${{ secrets.FACTORY_API_KEY }}",
    "FIREBASE_PLIST_BASE64: ${{ secrets.FIREBASE_PLIST_BASE64 }}",
    "FIREBASE_APP_CHECK_DEBUG_TOKEN: ${{ secrets.FIREBASE_APP_CHECK_DEBUG_TOKEN }}",
    "QA_FIREBASE_EMAIL: ${{ secrets.QA_FIREBASE_EMAIL }}",
    "QA_FIREBASE_PASSWORD: ${{ secrets.QA_FIREBASE_PASSWORD }}",
  ];

  requireEnvEntry(
    file,
    job,
    4,
    "RUN_PR_SAFE_QA",
    "${{ github.event_name == 'pull_request' || github.event_name == 'merge_group' || github.ref != 'refs/heads/main' }}",
    "functional QA must run the non-secret PR-safe lane for pull requests, merge groups, and non-main manual dispatches",
  );
  requireEnvEntry(
    file,
    job,
    4,
    "RUN_SECRET_BACKED_QA",
    "${{ github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main' }}",
    "functional QA secret-backed lane must be restricted to manual dispatch on main",
  );
  requireFieldEquals(
    file,
    runPrSafeQa,
    "if",
    8,
    "env.RUN_PR_SAFE_QA == 'true'",
    "PR-safe QA step must run only through the non-secret QA lane",
  );
  requireEnvEntry(
    file,
    runPrSafeQa,
    8,
    "CI",
    "true",
    "PR-safe QA must run in CI mode",
  );
  requireEnvEntry(
    file,
    runPrSafeQa,
    8,
    "OPENBURNBAR_QA_SECRET_MODE",
    "pr-safe",
    "PR-safe QA must explicitly select the no-secret runner mode",
  );
  const prSafeSecretLines = secretReferenceLines(runPrSafeQa);
  if (prSafeSecretLines.length > 0) {
    fail(
      file,
      `PR-safe QA step must not reference secrets: ${prSafeSecretLines.join(", ")}`,
    );
  }
  requireFieldEquals(
    file,
    runSecretBackedQa,
    "if",
    8,
    "env.RUN_SECRET_BACKED_QA == 'true'",
    "secret-backed QA step must be gated by workflow_dispatch on main",
  );
  requireEnvEntry(
    file,
    runSecretBackedQa,
    8,
    "OPENBURNBAR_QA_SECRET_MODE",
    "full",
    "secret-backed QA must explicitly select the full runner mode",
  );
  requireEnvEntry(
    file,
    runSecretBackedQa,
    8,
    "OPENBURNBAR_USE_DEBUG_APP_CHECK",
    "YES",
    "secret-backed QA must be the only lane that enables debug App Check injection",
  );

  for (const secret of requiredQaSecrets) {
    const [name, value] = secret.split(": ");
    requireEnvEntry(
      file,
      runSecretBackedQa,
      8,
      name,
      value,
      `secret-backed QA is missing ${secret}`,
    );
    requireSingleOccurrence(
      file,
      source,
      secret,
      `${secret} must only appear in the secret-backed QA step`,
    );
  }
  requireEnvEntry(
    file,
    resolvePr,
    8,
    "GH_TOKEN",
    "${{ secrets.GITHUB_TOKEN }}",
    "Resolve PR metadata must be the first GITHUB_TOKEN consumer",
  );
  requireEnvEntry(
    file,
    postQa,
    8,
    "GH_TOKEN",
    "${{ secrets.GITHUB_TOKEN }}",
    "Post QA report must be the second GITHUB_TOKEN consumer",
  );
  requireOccurrenceCount(
    file,
    source,
    githubToken,
    2,
    "GITHUB_TOKEN must only appear in QA metadata/comment steps",
  );
  requireOnlyAllowedSecretLines(
    file,
    job,
    [
      ...requiredQaSecrets,
      githubToken,
    ],
    "functional QA contains unallowlisted secret reference",
  );
  requireIncludes(
    runnerFile,
    runner,
    'qa_secret_mode="${OPENBURNBAR_QA_SECRET_MODE:-full}"',
    "functional QA runner must default to full secret-backed mode",
  );
  requireIncludes(
    runnerFile,
    runner,
    "full|pr-safe)",
    "functional QA runner must support explicit pr-safe mode",
  );
  requireIncludes(
    runnerFile,
    runner,
    "PR-safe mode intentionally receives no secret-backed QA credentials.",
    "functional QA runner must treat secret-backed credentials as skipped in pr-safe mode",
  );
  requireIncludes(
    runnerFile,
    runner,
    "strip_pr_safe_secret_environment",
    "functional QA runner must strip inherited secret variables in pr-safe mode",
  );
  requireIncludes(
    runnerFile,
    runner,
    'unset "$secret_name"',
    "functional QA runner must unset known secret variables in pr-safe mode",
  );
  requireIncludes(
    runnerFile,
    runner,
    'if [[ "$qa_secret_mode" == "pr-safe" ]]; then\n  strip_pr_safe_secret_environment\nfi',
    "functional QA runner must call the pr-safe secret stripper before checks run",
  );
}

function validateCodeQualityWorkflow() {
  const file = ".github/workflows/code-quality.yml";
  const source = stripYamlComments(readRepoFile(file));
  const job = extractJob(source, "android-dependency-health");
  const templateStep = extractStep(
    job,
    "Use Android Firebase template for untrusted PRs",
  );
  const injectStep = extractStep(job, "Inject Android Firebase config");
  const androidSecret =
    "GOOGLE_SERVICES_JSON_BASE64: ${{ secrets.GOOGLE_SERVICES_JSON_BASE64 }}";

  requireEnvEntry(
    file,
    job,
    4,
    "TRUSTED_PR_SECRET_RUN",
    `\${{ ${TRUSTED_PR_EXPR} }}`,
    "Android dependency health must require trusted same-repo PR authors before injecting Firebase secrets",
  );
  requireEnvEntry(
    file,
    job,
    4,
    "HAS_ANDROID_FIREBASE_SECRET",
    "${{ secrets.GOOGLE_SERVICES_JSON_BASE64 != '' }}",
    "Android dependency health must probe Firebase secret availability without exposing its value",
  );
  requireFieldEquals(
    file,
    templateStep,
    "if",
    8,
    "env.TRUSTED_PR_SECRET_RUN != 'true' || env.HAS_ANDROID_FIREBASE_SECRET != 'true'",
    "untrusted or secretless PRs must use the non-secret Android Firebase template",
  );
  requireIncludes(
    file,
    templateStep,
    "cp android/app/google-services.json.template android/app/google-services.json",
    "untrusted or secretless PRs must materialize the non-secret Android Firebase template",
  );
  requireFieldEquals(
    file,
    injectStep,
    "if",
    8,
    "env.TRUSTED_PR_SECRET_RUN == 'true' && env.HAS_ANDROID_FIREBASE_SECRET == 'true'",
    "real Android Firebase config injection must be trusted-author and secret-availability gated",
  );
  requireEnvEntry(
    file,
    injectStep,
    8,
    "GOOGLE_SERVICES_JSON_BASE64",
    "${{ secrets.GOOGLE_SERVICES_JSON_BASE64 }}",
    "real Android Firebase config injection step is missing its Firebase secret",
  );
  requireSingleOccurrence(
    file,
    source,
    androidSecret,
    "Android Firebase secret must only appear in the guarded injection step",
  );
  requireOnlyAllowedSecretLines(
    file,
    job,
    [
      "HAS_ANDROID_FIREBASE_SECRET: ${{ secrets.GOOGLE_SERVICES_JSON_BASE64 != '' }}",
      androidSecret,
    ],
    "Android dependency health contains unallowlisted secret reference",
  );
}

function validateOpenBurnBarPrHarnessWorkflow() {
  const file = ".github/workflows/openburnbar-pr-harness.yml";
  const source = stripYamlComments(readRepoFile(file));
  const androidSecret =
    "GOOGLE_SERVICES_JSON_BASE64: ${{ secrets.GOOGLE_SERVICES_JSON_BASE64 }}";
  const iosFirebaseSecrets = [
    "FIREBASE_PLIST_BASE64: ${{ secrets.FIREBASE_PLIST_BASE64 }}",
    "FIREBASE_APP_CHECK_DEBUG_TOKEN: ${{ secrets.FIREBASE_APP_CHECK_DEBUG_TOKEN }}",
  ];

  const androidJob = extractJob(source, "android");
  const androidTemplateStep = extractStep(
    androidJob,
    "Use Android Firebase template when secret run is not allowed",
  );
  const androidInjectStep = extractStep(androidJob, "Inject Android Firebase config");
  const androidUploadStep = extractStep(androidJob, "Upload Android APK");

  requireEnvEntry(
    file,
    androidJob,
    4,
    "ALLOW_ANDROID_FIREBASE_SECRET_RUN",
    `\${{ ${MAIN_PUSH_OR_SCHEDULE_EXPR} }}`,
    "full harness Android job must only allow real Firebase config on reviewed main push/schedule runs",
  );
  requireEnvEntry(
    file,
    androidJob,
    4,
    "HAS_ANDROID_SECRETS",
    "${{ secrets.GOOGLE_SERVICES_JSON_BASE64 != '' }}",
    "full harness Android job must probe Firebase secret availability without exposing its value",
  );
  requireFieldEquals(
    file,
    androidTemplateStep,
    "if",
    8,
    "env.ALLOW_ANDROID_FIREBASE_SECRET_RUN != 'true' || env.HAS_ANDROID_SECRETS != 'true'",
    "full harness Android job must use the non-secret template when real config is not allowed",
  );
  requireIncludes(
    file,
    androidTemplateStep,
    "cp android/app/google-services.json.template android/app/google-services.json",
    "full harness Android template step must materialize the non-secret Firebase template",
  );
  requireFieldEquals(
    file,
    androidInjectStep,
    "if",
    8,
    "env.ALLOW_ANDROID_FIREBASE_SECRET_RUN == 'true' && env.HAS_ANDROID_SECRETS == 'true'",
    "full harness Android real Firebase injection must be main push/schedule gated",
  );
  requireEnvEntry(
    file,
    androidInjectStep,
    8,
    "GOOGLE_SERVICES_JSON_BASE64",
    "${{ secrets.GOOGLE_SERVICES_JSON_BASE64 }}",
    "full harness Android injection step is missing its Firebase secret",
  );
  requireFieldEquals(
    file,
    androidUploadStep,
    "if",
    8,
    "env.ALLOW_ANDROID_FIREBASE_SECRET_RUN != 'true' || env.HAS_ANDROID_SECRETS != 'true'",
    "full harness must not upload APK artifacts built with real Android Firebase config",
  );
  requireOnlyAllowedSecretLines(
    file,
    androidJob,
    [
      "HAS_ANDROID_SECRETS: ${{ secrets.GOOGLE_SERVICES_JSON_BASE64 != '' }}",
      androidSecret,
    ],
    "full harness Android job contains unallowlisted secret reference",
  );

  const hermesSmokeJob = extractJob(source, "android-hermes-smoke");
  const hermesTemplateStep = extractStep(
    hermesSmokeJob,
    "Use Android Firebase template when secret run is not allowed",
  );
  const hermesInjectStep = extractStep(hermesSmokeJob, "Inject Android Firebase config");
  requireEnvEntry(
    file,
    hermesSmokeJob,
    4,
    "ALLOW_ANDROID_FIREBASE_SECRET_RUN",
    `\${{ ${MAIN_PUSH_OR_SCHEDULE_EXPR} }}`,
    "Android Hermes smoke must only allow real Firebase config on reviewed main push/schedule runs",
  );
  requireFieldEquals(
    file,
    hermesTemplateStep,
    "if",
    8,
    "env.ALLOW_ANDROID_FIREBASE_SECRET_RUN != 'true' || env.HAS_ANDROID_SECRETS != 'true'",
    "Android Hermes smoke must use the non-secret template when real config is not allowed",
  );
  requireFieldEquals(
    file,
    hermesInjectStep,
    "if",
    8,
    "env.ALLOW_ANDROID_FIREBASE_SECRET_RUN == 'true' && env.HAS_ANDROID_SECRETS == 'true'",
    "Android Hermes smoke real Firebase injection must be main push/schedule gated",
  );
  requireOnlyAllowedSecretLines(
    file,
    hermesSmokeJob,
    [
      "HAS_ANDROID_SECRETS: ${{ secrets.GOOGLE_SERVICES_JSON_BASE64 != '' }}",
      androidSecret,
    ],
    "Android Hermes smoke contains unallowlisted secret reference",
  );

  const mercuryJob = extractJob(source, "mercury-media-e2e");
  const mercuryAndroidInjectStep = extractStep(mercuryJob, "Inject Android Firebase config");
  const mercuryAndroidTemplateStep = extractStep(
    mercuryJob,
    "Generate dummy google-services.json when secret unavailable",
  );
  const mercuryIosInjectStep = extractStep(mercuryJob, "Inject Firebase config");
  requireEnvEntry(
    file,
    mercuryJob,
    4,
    "ALLOW_FIREBASE_SECRET_RUN",
    `\${{ ${MAIN_PUSH_OR_SCHEDULE_EXPR} }}`,
    "Mercury media job must only allow real Firebase config on reviewed main push/schedule runs",
  );
  requireFieldEquals(
    file,
    mercuryAndroidInjectStep,
    "if",
    8,
    "env.ALLOW_FIREBASE_SECRET_RUN == 'true' && env.HAS_ANDROID_SECRETS == 'true'",
    "Mercury Android Firebase injection must be main push/schedule gated",
  );
  requireFieldEquals(
    file,
    mercuryAndroidTemplateStep,
    "if",
    8,
    "env.ALLOW_FIREBASE_SECRET_RUN != 'true' || env.HAS_ANDROID_SECRETS != 'true'",
    "Mercury Android lane must generate a dummy config when real config is not allowed",
  );
  requireFieldEquals(
    file,
    mercuryIosInjectStep,
    "if",
    8,
    "env.ALLOW_FIREBASE_SECRET_RUN == 'true' && env.HAS_FIREBASE_SECRETS == 'true'",
    "Mercury iOS Firebase injection must be main push/schedule gated",
  );
  requireOnlyAllowedSecretLines(
    file,
    mercuryJob,
    [
      "HAS_ANDROID_SECRETS: ${{ secrets.GOOGLE_SERVICES_JSON_BASE64 != '' }}",
      "HAS_FIREBASE_SECRETS: ${{ secrets.FIREBASE_PLIST_BASE64 != '' && secrets.FIREBASE_APP_CHECK_DEBUG_TOKEN != '' }}",
      androidSecret,
      ...iosFirebaseSecrets,
    ],
    "Mercury media job contains unallowlisted secret reference",
  );
}

function validateWorkflowLintWiring() {
  const file = ".github/workflows/workflow-lint.yml";
  const source = stripYamlComments(readRepoFile(file));
  for (const path of [
    "scripts/ci/verify-pr-secret-boundaries.mjs",
    "scripts/ci/verify-pr-secret-boundaries.test.mjs",
  ]) {
    for (const trigger of ["pull_request", "push"]) {
      if (!extractTriggerPaths(source, trigger).includes(path)) {
        fail(file, `${trigger} paths must include ${path}`);
      }
    }
  }

  for (const needle of [
    "node scripts/ci/verify-pr-secret-boundaries.test.mjs",
    "node scripts/ci/verify-pr-secret-boundaries.mjs",
    'go-version: "1.25.0"',
    "github.com/rhysd/actionlint/cmd/actionlint@v1.7.12",
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
validateOpenBurnBarPrHarnessWorkflow();
validateWorkflowLintWiring();

if (failures.length > 0) {
  console.error("PR secret boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log(
  "PASS: PR-adjacent QA and Android/Firebase secret surfaces are trusted-author gated with non-secret fallbacks.",
);
