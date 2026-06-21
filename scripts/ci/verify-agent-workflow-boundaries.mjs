#!/usr/bin/env node
/**
 * Static boundary gate for interactive agent workflows.
 *
 * Secrets-bearing agent workflows may post PR/issue feedback, but they must not
 * receive repository write checkout credentials or OIDC tokens by default. The
 * Factory API key must be passed only to the action invocation, the action must
 * receive the bounded workflow token explicitly instead of minting one through
 * OIDC, and PR-triggered agent runs must remain scoped to same-repository pull
 * requests.
 *
 * Usage:  node scripts/ci/verify-agent-workflow-boundaries.mjs
 * Exit:   0 = all scoped workflows are structurally gated; 1 = violation;
 *         2 = repository/workflow directory misconfigured.
 */

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = process.env.AGENT_WORKFLOW_BOUNDARY_ROOT
  ? process.env.AGENT_WORKFLOW_BOUNDARY_ROOT
  : join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WORKFLOW_DIR = join(REPO_ROOT, ".github", "workflows");

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

function hasDroidActionSurface(source) {
  return /Factory-AI\/droid-action@/u.test(source);
}

function hasDroidCliSurface(source) {
  const lines = source.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const runMatch = line.match(/^(\s*)run:\s*(.*)$/u);
    if (!runMatch) continue;
    if (/\bdroid\s+exec\b/u.test(runMatch[2])) return true;
    if (!/^\|/u.test(runMatch[2].trim())) continue;

    const runIndent = runMatch[1].length;
    for (let blockIndex = index + 1; blockIndex < lines.length; blockIndex += 1) {
      const blockLine = lines[blockIndex];
      if (blockLine.trim().length > 0 && blockLine.search(/\S/u) <= runIndent) break;
      if (/\bdroid\s+exec\b/u.test(blockLine)) return true;
    }
  }
  return false;
}

function hasInteractiveAgentSurface(source) {
  return hasDroidActionSurface(source) || hasDroidCliSurface(source);
}

function requireIncludes(file, source, needle, message) {
  if (!source.includes(needle)) fail(file, message);
}

for (const file of workflowFiles()) {
  const source = readFileSync(join(WORKFLOW_DIR, file), "utf8");
  if (!hasInteractiveAgentSurface(source)) continue;
  const usesDroidAction = hasDroidActionSurface(source);
  const usesDroidCli = hasDroidCliSurface(source);

  if (/contents:\s*write/u.test(source)) {
    fail(file, "interactive agent workflow must not request contents:write");
  }
  if (/id-token:\s*write/u.test(source)) {
    fail(file, "interactive agent workflow must not request id-token:write");
  }
  if (usesDroidAction) {
    if (/^\s*FACTORY_API_KEY:\s*\$\{\{\s*secrets\.FACTORY_API_KEY\s*\}\}/mu.test(source)) {
      fail(file, "Factory API key must not be exposed in Droid-action workflow or job env");
    }

    requireIncludes(
      file,
      source,
      "FACTORY_API_KEY_AVAILABLE: ${{ secrets.FACTORY_API_KEY != '' }}",
      "missing boolean Factory API key availability env",
    );
    requireIncludes(
      file,
      source,
      "if: env.FACTORY_API_KEY_AVAILABLE == 'false'",
      "missing fail-closed no-key skip step",
    );
    requireIncludes(
      file,
      source,
      "if: env.FACTORY_API_KEY_AVAILABLE == 'true'",
      "agent action must be gated by boolean Factory key availability",
    );
    requireIncludes(
      file,
      source,
      "factory_api_key: ${{ secrets.FACTORY_API_KEY }}",
      "Factory API key must be passed only as the Droid action input",
    );
    requireIncludes(
      file,
      source,
      "github_token: ${{ github.token }}",
      "Droid action must use the bounded workflow token instead of OIDC token minting",
    );
  }

  if (usesDroidCli) {
    requireIncludes(
      file,
      source,
      "FACTORY_API_KEY: ${{ secrets.FACTORY_API_KEY }}",
      "Droid CLI workflow must pass Factory key only to the Droid execution step",
    );
    if (!/if\s+\[\[\s+-z\s+"\$\{FACTORY_API_KEY\}"\s*\]\]/u.test(source)) {
      fail(file, "Droid CLI workflow must fail closed when FACTORY_API_KEY is unavailable");
    }
  }

  if (/uses:\s*actions\/checkout@/u.test(source) && !/persist-credentials:\s*false/u.test(source)) {
    fail(file, "agent workflow checkout must set persist-credentials:false");
  }

  if (
    /pull_request:/u.test(source) ||
    /pull_request_review:/u.test(source) ||
    /pull_request_review_comment:/u.test(source)
  ) {
    requireIncludes(
      file,
      source,
      "github.event.pull_request.head.repo.full_name == github.repository",
      "PR-triggered agent workflow must require same-repository pull requests",
    );
  }

  if (/issue_comment:/u.test(source)) {
    requireIncludes(
      file,
      source,
      "github.event.issue.pull_request == null",
      "issue-comment agent workflow must not run from PR comments",
    );
  }
}

if (failures.length > 0) {
  console.error("Agent workflow boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log("PASS: interactive agent workflows keep secrets and write privileges bounded.");
