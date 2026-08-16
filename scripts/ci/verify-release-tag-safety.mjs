#!/usr/bin/env node
/**
 * Static boundary gate for the two-phase release tag safety model.
 *
 * Both deploy-production.yml and deploy-cloud-run.yml implement a fail-closed
 * two-phase sequence:
 *
 *   Phase 1 — dry-run (workflow_dispatch + dry_run=true from main):
 *     The operator supplies candidate_sha (a full 40-char SHA). A future v*
 *     tag requires that SHA to equal current origin/main. An already-existing
 *     stable tag may use the one-shot recovery verifier when it is annotated,
 *     peels to the candidate, remains reachable from origin/main, and has no
 *     GitHub Release, production deployment, or plane status.
 *
 *   Phase 2 — real deploy:
 *     A v* tag push is the ordinary immutable trigger. Existing-tag recovery
 *     uses a dedicated main-only existing_tag_retry dispatch that verifies the
 *     current-main control SHA and both exact dry-run run receipts before the
 *     immutable tag payload is checked out or executed. Tag-selected manual
 *     dispatch and rerun are forbidden.
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
const RECOVERY_GATE = join(
  ROOT,
  "scripts",
  "ci",
  "verify-existing-tag-dry-run-recovery.mjs",
);
const ATTESTATION_GATE = join(
  ROOT,
  "scripts",
  "ci",
  "release-dry-run-attestation.mjs",
);

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

if (!existsSync(RECOVERY_GATE)) {
  fail(`missing existing-tag recovery gate: ${RECOVERY_GATE}`);
}
if (!existsSync(ATTESTATION_GATE)) {
  fail(`missing release dry-run attestation gate: ${ATTESTATION_GATE}`);
}

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
    "Full immutable release-candidate SHA",
    `[${label}] candidate_sha input must document immutable candidate semantics`,
  );
  requireIncludes(
    source,
    "existing_tag_retry:",
    `[${label}] must define a dedicated existing_tag_retry input`,
  );
  requireIncludes(
    source,
    'description: "Current-main controlled real retry for an existing stable tag"',
    `[${label}] existing_tag_retry must be an explicit workflow_dispatch input`,
  );
  requireIncludes(
    source,
    `run-name: release-control/${label}/`,
    `[${label}] run-name must expose the exact attestation receipt`,
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
    "INPUT_EXISTING_TAG_RETRY: ${{ inputs.existing_tag_retry }}",
    `[${label}] resolve step must pass existing_tag_retry through env`,
  );
  requireIncludes(
    resolveStep,
    "EVENT_NAME: ${{ github.event_name }}",
    `[${label}] resolve step must read event name through env`,
  );
  requireIncludes(
    resolveStep,
    "GITHUB_TOKEN: ${{ github.token }}",
    `[${label}] resolve step must receive only the scoped GitHub token for recovery reads`,
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
  requireIncludes(
    resolveRun,
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "$INPUT_EXISTING_TAG_RETRY" == "true" ]]; then',
    `[${label}] resolve step must compute the dedicated retry mode`,
  );
  requireIncludes(
    resolveRun,
    'if [[ "$IS_DRY_RUN" == "true" && "$IS_EXISTING_TAG_RETRY" == "true" ]]; then',
    `[${label}] dry-run and real retry must be mutually exclusive`,
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
    'if [[ "$IS_DRY_RUN" == "true" || "$IS_EXISTING_TAG_RETRY" == "true" ]]; then',
    `[${label}] resolve step must isolate all manual main-only control`,
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
    'if [[ "$EVENT_NAME" != "workflow_dispatch" || "$GITHUB_REF" != "refs/heads/main" || "$REF_NAME" != "main" ]]; then',
    `[${label}] manual release control must require workflow_dispatch from main`,
  );
  requireIncludes(
    resolveRun,
    'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"',
    `[${label}] dry-run must fetch origin/main before SHA comparison`,
  );
  requireIncludes(
    resolveRun,
    "git fetch --force --tags origin",
    `[${label}] dry-run must fetch tags before deciding normal vs recovery mode`,
  );
  requireIncludes(
    resolveRun,
    'main_sha="$(git rev-parse origin/main)"',
    `[${label}] dry-run must resolve origin/main to a SHA`,
  );
  requireIncludes(
    resolveRun,
    'elif [[ "$INPUT_CANDIDATE_SHA" != "$main_sha" ]]; then',
    `[${label}] future-tag dry-run must require candidate_sha == origin/main`,
  );
  requireIncludes(
    resolveRun,
    'commit="$INPUT_CANDIDATE_SHA"',
    `[${label}] dry-run must emit the candidate commit`,
  );

  /* Existing stable-tag recovery */
  requireIncludes(
    resolveRun,
    'if git rev-parse --verify --quiet "$tag_ref" >/dev/null; then',
    `[${label}] dry-run must isolate existing-tag recovery from the normal future-tag path`,
  );
  requireIncludes(
    resolveRun,
    'if [[ ! "$TAG" =~ ^v[0-9]{1,3}\\.[0-9]+\\.[0-9]+(\\+[0-9A-Za-z.-]+)?$ ]]; then',
    `[${label}] existing-tag recovery must reject prerelease tags`,
  );
  requireIncludes(
    resolveRun,
    'if [[ "$EVENT_NAME" != "workflow_dispatch" || "$GITHUB_REF" != "refs/heads/main" || "$REF_NAME" != "main" ]]; then',
    `[${label}] existing-tag recovery must require workflow_dispatch from main`,
  );
  requireIncludes(
    resolveRun,
    'if [[ "${GITHUB_SHA:-}" != "$main_sha" ]]; then',
    `[${label}] manual control must bind the workflow SHA to current main`,
  );
  requireIncludes(
    resolveRun,
    'if [[ "$(git cat-file -t "$tag_ref")" != "tag" ]]; then',
    `[${label}] existing-tag recovery must require an annotated tag object`,
  );
  requireIncludes(
    resolveRun,
    'tag_commit="$(git rev-parse "${tag_ref}^{commit}")"',
    `[${label}] existing-tag recovery must peel the tag to a commit`,
  );
  requireIncludes(
    resolveRun,
    'if [[ "$tag_commit" != "$INPUT_CANDIDATE_SHA" ]]; then',
    `[${label}] existing-tag recovery must require the tag to peel to candidate_sha`,
  );
  requireIncludes(
    resolveRun,
    'git merge-base --is-ancestor "$tag_commit" origin/main',
    `[${label}] existing-tag recovery must require tag reachability from origin/main`,
  );
  requireIncludes(
    resolveRun,
    "node scripts/ci/verify-existing-tag-dry-run-recovery.mjs",
    `[${label}] existing-tag recovery must run the GitHub-state verifier`,
  );
  requireIncludes(
    resolveRun,
    `--plane ${label}`,
    `[${label}] existing-tag recovery must check its own status context`,
  );
  requireIncludes(
    resolveRun,
    `--plane ${label}\n    else`,
    `[${label}] dry-run recovery must execute its absence verifier before the real-retry branch`,
  );
  requireOrder(
    resolveRun,
    'if git rev-parse --verify --quiet "$tag_ref" >/dev/null; then',
    'elif [[ "$IS_EXISTING_TAG_RETRY" == "true" ]]; then',
    `[${label}] current-main equality must apply only to the future-tag path`,
  );

  /* ── Phase 2: existing-tag retry or immutable tag push ── */
  requireIncludes(
    resolveRun,
    "--mode real-retry",
    `[${label}] existing-tag real retry must recheck GitHub Release absence`,
  );
  requireIncludes(
    resolveRun,
    'node "$RUNNER_TEMP/release-dry-run-attestation.mjs" verify',
    `[${label}] existing-tag real retry must use the preserved current-main verifier`,
  );
  requireIncludes(
    resolveRun,
    '--control-sha "$GITHUB_SHA"',
    `[${label}] existing-tag real retry must bind attestations to the exact control SHA`,
  );
  requireOrder(
    resolveRun,
    "--mode real-retry",
    'node "$RUNNER_TEMP/release-dry-run-attestation.mjs" verify',
    `[${label}] retry publication eligibility must be rechecked before attestation authority`,
  );
  requireOrder(
    resolveRun,
    'node "$RUNNER_TEMP/release-dry-run-attestation.mjs" verify',
    'commit="$INPUT_CANDIDATE_SHA"',
    `[${label}] real-retry authority must be verified before candidate selection`,
  );
  requireIncludes(
    resolveRun,
    'tag_ref="refs/tags/${TAG}"',
    `[${label}] non-dry-run path must build tag ref`,
  );
  requireIncludes(
    resolveRun,
    'if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then',
    `[${label}] ordinary non-dry-run path must reject every manual dispatch`,
  );
  requireIncludes(
    resolveRun,
    "tag-selected dispatches and reruns are forbidden",
    `[${label}] tag-selected manual recovery must be explicitly forbidden`,
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
  requireIncludes(
    resolveRun,
    'echo "existing_tag_retry=$IS_EXISTING_TAG_RETRY"',
    `[${label}] resolve step must emit dedicated retry mode`,
  );
  requireIncludes(
    resolveRun,
    'echo "control_sha=${GITHUB_SHA:-}"',
    `[${label}] resolve step must emit the exact trusted control SHA`,
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
  const start = run.indexOf(
    'if [[ "$IS_DRY_RUN" == "true" || "$IS_EXISTING_TAG_RETRY" == "true" ]]; then',
  );
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
      .replace(/cloud-run/gi, "DEPLOY_TARGET")
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
const cloudResolveJob = jobBlock(cloudSource, "resolve-release");
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
const productionRollbackAuthorizationJob = jobBlock(
  productionSource,
  "authorize-domain-core-rollback",
);
const productionDeployJob = jobBlock(productionSource, "deploy-functions");
const productionResultJob = jobBlock(productionSource, "functions-result");
const productionEvidenceDispatchJob = jobBlock(
  productionSource,
  "dispatch-domain-core-functions-evidence",
);
const productionEvidenceHandoffJob = jobBlock(
  productionSource,
  "retain-domain-core-functions-evidence-handoff",
);
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
  productionRollbackAuthorizationJob,
  "needs: prepare-functions-deploy",
  "[deploy-production] rollback authorization must follow trusted release preparation",
);
requireIncludes(
  productionRollbackAuthorizationJob,
  "needs.prepare-functions-deploy.result == 'success'",
  "[deploy-production] rollback authorization must require successful trusted release preparation",
);
requireIncludes(
  productionRollbackAuthorizationJob,
  "needs.prepare-functions-deploy.outputs.dry_run != 'true'",
  "[deploy-production] rollback dry-runs must not enter the protected environment",
);
requireIncludes(
  productionRollbackAuthorizationJob,
  "needs.prepare-functions-deploy.outputs.domain_core_profile == 'public-production-rollback'",
  "[deploy-production] rollback authorization must consume the resolved profile",
);
requireNoPattern(
  productionPrepareJob,
  /needs:\s*authorize-domain-core-rollback/u,
  "[deploy-production] trusted release preparation must precede rollback authorization",
);
requireOrder(
  productionSource,
  "prepare-functions-deploy:",
  "authorize-domain-core-rollback:",
  "[deploy-production] rollback authorization must be declared after trusted release preparation",
);
requireNoPattern(
  cloudResolveJob,
  /(?:environment:\s*production|id-token:\s*write|secrets\.|google-github-actions\/auth)/u,
  "[deploy-cloud-run] resolve-release must not receive production credentials",
);
requireIncludes(
  productionPrepareJob,
  "deployments: read",
  "[deploy-production] recovery resolver must have read-only deployment visibility",
);
requireIncludes(
  cloudResolveJob,
  "deployments: read",
  "[deploy-cloud-run] recovery resolver must have read-only deployment visibility",
);
requireIncludes(
  cloudResolveJob,
  "actions: read",
  "[deploy-cloud-run] main-only retry resolver must have read-only Actions API access",
);
requireIncludes(
  cloudResolveJob,
  "statuses: read",
  "[deploy-cloud-run] recovery resolver must have read-only status visibility",
);
requireIncludes(
  productionDeployJob,
  "needs: [prepare-functions-deploy, authorize-domain-core-rollback]",
  "[deploy-production] deploy-functions must consume preparation and protected rollback authorization",
);
requireIncludes(
  productionDeployJob,
  "needs.prepare-functions-deploy.outputs.dry_run != 'true'",
  "[deploy-production] deploy-functions must be skipped during dry-run",
);
requireIncludes(
  productionDeployJob,
  "needs.authorize-domain-core-rollback.result == 'success'",
  "[deploy-production] rollback deploy must require protected authorization",
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
requireIncludes(
  productionResultJob,
  "if: ${{ always() && !inputs.dry_run }}",
  "[deploy-production] workflow_dispatch booleans must use the typed inputs context",
);
requireNoPattern(
  productionResultJob,
  /github\.event\.inputs\.dry_run/u,
  "[deploy-production] workflow_dispatch booleans must not use stringly github.event.inputs",
);
requireIncludes(
  productionEvidenceDispatchJob,
  "needs.deploy-functions.outputs.existing_tag_retry != 'true'",
  "[deploy-production] existing-tag retries must not dispatch release evidence before the Release exists",
);
for (const marker of [
  "needs.deploy-functions.outputs.existing_tag_retry == 'true'",
  "domain-core-functions-release-evidence-handoff.json",
  "requiresPublishedGitHubRelease: true",
  "--field deploy_run_id=",
  "--field deploy_run_attempt=",
  "--field domain_core_profile=",
  "actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4",
]) {
  requireIncludes(
    productionEvidenceHandoffJob,
    marker,
    `[deploy-production] existing-tag retry evidence handoff is missing ${marker}`,
  );
}

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
    'verify --sha "$ATTEST_SHA" --tag "$ATTEST_TAG"',
    `[${wf.label}] must call attestation verify mode for the exact tag and SHA before credentials`,
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

const cloudVerifyAttestationsJob = jobBlock(cloudSource, "verify-attestations");
const cloudDryRunSummaryJob = jobBlock(
  cloudSource,
  "cloud-run-dry-run-summary",
);
requireIncludes(
  productionPrepareJob,
  "actions: read",
  "[deploy-production] attestation verify must have read-only Actions API access",
);
requireIncludes(
  productionPrepareJob,
  "statuses: write",
  "[deploy-production] attestation publish must have commit-status write access",
);
requireIncludes(
  cloudVerifyAttestationsJob,
  "actions: read",
  "[deploy-cloud-run] attestation verify must have read-only Actions API access",
);
requireIncludes(
  cloudVerifyAttestationsJob,
  "statuses: read",
  "[deploy-cloud-run] attestation verify must have read-only commit-status access",
);
requireNoPattern(
  cloudVerifyAttestationsJob,
  /(?:environment:\s*production|id-token:\s*write|secrets\.|google-github-actions\/auth)/u,
  "[deploy-cloud-run] attestation verify must not receive a production environment, secrets, or OIDC",
);
requireNoPattern(
  cloudVerifyAttestationsJob,
  /ref:\s*\$\{\{\s*needs\.resolve-release\.outputs\.commit\s*\}\}/u,
  "[deploy-cloud-run] attestation verification must not check out or execute candidate code",
);
requireIncludes(
  cloudDryRunSummaryJob,
  "statuses: write",
  "[deploy-cloud-run] attestation publish must have commit-status write access",
);
requireIncludes(
  productionPrepareJob,
  "Stage trusted release attestation helper",
  "[deploy-production] must preserve the workflow-ref attestation helper before checking out the candidate",
);
requireIncludes(
  productionPrepareJob,
  "persist-credentials: false",
  "[deploy-production] current-main control checkout must not persist credentials into candidate execution",
);
requireOrder(
  productionPrepareJob,
  "Stage trusted release attestation helper",
  'git checkout --detach "$commit"',
  "[deploy-production] must preserve the current-main helper before candidate checkout",
);
requireOrder(
  productionPrepareJob,
  '--control-sha "$GITHUB_SHA"',
  'git checkout --detach "$commit"',
  "[deploy-production] existing-tag retry authority must be verified before candidate checkout",
);
requireIncludes(
  productionPrepareJob,
  'node "$RUNNER_TEMP/release-dry-run-attestation.mjs"',
  "[deploy-production] publish and verify must use the preserved workflow-ref helper",
);
for (const [job, label] of [
  [cloudVerifyAttestationsJob, "verify"],
  [cloudDryRunSummaryJob, "publish"],
]) {
  requireIncludes(
    job,
    "Check out trusted release attestation helper",
    `[deploy-cloud-run] ${label} must check out the workflow-ref attestation helper`,
  );
  requireIncludes(
    job,
    "ref: ${{ github.sha }}",
    `[deploy-cloud-run] ${label} helper must bind to the exact workflow run SHA`,
  );
  requireIncludes(
    job,
    "persist-credentials: false",
    `[deploy-cloud-run] ${label} helper checkout must not persist credentials`,
  );
  requireIncludes(
    job,
    ".release-attestation-control/scripts/ci/release-dry-run-attestation.mjs",
    `[deploy-cloud-run] ${label} must execute the workflow-ref helper`,
  );
}

const attestationSource = readFileSync(ATTESTATION_GATE, "utf8");
requireIncludes(
  attestationSource,
  "getAllPages(`/commits/${sha}/statuses?per_page=100`)",
  "[attestation] verify must read every raw commit-status page",
);
requireIncludes(
  attestationSource,
  "newestExactStatus(statuses, context)",
  "[attestation] verify must evaluate the newest exact-context status",
);
requireIncludes(
  attestationSource,
  'status.creator?.login !== "github-actions[bot]"',
  "[attestation] verify must require the GitHub Actions bot status creator",
);
requireIncludes(
  attestationSource,
  "`/actions/runs/${runId}`",
  "[attestation] verify must resolve the attesting Actions run through the API",
);
requireIncludes(
  attestationSource,
  '"deploy-production": ".github/workflows/deploy-production.yml"',
  "[attestation] production status must bind the production workflow path",
);
requireIncludes(
  attestationSource,
  '"deploy-cloud-run": ".github/workflows/deploy-cloud-run.yml"',
  "[attestation] cloud status must bind the cloud workflow path",
);
requireIncludes(
  attestationSource,
  "target_url: targetUrl",
  "[attestation] publish must bind the status to its exact Actions run URL",
);
requireIncludes(
  attestationSource,
  'run?.head_branch === "main"',
  "[attestation] verify must bind the attesting run to the main control ref",
);
requireIncludes(
  attestationSource,
  "run?.head_sha === controlSha",
  "[attestation] verify must bind the attesting run to the exact trusted control SHA",
);
requireIncludes(
  attestationSource,
  "run?.display_title === receiptTitle({ plane, tag, sha, controlSha })",
  "[attestation] verify must bind the exact dispatched plane/tag/candidate/control receipt",
);
requireIncludes(
  attestationSource,
  "release-control/${plane}/dry-run/${tag}/${sha}/${controlSha}",
  "[attestation] receipt title must include full plane/tag/candidate/control identities",
);

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
  "PASS: both deploy workflows enforce main-controlled existing-tag recovery and real retry.",
);
