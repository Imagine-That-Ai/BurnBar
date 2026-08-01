#!/usr/bin/env node

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = process.env.MERGE_QUEUE_WORKFLOW_ROOT
  ?? join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const requiredWorkflows = [
  "codeql-pr.yml",
  "android-ktlint.yml",
  "code-quality.yml",
  "public-macos-download-trust.yml",
  "public-linux-download-trust.yml",
  "qa.yml",
  "pr-review.yml",
  "droid-review.yml",
  "domain-core-deletion-guard.yml",
  "domain-core.yml",
];

const failures = [];

function jobBlock(source, jobName) {
  const marker = `  ${jobName}:\n`;
  const start = source.indexOf(marker);
  if (start < 0) return null;
  const remainder = source.slice(start + marker.length);
  const nextJob = remainder.search(/^  [a-z0-9_-]+:\s*$/mu);
  return nextJob < 0
    ? source.slice(start)
    : source.slice(start, start + marker.length + nextJob);
}

for (const name of requiredWorkflows) {
  const path = join(root, ".github", "workflows", name);
  if (!existsSync(path)) {
    failures.push(`${name}: workflow is missing`);
    continue;
  }
  const source = readFileSync(path, "utf8");
  if (!/^  merge_group:\s*$/mu.test(source)) {
    failures.push(`${name}: required check does not run for merge_group`);
  }
}

const publicDownloadDetectors = [
  ["public-macos-download-trust.yml", "detect-public-macos-download-change"],
  ["public-linux-download-trust.yml", "detect-public-linux-download-change"],
];

for (const [name, jobName] of publicDownloadDetectors) {
  const source = readFileSync(join(root, ".github", "workflows", name), "utf8");
  const job = jobBlock(source, jobName);
  if (job === null) {
    failures.push(`${name}: ${jobName} job is missing`);
    continue;
  }

  const timeout = job.match(/^    timeout-minutes:\s*(\d+)\s*$/mu);
  if (timeout === null || Number.parseInt(timeout[1], 10) < 60) {
    failures.push(
      `${name}: ${jobName} must budget at least 60 minutes for degraded full-history checkout`,
    );
  }
  if (!/^\s+fetch-depth:\s*0\s*$/mu.test(job)) {
    failures.push(`${name}: ${jobName} must fetch complete history for exact base comparison`);
  }
  if (!/^\s+filter:\s*blob:none\s*$/mu.test(job)) {
    failures.push(`${name}: ${jobName} must use a blobless partial clone`);
  }
  if (!/^\s+persist-credentials:\s*false\s*$/mu.test(job)) {
    failures.push(`${name}: ${jobName} must not persist checkout credentials`);
  }
}

{
  const name = "public-macos-download-trust.yml";
  const source = readFileSync(join(root, ".github", "workflows", name), "utf8");
  const detector = jobBlock(source, "detect-public-macos-download-change");
  const codeGate = jobBlock(source, "verify-public-macos-download-trust-code");
  const signingVerifierPattern =
    "scripts/ci/verify-daemon-release-signing\\.sh";
  const signingTestPattern =
    "scripts/ci/verify-daemon-release-signing\\.test\\.sh";

  if (detector === null) {
    failures.push(`${name}: detect-public-macos-download-change job is missing`);
  } else {
    for (const dependency of [signingVerifierPattern, signingTestPattern]) {
      const occurrences = detector.split(dependency).length - 1;
      if (occurrences < 2) {
        failures.push(
          `${name}: both PR and push detection must treat ${dependency} as trusted-gate code`,
        );
      }
    }
  }

  if (codeGate === null) {
    failures.push(`${name}: verify-public-macos-download-trust-code job is missing`);
  } else if (
    !codeGate.includes("bash scripts/ci/verify-daemon-release-signing.test.sh")
  ) {
    failures.push(
      `${name}: trust-gate code job must execute the daemon signing regression suite`,
    );
  }
}

