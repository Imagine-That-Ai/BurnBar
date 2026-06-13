#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required for GitHub governance verification." >&2
  exit 2
fi

REPO="${GITHUB_REPOSITORY:-}"
if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
fi

BRANCH="${OPENBURNBAR_GOVERNANCE_BRANCH:-main}"
REQUIRED_CHECKS="${OPENBURNBAR_REQUIRED_BRANCH_CHECKS:-openburnbar-pr,Analyze (swift),Analyze (javascript-typescript),Analyze (python),Analyze (java-kotlin)}"
REQUIRED_ENVIRONMENTS="${OPENBURNBAR_REQUIRED_ENVIRONMENTS:-release,production}"
export BRANCH REQUIRED_CHECKS REQUIRED_ENVIRONMENTS

PROTECTION_JSON="$(mktemp)"
ENVIRONMENTS_JSON="$(mktemp)"
trap 'rm -f "$PROTECTION_JSON" "$ENVIRONMENTS_JSON"' EXIT

gh api \
  -H "Accept: application/vnd.github+json" \
  "/repos/${REPO}/branches/${BRANCH}/protection" >"$PROTECTION_JSON"

gh api \
  -H "Accept: application/vnd.github+json" \
  "/repos/${REPO}/environments" >"$ENVIRONMENTS_JSON"

node - "$PROTECTION_JSON" "$ENVIRONMENTS_JSON" <<'NODE'
const fs = require("fs");

const protection = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const environmentsPayload = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const requiredChecks = (process.env.REQUIRED_CHECKS || "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const requiredEnvironments = (process.env.REQUIRED_ENVIRONMENTS || "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);

const failures = [];

function fail(message) {
  failures.push(message);
}

const contexts = new Set([
  ...(protection.required_status_checks?.contexts || []),
  ...((protection.required_status_checks?.checks || []).map((check) => check.context).filter(Boolean)),
]);

if (protection.enforce_admins?.enabled !== true) {
  fail("main branch protection must enforce admins.");
}
if (protection.allow_force_pushes?.enabled === true) {
  fail("main branch protection must disable force pushes.");
}
if (protection.allow_deletions?.enabled === true) {
  fail("main branch protection must disable deletions.");
}
if ((protection.required_pull_request_reviews?.required_approving_review_count || 0) < 1) {
  fail("main branch protection must require at least one approving review.");
}
if (protection.required_conversation_resolution?.enabled !== true) {
  fail("main branch protection must require conversation resolution.");
}

const bypass = protection.required_pull_request_reviews?.bypass_pull_request_allowances || {};
const bypassCount =
  (bypass.users || []).length + (bypass.teams || []).length + (bypass.apps || []).length;
if (bypassCount > 0) {
  fail("main branch protection must not configure PR bypass users, teams, or apps.");
}

for (const check of requiredChecks) {
  if (!contexts.has(check)) {
    fail(`main branch protection is missing required status check: ${check}`);
  }
}

const environments = new Map((environmentsPayload.environments || []).map((env) => [env.name, env]));
for (const name of requiredEnvironments) {
  const env = environments.get(name);
  if (!env) {
    fail(`GitHub environment is missing: ${name}`);
    continue;
  }
  const rules = env.protection_rules || [];
  if (rules.length === 0) {
    fail(`GitHub environment ${name} must have at least one protection rule.`);
  }
  const branchPolicy = env.deployment_branch_policy;
  if (!branchPolicy || (branchPolicy.protected_branches !== true && branchPolicy.custom_branch_policies !== true)) {
    fail(`GitHub environment ${name} must restrict deployment branches.`);
  }
}

const summary = {
  branch: process.env.BRANCH || "main",
  adminsEnforced: protection.enforce_admins?.enabled === true,
  reviewCount: protection.required_pull_request_reviews?.required_approving_review_count || 0,
  requiredChecksPresent: requiredChecks.filter((check) => contexts.has(check)),
  requiredChecksMissing: requiredChecks.filter((check) => !contexts.has(check)),
  environments: requiredEnvironments.map((name) => {
    const env = environments.get(name);
    return {
      name,
      exists: Boolean(env),
      protectionRuleCount: env?.protection_rules?.length || 0,
      deploymentBranchPolicy: env?.deployment_branch_policy || null,
    };
  }),
  ok: failures.length === 0,
  failures,
};

console.log(JSON.stringify(summary, null, 2));

if (failures.length > 0) {
  process.exit(1);
}
NODE
