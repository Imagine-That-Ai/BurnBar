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
  "droid-review.yml", "domain-core-deletion-guard.yml", "domain-core.yml", "app-pr-gate.yml",
];

function fixture(edit = () => {}) {
  const root = mkdtempSync(join(tmpdir(), "merge-queue-workflows-"));
  mkdirSync(join(root, ".github", "workflows"), { recursive: true });
  mkdirSync(join(root, "governance"), { recursive: true });
  for (const name of workflows) {
    copyFileSync(
      join(repoRoot, ".github", "workflows", name),
      join(root, ".github", "workflows", name),
    );
  }
  copyFileSync(
    join(repoRoot, "governance", "branch-protection.main.json"),
    join(root, "governance", "branch-protection.main.json"),
  );
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

function mutateGovernance(root, edit) {
  const path = join(root, "governance", "branch-protection.main.json");
  const governance = JSON.parse(readFileSync(path, "utf8"));
  edit(governance);
  writeFileSync(path, `${JSON.stringify(governance, null, 2)}\n`);
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
  ["macOS detector checkout timeout regresses", (root) => mutate(root, "public-macos-download-trust.yml", "timeout-minutes: 60", "timeout-minutes: 15"), 1],
  ["Linux detector clone downloads blobs", (root) => mutate(root, "public-linux-download-trust.yml", "filter: blob:none", "filter: blob:limit=1"), 1],
  ["Linux detector persists credentials", (root) => mutate(root, "public-linux-download-trust.yml", "persist-credentials: false", "persist-credentials: true"), 1],
  ["Domain Core gate checkout timeout regresses", (root) => mutate(root, "domain-core.yml", "fail-closed gate.\n    timeout-minutes: 60", "fail-closed gate.\n    timeout-minutes: 15"), 1],
  ["Domain Core gate evaluator fetches full history", (root) => mutate(root, "domain-core.yml", "fetch-depth: 1\n          sparse-checkout: |", "fetch-depth: 0\n          sparse-checkout: |"), 1],
  ["Domain Core gate candidate clone drops blobs", (root) => mutate(root, "domain-core.yml", "Check out deletion candidate\n        if: needs.classify.outputs.rust == 'true'\n        uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd # v5.0.1\n        with:\n          persist-credentials: false\n          fetch-depth: 0\n", "Check out deletion candidate\n        if: needs.classify.outputs.rust == 'true'\n        uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd # v5.0.1\n        with:\n          persist-credentials: false\n          fetch-depth: 0\n          filter: blob:none\n"), 1],
  ["Domain Core gate sparse checkout drops the absence evaluator", (root) => mutate(root, "domain-core.yml", "            scripts/ci/verify-domain-core-legacy-absence.py\n", ""), 1],
  ["promotion-contracts checkout timeout regresses", (root) => mutate(root, "domain-core.yml", "fail-closed contract lane.\n    timeout-minutes: 60", "fail-closed contract lane.\n    timeout-minutes: 15"), 1],
  ["promotion-contracts candidate clone drops blobs", (root) => mutate(root, "domain-core.yml", "persist-credentials: false\n          fetch-depth: 0\n          ref: ${{ github.event.pull_request.head.sha || github.sha }}\n", "persist-credentials: false\n          fetch-depth: 0\n          filter: blob:none\n          ref: ${{ github.event.pull_request.head.sha || github.sha }}\n"), 1],
  ["promotion-contracts evaluator fetches full history", (root) => mutate(root, "domain-core.yml", "fetch-depth: 1\n          sparse-checkout: scripts/ci/verify-domain-core-legacy-deletion.py", "fetch-depth: 0\n          sparse-checkout: scripts/ci/verify-domain-core-legacy-deletion.py"), 1],
  ["queue timeout shorter than workflow", (root) => mutateGovernance(root, (governance) => {
    governance.merge_queue.check_response_timeout_minutes = 240;
  }), 1],
  ["workflow outgrows queue timeout", (root) => mutate(root, "app-pr-gate.yml", "timeout-minutes: 240", "timeout-minutes: 301"), 1],
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
