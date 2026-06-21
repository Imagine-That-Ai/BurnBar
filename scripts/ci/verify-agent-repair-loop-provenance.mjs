#!/usr/bin/env node
/**
 * Static provenance gate for privileged workflow_run repair loops.
 *
 * The invariant: a secrets-bearing/write-token repair job may only checkout or
 * hand off a PR after a no-secret read-only classifier proves that the PR is the
 * base repo's trusted repair branch, authored by the expected bot, and bound to
 * the triggering workflow_run head SHA. Manual dispatches must independently
 * prove the dispatcher still has write-level repository permission. Public PR
 * title/body marker text and workflow_run.pull_requests membership are
 * correlation only.
 *
 * Usage:  node scripts/ci/verify-agent-repair-loop-provenance.mjs
 * Exit:   0 = all scoped workflows are structurally gated; 1 = violation;
 *         2 = repository/workflow directory misconfigured.
 */

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = process.env.AGENT_REPAIR_PROVENANCE_ROOT
  ? process.env.AGENT_REPAIR_PROVENANCE_ROOT
  : join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WORKFLOW_DIR = join(REPO_ROOT, ".github", "workflows");
const ALLOWLIST = new Set(["supply-chain-provenance.yml"]);

const failures = [];
const fail = (file, message) => failures.push(`${file}: ${message}`);

function workflowFiles() {
  if (!existsSync(WORKFLOW_DIR)) {
    console.error(`MISCONFIGURED: workflow directory not found: ${WORKFLOW_DIR}`);
    process.exit(2);
  }
  return readdirSync(WORKFLOW_DIR)
    .filter((name) => /\.ya?ml$/u.test(name))
    .sort();
}

function hasPrivilegedRepairSurface(source) {
  return (
    /workflow_run:/u.test(source) &&
    /(?:secrets\.[A-Z0-9_]+|contents:\s*write|pull-requests:\s*write)/u.test(
      source,
    )
  );
}

function requireAll(file, source, checks) {
  for (const [needle, message] of checks) {
    if (!source.includes(needle)) fail(file, message);
  }
}

function extractStep(source, name) {
  const start = source.indexOf(`- name: ${name}`);
  if (start === -1) return "";
  const next = source.indexOf("\n      - name:", start + 1);
  return source.slice(start, next === -1 ? source.length : next);
}

for (const file of workflowFiles()) {
  const source = readFileSync(join(WORKFLOW_DIR, file), "utf8");
  if (!hasPrivilegedRepairSurface(source)) continue;
  if (ALLOWLIST.has(file)) {
    console.log(`ALLOW: ${file} is explicitly out of repair-loop scope.`);
    continue;
  }

  if (/in:title,body/u.test(source)) {
    fail(file, "must not use public PR title/body marker search as identity");
  }
  if (/\bgh\s+pr\s+checkout\b/u.test(source)) {
    fail(file, "must not checkout a PR number with gh pr checkout");
  }
  if (/group:\s*.*github\.event\.workflow_run\.head_branch/u.test(source)) {
    fail(file, "concurrency group must not include workflow_run.head_branch");
  }
  if (
    /^ {2,6}(?:GH_TOKEN|OPENAI_API_KEY|CURSOR_API_KEY|GIT_AUTH_TOKEN):\s*\$\{\{\s*(?:secrets|github\.token)/mu.test(
      source,
    )
  ) {
    fail(file, "secret or write-capable token is present in top-level/job env");
  }

  requireAll(file, source, [
    ["validate-provenance:", "missing read-only validate-provenance job"],
    ["needs: validate-provenance", "privileged job must depend on validate-provenance"],
    [
      "needs.validate-provenance.outputs.safe == 'true'",
      "privileged job must be gated by safe=true",
    ],
    ["--base main", "repair PR discovery must pin base branch main"],
    [
      '--head "${GH_OWNER}:${REPAIR_BRANCH}"',
      "repair PR discovery must pin the base-repo repair branch",
    ],
    ["baseRefName", "repair PR validation must inspect baseRefName"],
    ["headRefName", "repair PR validation must inspect headRefName"],
    ["headRefOid", "repair PR validation must inspect headRefOid"],
    ["isCrossRepository", "repair PR validation must reject cross-repo heads"],
    [
      "headRepositoryOwner.login",
      "repair PR validation must bind headRepositoryOwner.login",
    ],
    ["headRepository.name", "repair PR validation must bind headRepository.name"],
    ["author.login", "repair PR validation must bind PR author.login"],
    ["TRUSTED_AUTHOR", "repair PR validation must compare against TRUSTED_AUTHOR"],
    [
      ".workflow_run.head_repository.full_name",
      "workflow_run classifier must bind head_repository.full_name",
    ],
    [
      ".workflow_run.head_branch",
      "workflow_run classifier must bind head_branch",
    ],
    [".workflow_run.head_sha", "workflow_run classifier must bind head_sha"],
    [
      ".workflow_run.pull_requests",
      "workflow_run pull_requests may only be correlation after provenance",
    ],
    [".sender.login", "workflow_dispatch classifier must bind sender.login"],
    [
      'collaborators/${dispatch_actor}/permission',
      "workflow_dispatch classifier must verify actor repository permission",
    ],
    [
      "admin|maintain|write)",
      "workflow_dispatch classifier must require write-level actor permission",
    ],
  ]);

  if (/uses:\s*actions\/checkout@/u.test(source)) {
    if (!/persist-credentials:\s*false/u.test(source)) {
      fail(file, "actions/checkout must set persist-credentials:false");
    }
    requireAll(file, source, [
      [
        'fetch origin "+refs/heads/${ref}:refs/remotes/origin/${ref}"',
        "trusted branch continuation must fetch refs/heads from origin",
      ],
      [
        'git_fetch_ref "$REPAIR_BRANCH"',
        "continue mode must fetch the trusted repair branch",
      ],
      [
        'actual_head" != "$VALIDATED_HEAD_SHA"',
        "continue mode must verify fetched HEAD equals validated head SHA",
      ],
    ]);
  }

  if (/openai\/codex-action@/u.test(source)) {
    const codexStep = extractStep(source, "Run Codex");
    if (/\bGH_TOKEN\b|github-token/u.test(codexStep)) {
      fail(file, "Codex action step must not receive GH_TOKEN");
    }
    requireAll(file, source, [
      ["REDACTED_TOKEN", "published Codex output must redact token patterns"],
      ["REDACTED_SECRET", "published Codex output must redact exact secret values"],
      [
        "marker above is display-only",
        "repair PR body must say marker text is non-authoritative",
      ],
    ]);
  }

  if (source.includes("api.cursor.com/v1/agents")) {
    requireAll(file, source, [
      [
        "Refusing to send prUrl without a validated Cursor repair PR",
        "Cursor workflow must fail closed before sending unvalidated prUrl",
      ],
      ["REPAIR_PR_URL", "Cursor prUrl must come from validated provenance output"],
      ["cursor[bot]", "Cursor repair PR author must be pinned"],
    ]);
  }
}

if (failures.length > 0) {
  console.error("Agent repair loop provenance verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log("PASS: privileged agent repair loops use trusted repair-branch provenance.");
