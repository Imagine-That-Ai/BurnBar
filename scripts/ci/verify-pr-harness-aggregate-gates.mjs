#!/usr/bin/env node
/**
 * Static gate for required OpenBurnBar PR harness aggregate jobs.
 *
 * Required collapse jobs must run with always() and inspect the upstream
 * results themselves. If the job-level condition includes !cancelled(), GitHub
 * can report the required aggregate check as skipped during a cancelled
 * upstream harness, which is indistinguishable from a passing required check.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT =
  process.env.PR_HARNESS_AGGREGATE_GATE_ROOT ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WORKFLOW = join(ROOT, ".github", "workflows", "openburnbar-pr-harness.yml");

const REQUIRED_GATES = [
  "platform-confidence-gate",
  "targeted-e2e-gate",
  "harness-required",
  "harness-informational",
  "openburnbar-pr",
];

const failures = [];
const fail = (message) => failures.push(message);

function extractJobs(source) {
  const jobs = new Map();
  const lines = source.split("\n");
  let inJobs = false;
  let currentName = null;
  let currentLines = [];

  for (const line of lines) {
    if (!inJobs) {
      if (line === "jobs:") inJobs = true;
      continue;
    }

    const match = /^  ([A-Za-z0-9_-]+):\s*$/u.exec(line);
    if (match) {
      if (currentName) jobs.set(currentName, currentLines.join("\n"));
      currentName = match[1];
      currentLines = [line];
      continue;
    }

    if (currentName) currentLines.push(line);
  }

  if (currentName) jobs.set(currentName, currentLines.join("\n"));
  return jobs;
}

function normalizeIf(raw) {
  return raw
    .trim()
    .replace(/^\$\{\{\s*/u, "")
    .replace(/\s*\}\}$/u, "")
    .trim();
}

function jobIf(block) {
  const match = /^    if:\s*(.+)$/mu.exec(block);
  return match ? normalizeIf(match[1]) : "";
}

function hasNeeds(block) {
  return /^    needs:\s*$/mu.test(block);
}

function rejectsCancelledNeeds(block) {
  if (!/toJSON\(needs\)/u.test(block)) return false;
  if (/['"]cancelled['"]/u.test(block)) return false;
  return (
    /not in \('success', 'skipped'\)/u.test(block) ||
    /r not in \('success', 'skipped'\)/u.test(block) ||
    /failed\.append\(k \+ ' \(result='/u.test(block)
  );
}

if (!existsSync(WORKFLOW)) {
  fail(`missing workflow: ${WORKFLOW}`);
} else {
  const source = readFileSync(WORKFLOW, "utf8");
  const jobs = extractJobs(source);

  for (const name of REQUIRED_GATES) {
    const block = jobs.get(name);
    if (!block) {
      fail(`missing required aggregate gate job: ${name}`);
      continue;
    }

    const condition = jobIf(block);
    if (!condition) {
      fail(`${name} must have an explicit if: always() condition`);
    } else if (condition !== "always()") {
      fail(`${name} must use if: always(); found: ${condition}`);
    }

    if (/cancelled\(\)/u.test(block)) {
      fail(`${name} must not use cancelled() in the job-level gate condition`);
    }

    if (!hasNeeds(block)) {
      fail(`${name} must depend on upstream jobs through needs`);
    }

    if (!rejectsCancelledNeeds(block)) {
      fail(`${name} must parse toJSON(needs) and reject any non-success/non-skipped upstream result`);
    }
  }
}

if (failures.length > 0) {
  console.error("PR harness aggregate gate verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("PASS: PR harness aggregate gates fail closed for cancelled upstream jobs.");
