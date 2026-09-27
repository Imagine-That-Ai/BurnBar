#!/usr/bin/env node
/**
 * Fail-closed gate: CI runs only on free GitHub-hosted runners.
 *
 * Public repositories get unlimited free GitHub-hosted runner minutes, so no
 * workflow may route jobs to self-hosted hardware, the retired burnbar-turbo
 * ephemeral fleet, the retired burnbar-ci-paid group, or the retired
 * MACOS_GATE_POOL toggle. The two linux-product-parity jobs that require
 * physical hardware (paired-iPad producer, distro install validation) are the
 * deliberate exception: they stay self-hosted but only run with explicit
 * `confirm_local_runners` consent, and this gate pins both the allowlist and
 * the consent input so neither can drift silently.
 *
 * Usage:  node scripts/ci/verify-github-hosted-runners-only.mjs
 * Exit:   0 = all workflows GitHub-hosted (or consent-gated exception);
 *         1 = violation; 2 = repository/workflow directory misconfigured.
 */

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = process.env.GITHUB_RUNNERS_ONLY_ROOT
  ? process.env.GITHUB_RUNNERS_ONLY_ROOT
  : join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WORKFLOW_DIR = join(REPO_ROOT, ".github", "workflows");

// file -> job ids allowed to name self-hosted labels. Both jobs are manual,
// consent-gated (see confirm_local_runners), and cannot run on GitHub
// hardware: one needs a paired physical iPad, the other installs signed
// candidate packages per distro.
export const ALLOWED_SELF_HOSTED = {
  "linux-product-parity.yml": new Set(["p16-ipad-producer", "validate"]),
};
export const CONSENT_INPUT = "confirm_local_runners";
export const RETIRED_DISPATCHER = "burnbar-turbo.yml";

// Bare `burnbar-swift` also matches test-openburnbar-swift.sh paths, so the
// fleet label only counts quoted or list-shaped (the shapes runs-on uses).
const RETIRED_LABELS = [
  /["']burnbar-turbo-ephemeral["']/u,
  /["']burnbar-ci-paid["']/u,
  /["']burnbar-swift["']/u,
  /-\s*burnbar-swift\b/u,
  /group["']?\s*:\s*["']?burnbar-turbo-ephemeral/u,
  /group["']?\s*:\s*["']?burnbar-ci-paid/u,
];
const POOL_TOGGLE = "MACOS_GATE_POOL";

function stripLineComment(line) {
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
    if (char === "#" && !singleQuoted && !doubleQuoted) {
      return line.slice(0, index);
    }
  }
  return line;
}

function trackJob(line, state) {
  if (/^jobs:\s*(#.*)?$/u.test(line)) {
    state.inJobs = true;
    state.job = null;
    return;
  }
  if (/^[A-Za-z][A-Za-z0-9_-]*:/u.test(line)) {
    state.inJobs = false;
    state.job = null;
    return;
  }
  if (state.inJobs) {
    const match = /^  ([A-Za-z0-9_.-]+):\s*(#.*)?$/u.exec(line);
    if (match) {
      state.job = match[1];
    }
  }
}

export function scanWorkflowText(file, text) {
  const failures = [];
  const state = { inJobs: false, job: null };
  const allowlist = ALLOWED_SELF_HOSTED[file] ?? new Set();
  const seenConsentByJob = new Map();
  const lines = text.split("\n");
  // Only runs-on lines (and their `- item` continuations) can route a job,
  // so label checks stay scoped there; prose and --deny-self-hosted-runners
  // script flags elsewhere must not trip the gate.
  let listIndent = null;
  lines.forEach((raw, index) => {
    const lineNo = index + 1;
    trackJob(raw, state);
    const code = stripLineComment(raw);
    if (code.includes(POOL_TOGGLE)) {
      failures.push(`${file}:${lineNo}: retired ${POOL_TOGGLE} toggle referenced`);
    }
    const runsOn = /^(\s*)runs-on:(.*)$/u.exec(code);
    let inRunsOn = false;
    if (runsOn) {
      listIndent = runsOn[2].trim() === "" ? runsOn[1].length : null;
      inRunsOn = true;
    } else if (listIndent !== null) {
      if (/^\s*$/u.test(code)) {
        inRunsOn = true;
      } else {
        const indent = /^(\s*)/u.exec(code)[1].length;
        // Bare runs-on continues through deeper-indented lines, whether list
        // items (`- self-hosted`) or mappings (`group: <name>`).
        if (indent > listIndent) {
          inRunsOn = true;
        } else {
          listIndent = null;
        }
      }
    }
    if (state.job && code.includes(CONSENT_INPUT)) {
      seenConsentByJob.set(state.job, true);
    }
    if (!inRunsOn) {
      return;
    }
    for (const pattern of RETIRED_LABELS) {
      if (pattern.test(code)) {
        failures.push(
          `${file}:${lineNo}: retired local/paid runner label ${pattern.source}`,
        );
        break;
      }
    }
    if (/self-hosted/u.test(code)) {
      if (allowlist.has(state.job)) {
        return;
      }
      const where = state.job ? `job ${state.job}` : "outside any job";
      failures.push(`${file}:${lineNo}: self-hosted label in ${where}`);
    }
  });
  // The exception jobs must keep their consent gate: each allowlisted job
  // present in the file must reference the consent input, and the input must
  // exist with default false.
  if (allowlist.size > 0) {
    const jobNames = new Set();
    const probe = { inJobs: false, job: null };
    for (const raw of lines) {
      trackJob(raw, probe);
      if (probe.job) {
        jobNames.add(probe.job);
      }
    }
    for (const job of allowlist) {
      if (!jobNames.has(job)) {
        failures.push(`${file}: allowlisted job ${job} missing (stale allowlist?)`);
      } else if (!seenConsentByJob.get(job)) {
        failures.push(`${file}: allowlisted job ${job} lost its ${CONSENT_INPUT} gate`);
      }
    }
    if (!new RegExp(`${CONSENT_INPUT}:\\s*(#.*)?$`, "um").test(text)) {
      failures.push(`${file}: missing ${CONSENT_INPUT} input definition`);
    }
    const consentDefaultOff = new RegExp(
      `${CONSENT_INPUT}:[\\s\\S]{0,500}?default:\\s*false\\b`,
      "u",
    ).test(text);
    if (!consentDefaultOff) {
      failures.push(`${file}: ${CONSENT_INPUT} must default to false`);
    }
  }
  return failures;
}

function workflowFiles() {
  if (!existsSync(WORKFLOW_DIR)) {
    console.error(`MISCONFIGURED: workflow directory not found: ${WORKFLOW_DIR}`);
    process.exit(2);
  }
  return readdirSync(WORKFLOW_DIR)
    .filter((name) => /\.ya?ml$/u.test(name))
    .sort();
}

const failures = [];
if (existsSync(join(WORKFLOW_DIR, RETIRED_DISPATCHER))) {
  failures.push(
    `${RETIRED_DISPATCHER}: retired local-fleet dispatcher must stay deleted`,
  );
}
for (const file of workflowFiles()) {
  const text = readFileSync(join(WORKFLOW_DIR, file), "utf8");
  failures.push(...scanWorkflowText(file, text));
}
if (failures.length > 0) {
  for (const failure of failures) {
    console.error(`VIOLATION: ${failure}`);
  }
  process.exit(1);
}
console.log("github-hosted runners only: OK");
