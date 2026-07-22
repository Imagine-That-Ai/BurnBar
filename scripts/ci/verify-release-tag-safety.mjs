#!/usr/bin/env node
/**
 * Static boundary gate for the two-phase release tag safety model.
 *
 * Both deploy-production.yml and deploy-cloud-run.yml implement a fail-closed
 * two-phase sequence:
 *
 *   Phase 1 — dry-run (workflow_dispatch + dry_run=true):
 *     The dispatch ref is a non-tag candidate branch/SHA. The operator supplies
 *     candidate_sha (a full 40-char SHA). The resolve step fetches origin/main,
 *     requires candidate_sha == origin/main, checks out that exact commit, and
 *     emits it. The tag string (future v*) is validated as SemVer but must NOT
 *     already exist — no credential or deploy step runs.
 *
 *   Phase 2 — real deploy (push: v* tag, or manual non-dry-run dispatch):
 *     A v* tag push is the only initial real deploy trigger. Manual non-dry-run
 *     dispatch must run from that existing tag ref. Credentials stay tag-bound.
 *
 * This gate enforces the invariants that make both phases fail-closed and
 * symmetric across the two workflows.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT =
  process.env.RELEASE_TAG_SAFETY_ROOT ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const WORKFLOWS = [
  {
    file: join(ROOT, ".github", "workflows", "deploy-production.yml"),
    jobName: "prepare-functions-deploy",
    resolveStepName: "Resolve release tag",
    label: "deploy-production",
  },
  {
    file: join(ROOT, ".github", "workflows", "deploy-cloud-run.yml"),
    jobName: "resolve-release",
    resolveStepName: "Resolve and verify deploy tag",
    label: "deploy-cloud-run",
  },
];

const failures = [];
const fail = (message) => failures.push(message);

/* ── YAML helpers (same approach as verify-hosting-deploy-boundary.mjs) ── */

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

/* ── Per-workflow checks ───────────────────────────────────────────────── */