{
  const name = "domain-core.yml";
  const source = readFileSync(join(root, ".github", "workflows", name), "utf8");
  const job = jobBlock(source, "domain-core-pr-gate");
  if (job === null) {
    failures.push(`${name}: domain-core-pr-gate job is missing`);
  } else {
    const timeout = job.match(/^    timeout-minutes:\s*(\d+)\s*$/mu);
    if (timeout === null || Number.parseInt(timeout[1], 10) < 60) {
      failures.push(
        `${name}: domain-core-pr-gate must budget at least 60 minutes for degraded full-history checkout`,
      );
    }
    if (!/^\s+fetch-depth:\s*0\s*$/mu.test(job)) {
      failures.push(
        `${name}: domain-core-pr-gate must fetch the complete deletion candidate for ancestry proofs`,
      );
    }
    if (/^\s+filter:/mu.test(job)) {
      failures.push(
        `${name}: domain-core-pr-gate clones must keep blobs for historical-content evidence reads`,
      );
    }
    if (!/^\s+fetch-depth:\s*1\s*$/mu.test(job)) {
      failures.push(
        `${name}: domain-core-pr-gate trusted evaluator checkout must stay bounded at depth 1`,
      );
    }
    for (const script of [
      "scripts/ci/verify-domain-core-legacy-absence.py",
      "scripts/ci/verify-domain-core-legacy-deletion.py",
    ]) {
      if (!job.includes(`            ${script}\n`)) {
        failures.push(
          `${name}: domain-core-pr-gate trusted evaluator sparse checkout must include ${script}`,
        );
      }
    }
    const credentialOptOuts = job.match(/^\s+persist-credentials:\s*false\s*$/gmu) ?? [];
    if (credentialOptOuts.length < 2) {
      failures.push(
        `${name}: both domain-core-pr-gate checkouts must not persist credentials`,
      );
    }
  }

  const contracts = jobBlock(source, "promotion-contracts");
  if (contracts === null) {
    failures.push(`${name}: promotion-contracts job is missing`);
  } else {
    const timeout = contracts.match(/^    timeout-minutes:\s*(\d+)\s*$/mu);
    if (timeout === null || Number.parseInt(timeout[1], 10) < 60) {
      failures.push(
        `${name}: promotion-contracts must budget at least 60 minutes for degraded full-history checkout`,
      );
    }
    if (!/^\s+fetch-depth:\s*0\s*$/mu.test(contracts)) {
      failures.push(
        `${name}: promotion-contracts must fetch the complete deletion candidate for ancestry proofs`,
      );
    }
    if (/^\s+filter:/mu.test(contracts)) {
      failures.push(
        `${name}: promotion-contracts clones must keep blobs for historical-content evidence reads`,
      );
    }
    if (!/^\s+fetch-depth:\s*1\s*$/mu.test(contracts)) {
      failures.push(
        `${name}: promotion-contracts trusted evaluator checkout must stay bounded at depth 1`,
      );
    }
    if (
      !/^\s+sparse-checkout:\s*scripts\/ci\/verify-domain-core-legacy-deletion\.py\s*$/mu.test(
        contracts,
      )
    ) {
      failures.push(
        `${name}: promotion-contracts trusted evaluator sparse checkout must include scripts/ci/verify-domain-core-legacy-deletion.py`,
      );
    }
    const credentialOptOuts =
      contracts.match(/^\s+persist-credentials:\s*false\s*$/gmu) ?? [];
    if (credentialOptOuts.length < 2) {
      failures.push(
        `${name}: both promotion-contracts checkouts must not persist credentials`,
      );
    }
  }
}

const governancePath = join(root, "governance", "branch-protection.main.json");
if (!existsSync(governancePath)) {
  failures.push("governance/branch-protection.main.json: source of truth is missing");
} else {
  let governance;
  try {
    governance = JSON.parse(readFileSync(governancePath, "utf8"));
  } catch (error) {
    failures.push(
      `governance/branch-protection.main.json: invalid JSON (${error.message})`,
    );
  }

  const queueTimeout = governance?.merge_queue?.check_response_timeout_minutes;
  if (!Number.isInteger(queueTimeout) || queueTimeout <= 0) {
    failures.push(
      "governance/branch-protection.main.json: merge queue timeout must be a positive integer",
    );
  } else {
    const workflowDir = join(root, ".github", "workflows");
    const mergeGroupTimeouts = [];
    for (const name of readdirSync(workflowDir)) {
      if (!/\.ya?ml$/u.test(name)) continue;
      const source = readFileSync(join(workflowDir, name), "utf8");
      if (!/^  merge_group:\s*$/mu.test(source)) continue;
      for (const match of source.matchAll(
        /^\s*timeout-minutes:\s*(\d+)\s*$/gmu,
      )) {
        mergeGroupTimeouts.push({ name, minutes: Number(match[1]) });
      }
    }
    const longest = mergeGroupTimeouts.reduce(
      (current, candidate) =>
        candidate.minutes > current.minutes ? candidate : current,
      { name: "<none>", minutes: 0 },
    );
    if (queueTimeout <= longest.minutes) {
      failures.push(
        `merge queue timeout ${queueTimeout}m must exceed longest merge_group workflow timeout ${longest.minutes}m (${longest.name})`,
      );
    }
  }
}

const contracts = [
  [
    "domain-core-deletion-guard.yml",
    "github.event.pull_request.head.sha || github.event.merge_group.head_sha",
    "trusted deletion guard must evaluate the merge-group candidate SHA",
    1,
  ],
  [
    "domain-core-deletion-guard.yml",
    "gh-readonly-queue/main/pr-([0-9]+)-",
    "trusted deletion guard must recover the single queued PR identity",
    1,
  ],
  [
    "pr-review.yml",
    "github.event.pull_request.base.sha || github.event.merge_group.base_sha",
    "automated review must compare the merge group against its base",
    1,
  ],
  [
    "public-macos-download-trust.yml",
    "github.event.pull_request.base.sha || github.event.merge_group.base_sha",
    "public download trust detection and trusted checkout must both compare the merge group against its base",
    2,
  ],
  [
    "public-linux-download-trust.yml",
    "github.event.pull_request.base.sha || github.event.merge_group.base_sha",
    "public Linux download trust detection must compare the merge group against its base",
  ],
  [
    "droid-review.yml",
    "Reuse PR-head Droid review for merge queue",
    "Droid's advisory check must emit a merge-group receipt without invoking PR-only APIs",
    1,
  ],
];

for (const [name, needle, message, minimumOccurrences] of contracts) {
  const source = readFileSync(join(root, ".github", "workflows", name), "utf8");
  const occurrences = source.split(needle).length - 1;
  if (occurrences < minimumOccurrences) {
    failures.push(`${name}: ${message} (expected at least ${minimumOccurrences}, found ${occurrences})`);
  }
}

if (failures.length > 0) {
  console.error("Merge queue workflow verification failed:");
  failures.forEach((failure) => console.error(`  - ${failure}`));
  process.exit(1);
}

console.log(`PASS: ${requiredWorkflows.length} required-check workflows support merge_group safely.`);
