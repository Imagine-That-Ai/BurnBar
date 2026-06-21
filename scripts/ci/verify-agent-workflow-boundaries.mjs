#!/usr/bin/env node
/**
 * Static boundary gate for interactive agent workflows.
 *
 * Secrets-bearing agent workflows may post PR/issue feedback, but they must not
 * receive repository write checkout credentials by default. The Factory API key
 * must be passed only to the action invocation or the Droid CLI execution step,
 * interactive executions must receive the bounded workflow token explicitly,
 * and PR-triggered agent runs must remain scoped to same-repository pull
 * requests. The only OIDC exception is the pinned automatic Droid review
 * validator, which requires id-token:write after the main review run.
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
    if (char === "#" && !singleQuoted && !doubleQuoted && (index === 0 || /\s/u.test(previous))) {
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

function indentOf(line) {
  return line.match(/^(\s*)/u)[1].length;
}

function isBlank(line) {
  return line.trim().length === 0;
}

function blockSource(lines, start, end) {
  return lines.slice(start, end).join("\n");
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
    if (blockHasDroidExec(runMatch[2])) return true;
    if (!/^[>|]/u.test(runMatch[2].trim())) continue;

    const runIndent = runMatch[1].length;
    for (let blockIndex = index + 1; blockIndex < lines.length; blockIndex += 1) {
      const blockLine = lines[blockIndex];
      if (!isBlank(blockLine) && indentOf(blockLine) <= runIndent) break;
      if (blockHasDroidExec(blockLine)) return true;
    }
  }
  return false;
}

function hasInteractiveAgentSurface(source) {
  return hasDroidActionSurface(source) || hasDroidCliSurface(source);
}

function jobBlocks(source) {
  const lines = source.split("\n");
  const jobsIndex = lines.findIndex((line) => /^(\s*)jobs:\s*$/u.test(line));
  if (jobsIndex === -1) return [{ start: 0, end: lines.length, source }];

  const jobsIndent = indentOf(lines[jobsIndex]);
  let jobIndent = null;
  const blocks = [];
  for (let index = jobsIndex + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line)) continue;
    const lineIndent = indentOf(line);
    if (lineIndent <= jobsIndent) break;

    const jobMatch = line.match(/^(\s*)[A-Za-z0-9_-]+:\s*$/u);
    if (!jobMatch) continue;
    if (jobIndent === null) jobIndent = lineIndent;
    if (lineIndent !== jobIndent) continue;

    let end = lines.length;
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      const cursorLine = lines[cursor];
      if (isBlank(cursorLine)) continue;
      const cursorIndent = indentOf(cursorLine);
      if (cursorIndent <= jobsIndent) {
        end = cursor;
        break;
      }
      if (cursorIndent === jobIndent && /^(\s*)[A-Za-z0-9_-]+:\s*$/u.test(cursorLine)) {
        end = cursor;
        break;
      }
    }
    blocks.push({ start: index, end, source: blockSource(lines, index, end) });
    index = end - 1;
  }

  return blocks.length > 0 ? blocks : [{ start: 0, end: lines.length, source }];
}

function stepBlocks(source) {
  const lines = source.split("\n");
  const blocks = [];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const stepsMatch = line.match(/^(\s*)steps:\s*$/u);
    if (!stepsMatch) continue;

    const stepsIndent = stepsMatch[1].length;
    let stepIndent = null;
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      const cursorLine = lines[cursor];
      if (isBlank(cursorLine)) continue;
      const cursorIndent = indentOf(cursorLine);
      if (cursorIndent <= stepsIndent) break;

      const stepMatch = cursorLine.match(/^(\s*)-\s+/u);
      if (!stepMatch) continue;
      if (stepIndent === null) stepIndent = stepMatch[1].length;
      if (stepMatch[1].length !== stepIndent) continue;

      let end = lines.length;
      for (let endCursor = cursor + 1; endCursor < lines.length; endCursor += 1) {
        const endLine = lines[endCursor];
        if (isBlank(endLine)) continue;
        const endIndent = indentOf(endLine);
        if (endIndent <= stepsIndent) {
          end = endCursor;
          break;
        }
        const nextStep = endLine.match(/^(\s*)-\s+/u);
        if (nextStep && nextStep[1].length === stepIndent) {
          end = endCursor;
          break;
        }
      }
      blocks.push({ start: cursor, end, source: blockSource(lines, cursor, end) });
      cursor = end - 1;
    }
  }
  return blocks;
}

function blockContainingLine(blocks, lineIndex) {
  return blocks.find((block) => block.start <= lineIndex && lineIndex < block.end);
}

function uniqueBlocks(blocks) {
  return [...new Map(blocks.map((block) => [block.start, block])).values()];
}

function requireInBlock(file, block, needle, message) {
  if (!block.source.includes(needle)) fail(file, message);
}

function hasDroidReviewOidcException(step) {
  return (
    hasDroidActionSurface(step.source) &&
    /automatic_review:\s*true/u.test(step.source) &&
    /automatic_security_review:\s*true/u.test(step.source) &&
    step.source.includes("github_token: ${{ github.token }}") &&
    step.source.includes("factory_api_key: ${{ secrets.FACTORY_API_KEY }}")
  );
}

for (const file of workflowFiles()) {
  const rawSource = readFileSync(join(WORKFLOW_DIR, file), "utf8");
  const source = stripYamlComments(rawSource);
  if (!hasInteractiveAgentSurface(source)) continue;

  const usesDroidAction = hasDroidActionSurface(source);
  const usesDroidCli = hasDroidCliSurface(source);
  const jobs = jobBlocks(source);
  const steps = stepBlocks(source);
  const droidActionSteps = steps.filter((step) => hasDroidActionSurface(step.source));
  const droidActionJobs = uniqueBlocks(
    droidActionSteps
      .map((step) => blockContainingLine(jobs, step.start))
      .filter(Boolean),
  );

  if (/contents:\s*write/u.test(source)) {
    fail(file, "interactive agent workflow must not request contents:write");
  }
  if (/id-token:\s*write/u.test(source) && !droidActionSteps.some(hasDroidReviewOidcException)) {
    fail(file, "interactive agent workflow must not request id-token:write outside automatic Droid review validation");
  }

  if (usesDroidAction) {
    if (FACTORY_KEY_ENV.test(source)) {
      fail(file, "Factory API key must not be exposed in Droid-action workflow or job env");
    }

    for (const job of droidActionJobs) {
      requireInBlock(
        file,
        job,
        "FACTORY_API_KEY_AVAILABLE: ${{ secrets.FACTORY_API_KEY != '' }}",
        "missing boolean Factory API key availability env",
      );
      requireInBlock(
        file,
        job,
        "if: env.FACTORY_API_KEY_AVAILABLE == 'false'",
        "missing fail-closed no-key skip step",
      );
    }

    for (const step of droidActionSteps) {
      requireInBlock(
        file,
        step,
        "if: env.FACTORY_API_KEY_AVAILABLE == 'true'",
        "agent action must be gated by boolean Factory key availability",
      );
      requireInBlock(
        file,
        step,
        "factory_api_key: ${{ secrets.FACTORY_API_KEY }}",
        "Factory API key must be passed only as the Droid action input",
      );
      requireInBlock(
        file,
        step,
        "github_token: ${{ github.token }}",
        "Droid action must use the bounded workflow token instead of OIDC token minting",
      );
    }
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
    const owningStep = blockContainingLine(steps, index);
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
    for (const job of droidActionJobs) {
      requireInBlock(
        file,
        job,
        "github.event.pull_request.head.repo.full_name == github.repository",
        "PR-triggered agent workflow must require same-repository pull requests",
      );
    }
  }

  if (/issue_comment:/u.test(source)) {
    for (const job of droidActionJobs) {
      requireInBlock(
        file,
        job,
        "steps.pr-comment-scope.outputs.allowed == 'true'",
        "issue-comment agent workflow must gate Droid execution on resolved PR comment scope",
      );
      requireInBlock(
        file,
        job,
        "github.event.issue.pull_request.url",
        "issue-comment agent workflow must look up PR metadata before running on PR comments",
      );
      requireInBlock(
        file,
        job,
        ".head.repo.full_name",
        "issue-comment agent workflow must verify PR comments come from same-repository pull requests",
      );
    }
  }
}

if (failures.length > 0) {
  console.error("Agent workflow boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log("PASS: interactive agent workflows keep secrets and write privileges bounded.");