for (const wf of WORKFLOWS) {
  const { file, jobName, resolveStepName, label } = wf;

  if (!existsSync(file)) {
    fail(`[${label}] missing workflow file: ${file}`);
    continue;
  }

  const source = stripYamlComments(readFileSync(file, "utf8"));
  const job = jobBlock(source, jobName);
  const resolveStep = stepBlock(job, resolveStepName);
  const resolveRun = stepRunBlock(resolveStep);

  if (!job) {
    fail(`[${label}] missing job: ${jobName}`);
    continue;
  }
  if (!resolveStep) {
    fail(`[${label}] missing resolve step: ${resolveStepName}`);
    continue;
  }
  if (!resolveRun) {
    fail(`[${label}] resolve step has no run block`);
    continue;
  }

  /* Trigger model */
  requireIncludes(
    source,
    'push:\n    tags:\n      - "v*"',
    `[${label}] must preserve push trigger on v* tags`,
  );
  requireIncludes(
    source,
    "workflow_dispatch:",
    `[${label}] must support manual workflow_dispatch`,
  );

  /* candidate_sha input */
  requireIncludes(
    source,
    "candidate_sha:",
    `[${label}] must define candidate_sha workflow_dispatch input`,
  );
  requireIncludes(
    source,
    "Full SHA of the release candidate on origin/main (dry_run only)",
    `[${label}] candidate_sha input must document dry-run-only intent`,
  );

  /* Resolve step must not be conditional */
  if (/^\s{8}if\s*:/mu.test(resolveStep)) {
    fail(
      `[${label}] resolve step must not be conditional (runs in all dispatch modes)`,
    );
  }

  /* Env plumbing */
  requireIncludes(
    resolveStep,
    "INPUT_CANDIDATE_SHA: ${{ inputs.candidate_sha }}",
    `[${label}] resolve step must pass candidate_sha through env`,
  );
  requireIncludes(
    resolveStep,
    "INPUT_DRY_RUN: ${{ inputs.dry_run }}",
    `[${label}] resolve step must pass dry_run through env`,
  );
  requireIncludes(
    resolveStep,
    "EVENT_NAME: ${{ github.event_name }}",
    `[${label}] resolve step must read event name through env`,
  );

  /* Fail-closed shell */
  requireIncludes(
    resolveRun,
    "set -euo pipefail",
    `[${label}] resolve step must run fail-closed shell mode`,
  );

  /* IS_DRY_RUN computation */
  requireIncludes(
    resolveRun,
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "$INPUT_DRY_RUN" == "true" ]]; then',
    `[${label}] resolve step must compute IS_DRY_RUN from event + input`,
  );

  /* SemVer tag validation (applies in both phases) */
  requireIncludes(
    resolveRun,
    'if [[ ! "$TAG" =~ ^v[0-9]{1,3}\\.[0-9]+\\.[0-9]+',
    `[${label}] resolve step must validate SemVer v* tag format`,
  );

  /* ── Phase 1: dry-run candidate path ── */
  requireIncludes(
    resolveRun,
    'if [[ "$IS_DRY_RUN" == "true" ]]; then',
    `[${label}] resolve step must branch on IS_DRY_RUN for phase 1`,
  );
  requireIncludes(
    resolveRun,
    'if [[ -z "$INPUT_CANDIDATE_SHA" ]]; then',
    `[${label}] dry-run must require non-empty candidate_sha`,
  );
  requireIncludes(
    resolveRun,
    'if ! [[ "$INPUT_CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]]; then',
    `[${label}] dry-run must validate candidate_sha is a full 40-char hex SHA`,
  );
  requireIncludes(
    resolveRun,
    'if [[ "$GITHUB_REF" == "$tag_ref" ]]; then',
    `[${label}] dry-run must reject running from a tag ref`,
  );
  requireIncludes(
    resolveRun,
    'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"',
    `[${label}] dry-run must fetch origin/main before SHA comparison`,
  );
  requireIncludes(
    resolveRun,
    "git fetch --force --tags origin",
    `[${label}] dry-run must fetch tags to check if future tag already exists`,
  );
  requireIncludes(
    resolveRun,
    'if git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then',
    `[${label}] dry-run must reject if future tag already exists`,
  );
  requireIncludes(
    resolveRun,
    'main_sha="$(git rev-parse origin/main)"',
    `[${label}] dry-run must resolve origin/main to a SHA`,
  );
  requireIncludes(
    resolveRun,
    'if [[ "$INPUT_CANDIDATE_SHA" != "$main_sha" ]]; then',
    `[${label}] dry-run must require candidate_sha == origin/main`,
  );
  requireIncludes(
    resolveRun,
    'commit="$INPUT_CANDIDATE_SHA"',
    `[${label}] dry-run must emit the candidate commit`,
  );

  /* ── Phase 2: non-dry-run / tag-bound path ── */
  requireIncludes(
    resolveRun,
    'tag_ref="refs/tags/${TAG}"',
    `[${label}] non-dry-run path must build tag ref`,
  );
  requireIncludes(
    resolveRun,
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    `[${label}] manual non-dry-run dispatch must require tag ref`,
  );
  requireIncludes(
    resolveRun,
    'git fetch --force --tags origin "+${tag_ref}:${tag_ref}"',
    `[${label}] non-dry-run path must fetch the tag ref`,
  );
  requireIncludes(
    resolveRun,
    'git merge-base --is-ancestor "$commit" origin/main',
    `[${label}] non-dry-run path must verify tag commit is reachable from origin/main`,
  );

  /* ── Output: dry_run flag ── */
  requireIncludes(
    resolveRun,
    'echo "dry_run=$IS_DRY_RUN"',
    `[${label}] resolve step must emit IS_DRY_RUN (not inline expression)`,
  );

  /* ── Credential/deploy steps must be gated on dry_run != true ── */
  requireNoPattern(
    resolveRun,
    /\bcredential\b/i,
    `[${label}] resolve step must not reference credentials (dry-run is uncredentialed)`,
  );

  /* The deploy job(s) must check dry_run output to skip credentials */
  const allSteps = job.split("\n");
  const deployStepPattern = /Authenticate to Google Cloud/i;
  const hasDeployCredStep = allSteps.some((line) =>
    deployStepPattern.test(line),
  );
  if (hasDeployCredStep) {
    /* deploy-production.yml: credentials are in the same job */
    requireIncludes(
      job,
      "if: steps.tag.outputs.dry_run != 'true'",
      `[${label}] credential/deploy steps must be gated on dry_run != 'true'`,
    );
  }

  /* Sentry release step (deploy-production only) must be gated on dry_run != true */
  const sentryStep = stepBlock(job, "Sentry release (Functions)");
  if (sentryStep) {
    requireIncludes(
      sentryStep,
      "dry_run != 'true'",
      `[${label}] Sentry release step must be gated on dry_run != 'true'`,
    );
  }
}

