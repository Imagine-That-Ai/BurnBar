#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(scriptDir, "..", "..");
const gate = join(scriptDir, "verify-merge-queue-workflows.mjs");
const workflows = [
  "codeql-pr.yml", "android-ktlint.yml", "code-quality.yml",
  "public-macos-download-trust.yml", "public-linux-download-trust.yml", "qa.yml", "pr-review.yml",
  "droid-review.yml", "domain-core-deletion-guard.yml",
];

function fixture(edit = () => {}) {
  const root = mkdtempSync(join(tmpdir(), "merge-queue-workflows-"));
  mkdirSync(join(root, ".github", "workflows"), { recursive: true });
  for (const name of workflows) {
    copyFileSync(
      join(repoRoot, ".github", "workflows", name),
      join(root, ".github", "workflows", name),
    );
  }
  edit(root);
  return root;
}

function mutate(root, name, from, to) {
  const path = join(root, ".github", "workflows", name);
  const source = readFileSync(path, "utf8");
  const updated = source.replace(from, to);
  if (updated === source) throw new Error(`mutation did not change ${name}`);
  writeFileSync(path, updated);
}

function result(root) {
  try {
    execFileSync("node", [gate], {
      env: { ...process.env, MERGE_QUEUE_WORKFLOW_ROOT: root },
      stdio: "pipe",
    });
    return 0;
  } catch (error) {
    return error.status ?? 1;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const cases = [
  ["current workflows", () => {}, 0],
  ["missing merge_group", (root) => mutate(root, "codeql-pr.yml", "  merge_group:\n", "  disabled_merge_group:\n"), 1],
  ["missing queue PR identity", (root) => mutate(root, "domain-core-deletion-guard.yml", "gh-readonly-queue/main/pr-([0-9]+)-", "queue/main/change-([0-9]+)-"), 1],
  ["missing merge base", (root) => mutate(root, "public-macos-download-trust.yml", "github.event.pull_request.base.sha || github.event.merge_group.base_sha", "github.event.pull_request.base.sha"), 1],
];

let failures = 0;
for (const [name, edit, expected] of cases) {
  const actual = result(fixture(edit));
  if (actual === expected) console.log(`✓ ${name}`);
  else {
    console.error(`✗ ${name}: expected ${expected}, got ${actual}`);
    failures += 1;
  }
}
if (failures > 0) process.exit(1);
console.log(`PASS: ${cases.length} merge queue workflow cases.`);
