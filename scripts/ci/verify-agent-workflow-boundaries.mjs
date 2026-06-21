#!/usr/bin/env node
/**
 * Static boundary gate for interactive agent workflows.
 *
 * Secrets-bearing agent workflows may post PR/issue feedback, but they must not
 * receive repository write checkout credentials or OIDC tokens by default. The
 * Factory API key must be passed only to the action invocation, interactive
 * executions must receive the bounded workflow token explicitly, and
 * PR-triggered agent runs must remain scoped to same-repository pull requests.
 * The only OIDC exception is the pinned automatic Droid review validator, which
 * requires id-token:write after the main review run.
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
const FACTORY_KEY_ENV = /^\s*FACTORY_API_KEY:\s*\$\{\{\s*secrets\.FACTORY_API_KEY\s*\}\}/mu;

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

function blockHasDroidExec(source) {
  return /\bdroid\s+exec\b/u.test(source);
}

function hasDroidCliSurface(source) {
  const lines = source.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const runMatch = line.match(/^(\s*)run:\s*(.*)$/u);
    if (!runMatch) continue;
    if (/\bdroid\s+exec\b/u.test(runMatch[2])) return true;
    if (!/^[>|]/u.test(runMatch[2].trim())) continue;

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

function stepBlocks(source) {
  const lines = source.split("\n");
  const blocks = [];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const stepMatch = line.match(/^(\s*)-\s+/u);
    if (!stepMatch) continue;
    const stepIndent = stepMatch[1].length;
    let end = lines.length;
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      const nextLine = lines[cursor];
      const nextStep = nextLine.match(/^(\s*)-\s+/u);
      if (nextStep && nextStep[1].length <= stepIndent) {
        end = cursor;
        break;
      }
    }
    blocks.push({ start: index, end, source: lines.slice(index, end).join("\n") });
  }
  return blocks;
}

function stepContainingLine(blocks, lineIndex) {
  return blocks.find((block) => block.start <= lineIndex && lineIndex < block.end);
}

function hasDroidReviewOidcException(source) {
  return (
    hasDroidActionSurface(source) &&
    /automatic_review:\s*true/u.test(source) &&
    /automatic_security_review:\s*true/u.test(source) &&
    source.includes("github_token: ${{ github.token }}") &&
    source.includes("factory_api_key: ${{ secrets.FACTORY_API_KEY }}")
  );
}

for (const file of workflowFiles()) {
  const source = readFileSync(join(WORKFLOW_DIR, file), "utf8");
  if (!hasInteractiveAgentSurface(source)) continue;
  const usesDroidAction = hasDroidActionSurface(source);
  const usesDroidCli = hasDroidCliSurface(source);
  const steps = stepBlocks(source);

  if (/contents:\s*write/u.test(source)) {
    fail(file, "interactive agent workflow must not request contents:write");
  }
  if (/id-token:\s*write/u.test(source) && !hasDroidReviewOidcException(source)) {
    fail(file, "interactive agent workflow must not request id-token:write outside automatic Droid review validation");
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
    if (
      !steps.some((step) => blockHasDroidExec(step.source) && FACTORY_KEY_ENV.test(step.source))
    ) {
      fail(file, "Droid CLI workflow must pass Factory key only to the Droid execution step");
    }
    if (!/if\s+\[\[\s+-z\s+"\$\{FACTORY_API_KEY\}"\s*\]\]/u.test(source)) {
      fail(file, "Droid CLI workflow must fail closed when FACTORY_API_KEY is unavailable");
    }
  }

  source.split("\n").forEach((line, index) => {
    if (!FACTORY_KEY_ENV.test(line)) return;
    const owningStep = stepContainingLine(steps, index);
    if (!owningStep || !blockHasDroidExec(owningStep.source)) {
      fail(file, "Factory API key secret env must appear only on Droid CLI execution steps");
    }
  });

  for (const step of steps) {
    if (/uses:\s*actions\/checkout@/u.test(step.source) && !/persist-credentials:\s*false/u.test(step.source)) {
      fail(file, "each agent workflow checkout must set persist-credentials:false");
    }
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
      "steps.pr-comment-scope.outputs.allowed == 'true'",
      "issue-comment agent workflow must gate Droid execution on resolved PR comment scope",
    );
    requireIncludes(
      file,
      source,
      "github.event.issue.pull_request.url",
      "issue-comment agent workflow must look up PR metadata before running on PR comments",
    );
    requireIncludes(
      file,
      source,
      ".head.repo.full_name",
      "issue-comment agent workflow must verify PR comments come from same-repository pull requests",
    );
  }
}

if (failures.length > 0) {
  console.error("Agent workflow boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log("PASS: interactive agent workflows keep secrets and write privileges bounded.");