/* ── Cross-workflow symmetry check ─────────────────────────────────────── */

function extractResolveRun(label) {
  const wf = WORKFLOWS.find((w) => w.label === label);
  if (!wf) return "";
  const source = stripYamlComments(readFileSync(wf.file, "utf8"));
  const job = jobBlock(source, wf.jobName);
  const step = stepBlock(job, wf.resolveStepName);
  return stepRunBlock(step);
}

const prodRun = extractResolveRun("deploy-production");
const cloudRun = extractResolveRun("deploy-cloud-run");

/* Extract the two-phase core logic (IS_DRY_RUN block) for symmetry */
function extractPhaseLogic(run) {
  const start = run.indexOf('if [[ "$IS_DRY_RUN" == "true" ]]; then');
  if (start === -1) return "";
  const end = run.indexOf("fi\n\n          {", start);
  if (end === -1) return "";
  return run.slice(start, end);
}

const prodPhase = extractPhaseLogic(prodRun);
const cloudPhase = extractPhaseLogic(cloudRun);

if (prodPhase && cloudPhase && prodPhase !== cloudPhase) {
  /* Allow minor differences in error messages but require structural parity */
  const normalize = (text) =>
    text
      .replace(/production/gi, "DEPLOY_TARGET")
      .replace(/cloud run/gi, "DEPLOY_TARGET")
      .replace(/Functions/g, "DEPLOY_TARGET")
      .replace(/functions/g, "DEPLOY_TARGET")
      .replace(/firebase/gi, "DEPLOY_TARGET");

  if (normalize(prodPhase) !== normalize(cloudPhase)) {
    fail(
      "deploy-production and deploy-cloud-run two-phase logic must be structurally symmetric",
    );
  }
}

/* ── Deploy-job dry_run gating for cloud-run (separate deploy job) ─────── */

const cloudSource = stripYamlComments(readFileSync(WORKFLOWS[1].file, "utf8"));
const cloudDeployJob = jobBlock(cloudSource, "deploy-hosted-mcp");
if (cloudDeployJob) {
  requireIncludes(
    cloudDeployJob,
    "if: needs.resolve-release.outputs.dry_run != 'true'",
    "[deploy-cloud-run] deploy-hosted-mcp job must be gated on dry_run != 'true'",
  );
}

const productionSource = stripYamlComments(
  readFileSync(WORKFLOWS[0].file, "utf8"),
);
const productionPrepareJob = jobBlock(
  productionSource,
  "prepare-functions-deploy",
);
const productionDeployJob = jobBlock(productionSource, "deploy-functions");
requireIncludes(
  productionPrepareJob,
  'if [[ -n "${GITHUB_SHA:-}" && "$commit" != "$GITHUB_SHA" ]]; then',
  "[deploy-production] release tag must match the workflow event commit",
);
requireNoPattern(
  productionPrepareJob,
  /(?:environment:\s*production|id-token:\s*write|secrets\.|google-github-actions\/auth)/u,
  "[deploy-production] prepare-functions-deploy must not receive production credentials",
);
requireIncludes(
  productionDeployJob,
  "needs: prepare-functions-deploy",
  "[deploy-production] deploy-functions must consume prepare-functions-deploy",
);
requireIncludes(
  productionDeployJob,
  "needs.prepare-functions-deploy.outputs.dry_run != 'true'",
  "[deploy-production] deploy-functions must be skipped during dry-run",
);
requireIncludes(
  productionDeployJob,
  "sha256sum --check --strict SHA256SUMS",
  "[deploy-production] deploy-functions must verify the immutable artifact checksum",
);
requireNoPattern(
  productionDeployJob,
  /actions\/checkout@/u,
  "[deploy-production] credentialed deploy-functions must not check out repository code",
);

/* ── Attestation invariants ────────────────────────────────────────────── */

