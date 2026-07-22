#!/usr/bin/env node

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = process.env.MERGE_QUEUE_WORKFLOW_ROOT
  ?? join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const requiredWorkflows = [
  "codeql-pr.yml",
  "android-ktlint.yml",
  "code-quality.yml",
  "public-macos-download-trust.yml",
  "qa.yml",
  "pr-review.yml",
  "droid-review.yml",
  "domain-core-deletion-guard.yml",
];

const failures = [];
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

const contracts = [
  [
    "domain-core-deletion-guard.yml",
    "github.event.pull_request.head.sha || github.event.merge_group.head_sha",
    "trusted deletion guard must evaluate the merge-group candidate SHA",
  ],
  [
    "domain-core-deletion-guard.yml",
    "gh-readonly-queue/main/pr-([0-9]+)-",
    "trusted deletion guard must recover the single queued PR identity",
  ],
  [
    "pr-review.yml",
    "github.event.pull_request.base.sha || github.event.merge_group.base_sha",
    "automated review must compare the merge group against its base",
  ],
  [
    "public-macos-download-trust.yml",
    "github.event.pull_request.base.sha || github.event.merge_group.base_sha",
    "public download trust detection must compare the merge group against its base",
  ],
  [
    "droid-review.yml",
    "Reuse PR-head Droid review for merge queue",
    "Droid's advisory check must emit a merge-group receipt without invoking PR-only APIs",
  ],
];

for (const [name, needle, message] of contracts) {
  const source = readFileSync(join(root, ".github", "workflows", name), "utf8");
  if (!source.includes(needle)) failures.push(`${name}: ${message}`);
}

if (failures.length > 0) {
  console.error("Merge queue workflow verification failed:");
  failures.forEach((failure) => console.error(`  - ${failure}`));
  process.exit(1);
}

console.log(`PASS: ${requiredWorkflows.length} required-check workflows support merge_group safely.`);
