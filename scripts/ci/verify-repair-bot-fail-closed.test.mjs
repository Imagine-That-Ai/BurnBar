#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const workflowPath = path.join(root, ".github/workflows/codex-nightly-ci-repair.yml");
const baseRevision = "9503b490b0";
const workflow = readFileSync(workflowPath, "utf8");

function jobBlock(source, name) {
  const marker = `  ${name}:\n`;
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `workflow is missing job ${name}`);
  const remainder = source.slice(start + marker.length);
  const next = remainder.search(/\n  [A-Za-z0-9_-]+:\n/u);
  return next === -1
    ? source.slice(start)
    : source.slice(start, start + marker.length + next);
}

function stepBlock(job, name) {
  const marker = `      - name: ${name}\n`;
  const start = job.indexOf(marker);
  assert.notEqual(start, -1, `job is missing step ${name}`);
  const remainder = job.slice(start + marker.length);
  const next = remainder.search(/\n      - (?:name:|uses:)/u);
  return next === -1
    ? job.slice(start)
    : job.slice(start, start + marker.length + next);
}

function scriptBlock(step) {
  const start = step.indexOf("        run: |\n");
  assert.notEqual(start, -1, "step is missing a block run script");
  const lines = [];
  for (const line of step.slice(start + "        run: |\n".length).split("\n")) {
    if (!line.startsWith("          ")) break;
    lines.push(line.slice(10));
  }
  return `${lines.join("\n")}\n`;
}

const validateProvenance = jobBlock(workflow, "validate-provenance");
const repairJob = jobBlock(workflow, "repair-nightly-ci");
const summaryJob = jobBlock(workflow, "fail-closed-summary");

test("the validate-provenance job is byte-identical to the trusted base", () => {
  const baseWorkflow = execFileSync(
    "git",
    ["show", `${baseRevision}:.github/workflows/codex-nightly-ci-repair.yml`],
    { cwd: root, encoding: "utf8" },
  );
  assert.equal(
    validateProvenance,
    jobBlock(baseWorkflow, "validate-provenance"),
    "the privileged provenance gate must not drift",
  );
});

test("missing OPENAI_API_KEY fails the repair job instead of producing a notice-only green", () => {
  const secretStep = stepBlock(repairJob, "Check OpenAI API key");
  const script = scriptBlock(secretStep);
  assert.match(secretStep, /OPENAI_API_KEY: \$\{\{ secrets\.OPENAI_API_KEY \}\}/u);
  assert.match(script, /::error::OPENAI_API_KEY missing/u);
  assert.match(script, /configured=false/u);
  assert.match(script, /exit 1/u);
  assert.doesNotMatch(script, /::notice::OPENAI_API_KEY/u);
});

test("unsafe provenance and a skipped repair job fail through the always summariser", () => {
  assert.match(summaryJob, /needs: \[validate-provenance, repair-nightly-ci\]/u);
  assert.match(summaryJob, /^\s+if: always\(\)$/mu);
  assert.match(summaryJob, /PROVENANCE_SAFE: \$\{\{ needs\.validate-provenance\.outputs\.safe \}\}/u);
  assert.match(summaryJob, /VALIDATION_RESULT: \$\{\{ needs\.validate-provenance\.result \}\}/u);
  assert.match(summaryJob, /REPAIR_RESULT: \$\{\{ needs\.repair-nightly-ci\.result \}\}/u);

  const script = scriptBlock(stepBlock(summaryJob, "Fail closed when repair proof is incomplete"));
  assert.match(script, /::error::OPENAI_API_KEY missing/u);
  assert.match(script, /::error::provenance\/skip reason:/u);
  assert.match(script, /PROVENANCE_SAFE.*!= "true"/u);
  assert.match(script, /REPAIR_RESULT.*!= "success"/u);
  assert.match(script, /GITHUB_STEP_SUMMARY/u);
  assert.match(script, /exit 1/u);
});

test("the repair operator remains gated by the unchanged safe=true provenance result", () => {
  assert.match(
    repairJob,
    /needs\.validate-provenance\.outputs\.safe == 'true'/u,
    "repair execution must not be unlocked by the fail-closed summariser",
  );
  assert.match(
    summaryJob,
    /if: always\(\)/u,
    "the summary must run when validate-provenance or repair-nightly-ci skips",
  );
});
