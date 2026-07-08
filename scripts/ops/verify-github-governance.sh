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
# The required-status-check set and review/admin invariants are NOT hand-maintained
# here. They are read from the governance source of truth
# (governance/branch-protection.main.json) by the drift check below — the previous
# DEFAULT_REQUIRED_CHECKS constant had already drifted (it omitted the native, app,
# and daemon gates entirely; governance/README.md §Consumers). Sourcing from the
# JSON makes it the single source of truth and can only strengthen the bar.
REQUIRED_ENVIRONMENTS="${OPENBURNBAR_REQUIRED_ENVIRONMENTS:-release,production}"
BRANCH_PROTECTION_SOURCE="${OPENBURNBAR_BRANCH_PROTECTION_SOURCE:-governance/branch-protection.main.json}"
export BRANCH REQUIRED_ENVIRONMENTS
export OPENBURNBAR_GOVERNANCE_REPO="$REPO"
export OPENBURNBAR_GOVERNANCE_BRANCH="$BRANCH"

# 1. Branch-protection drift: live protection (ruleset endpoints first, classic
#    additionally) vs governance/branch-protection.main.json. Fails CLOSED on any
#    divergence — reviews wiped, admins un-enforced, force-push/deletion enabled,
#    review count/code-owner/last-push/conversation drift, any bypass actor, or a
#    required-check set difference in either direction (governance/README.md §Drift).
echo "==> branch-protection drift (live vs governance/branch-protection.main.json)"
OPENBURNBAR_BRANCH_PROTECTION_SOURCE="$BRANCH_PROTECTION_SOURCE" \
  node scripts/ops/check-branch-protection-drift.mjs

# 2. Deployment-environment protection (release/production) still verified directly
#    against the live GitHub API — this is environment state, not encoded in the
#    branch-protection file.
ENVIRONMENTS_JSON="$(mktemp)"
trap 'rm -f "$ENVIRONMENTS_JSON"' EXIT

gh api \
  -H "Accept: application/vnd.github+json" \
  "/repos/${REPO}/environments" >"$ENVIRONMENTS_JSON"

echo "==> deployment-environment protection (${REQUIRED_ENVIRONMENTS})"
node - "$ENVIRONMENTS_JSON" <<'NODE'
const fs = require("fs");

const environmentsPayload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const requiredEnvironments = (process.env.REQUIRED_ENVIRONMENTS || "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const failures = [];

function fail(message) {
  failures.push(message);
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

echo "PASS: GitHub governance verification (branch-protection drift + environment protection)"