/* Both workflows must publish a dry-run attestation on success */
for (const wf of WORKFLOWS) {
  const source = stripYamlComments(readFileSync(wf.file, "utf8"));
  requireIncludes(
    source,
    "release-dry-run-attestation.mjs",
    `[${wf.label}] must reference the release-dry-run-attestation.mjs script`,
  );
  requireIncludes(
    source,
    "Publish dry-run attestation",
    `[${wf.label}] must have a Publish dry-run attestation step`,
  );
  requireIncludes(
    source,
    `--plane ${wf.label}`,
    `[${wf.label}] publish step must attest with its own plane name`,
  );

  /* Publish must be gated on dry_run == true */
  if (wf.label === "deploy-production") {
    /* deploy-production: publish step is in the same job, gated at step level */
    const deployJob = jobBlock(source, wf.jobName);
    const publishStep = stepBlock(deployJob, "Publish dry-run attestation");
    if (publishStep) {
      requireIncludes(
        publishStep,
        "dry_run == 'true'",
        `[${wf.label}] publish attestation step must be gated on dry_run == 'true'`,
      );
    } else {
      fail(`[${wf.label}] publish attestation step not found in ${wf.jobName}`);
    }
  } else {
    /* deploy-cloud-run: publish step is in cloud-run-dry-run-summary job, gated at job level */
    const summaryJob = jobBlock(source, "cloud-run-dry-run-summary");
    if (summaryJob) {
      const summaryPublishStep = stepBlock(
        summaryJob,
        "Publish dry-run attestation",
      );
      if (summaryPublishStep) {
        requireIncludes(
          summaryJob,
          "needs.resolve-release.outputs.dry_run == 'true'",
          `[${wf.label}] dry-run summary job must be gated on dry_run == 'true'`,
        );
      } else {
        fail(
          `[${wf.label}] publish attestation step not found in cloud-run-dry-run-summary`,
        );
      }
    } else {
      fail(`[${wf.label}] missing cloud-run-dry-run-summary job`);
    }
  }
}

/* Both workflows must verify attestations before credentials */
for (const wf of WORKFLOWS) {
  const source = stripYamlComments(readFileSync(wf.file, "utf8"));
  requireIncludes(
    source,
    "Verify dry-run attestations",
    `[${wf.label}] must have a Verify dry-run attestations step`,
  );
  requireIncludes(
    source,
    "release-dry-run-attestation.mjs verify",
    `[${wf.label}] must call attestation verify mode before credentials`,
  );

  /* Verify must be gated on dry_run != true (only real deploys need verification) */
  if (wf.label === "deploy-production") {
    const verifyStep = stepBlock(
      jobBlock(source, wf.jobName),
      "Verify dry-run attestations",
    );
    if (verifyStep) {
      requireIncludes(
        verifyStep,
        "dry_run != 'true'",
        `[${wf.label}] verify attestation step must be gated on dry_run != 'true'`,
      );
    } else {
      fail(`[${wf.label}] verify attestation step not found in ${wf.jobName}`);
    }
  } else {
    /* deploy-cloud-run: verify is in a separate verify-attestations job */
    const verifyJob = jobBlock(source, "verify-attestations");
    if (verifyJob) {
      requireIncludes(
        verifyJob,
        "needs.resolve-release.outputs.dry_run != 'true'",
        `[${wf.label}] verify-attestations job must be gated on dry_run != 'true'`,
      );
      requireIncludes(
        cloudDeployJob,
        "verify-attestations",
        `[${wf.label}] deploy-hosted-mcp must depend on verify-attestations`,
      );
    } else {
      fail(`[${wf.label}] missing verify-attestations job`);
    }
  }

  /* Verify must come before any credential/auth step */
  const fullSource = source;
  const verifyIdx = fullSource.indexOf("Verify dry-run attestations");
  const authIdx = fullSource.indexOf("Authenticate to Google Cloud");
  if (verifyIdx !== -1 && authIdx !== -1 && verifyIdx > authIdx) {
    fail(`[${wf.label}] verify attestation step must precede credential auth`);
  }
}

/* Both workflows must grant statuses: write for attestation */
for (const wf of WORKFLOWS) {
  const source = stripYamlComments(readFileSync(wf.file, "utf8"));
  requireIncludes(
    source,
    "statuses: write",
    `[${wf.label}] must grant statuses: write for attestation publish/verify`,
  );
}

/* ── Report ────────────────────────────────────────────────────────────── */

if (failures.length > 0) {
  console.error(
    `FAIL: ${failures.length} release-tag-safety invariant(s) violated:\n`,
  );
  for (const message of failures) {
    console.error(`  - ${message}`);
  }
  process.exit(1);
}

console.log(
  "PASS: both deploy workflows enforce two-phase release tag safety with attestation.",
);
