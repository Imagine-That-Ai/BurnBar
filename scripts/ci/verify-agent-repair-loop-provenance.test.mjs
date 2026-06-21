#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-agent-repair-loop-provenance.mjs.
 *
 * Builds throwaway workflow fixtures and proves the oracle accepts the
 * remediated repair-loop structure while rejecting the legacy unsafe class:
 * marker/title-body authority, number-only workflow_run continuation,
 * gh-pr-checkout, stale head SHA, job-wide secrets, and missing
 * persist-credentials:false.
 *
 * Run:  node scripts/ci/verify-agent-repair-loop-provenance.test.mjs
 * Exit: 0 = all self-test cases passed; 1 = the oracle misbehaved.
 */

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const GATE = join(SCRIPT_DIR, "verify-agent-repair-loop-provenance.mjs");
const roots = [];
process.on("exit", () =>
  roots.forEach((dir) => rmSync(dir, { recursive: true, force: true })),
);

const fixture = (strings, ...values) =>
  String.raw({ raw: strings.raw }, ...values).replaceAll("\\${", "${");

const REMEDIATED_CODEX = fixture`
name: Codex Nightly CI Repair
on:
  workflow_run:
    workflows: [Workflow Lint]
    types: [completed]
permissions:
  contents: read
concurrency:
  group: codex-nightly-ci-repair-singleton
env:
  GH_REPO: \${{ github.repository }}
  REPAIR_BRANCH: codex/nightly-ci-repair
  TRUSTED_AUTHOR: github-actions[bot]
jobs:
  validate-provenance:
    permissions:
      actions: read
      checks: read
      contents: read
      pull-requests: read
    outputs:
      safe: \${{ steps.trigger.outputs.safe }}
    steps:
      - name: Locate trusted repair PR
        env:
          GH_TOKEN: \${{ github.token }}
        run: |
          gh pr list --base main --head "\${GH_OWNER}:\${REPAIR_BRANCH}" --json baseRefName,headRefName,headRefOid,isCrossRepository,headRepositoryOwner,headRepository,author,state
          jq '.headRepositoryOwner.login and .headRepository.name and .author.login == env.TRUSTED_AUTHOR' file
      - name: Classify repair trigger
        id: trigger
        run: |
          jq '.workflow_run.head_repository.full_name and .workflow_run.head_branch and .workflow_run.head_sha and .workflow_run.pull_requests' "$GITHUB_EVENT_PATH"
  repair-nightly-ci:
    needs: validate-provenance
    if: needs.validate-provenance.outputs.safe == 'true' && github.event.workflow_run.head_sha == needs.validate-provenance.outputs.head_sha
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd
        with:
          persist-credentials: false
      - name: Prepare repair branch
        run: |
          git -c http.https://github.com/.extraheader=x fetch origin "+refs/heads/\${ref}:refs/remotes/origin/\${ref}"
          git_fetch_ref "$REPAIR_BRANCH"
          if [[ "$actual_head" != "$VALIDATED_HEAD_SHA" ]]; then exit 1; fi
      - name: Run Codex
        uses: openai/codex-action@a26d2d4d8b78a694338b8e3715c3630254340b2c
        with:
          openai-api-key: \${{ secrets.OPENAI_API_KEY }}
      - name: Publish
        run: |
          echo REDACTED_TOKEN
          echo REDACTED_SECRET
          echo "marker above is display-only"
`;

const REMEDIATED_CURSOR = fixture`
name: Cursor Nightly CI Repair
on:
  workflow_run:
    workflows: [Workflow Lint]
    types: [completed]
permissions:
  contents: read
concurrency:
  group: cursor-nightly-ci-repair-singleton
env:
  GH_REPO: \${{ github.repository }}
  REPAIR_BRANCH: cursor/nightly-ci-repair
  TRUSTED_AUTHOR: cursor[bot]
jobs:
  validate-provenance:
    permissions:
      actions: read
      checks: read
      contents: read
      pull-requests: read
    outputs:
      safe: \${{ steps.trigger.outputs.safe }}
    steps:
      - name: Locate trusted repair PR
        env:
          GH_TOKEN: \${{ github.token }}
        run: |
          gh pr list --base main --head "\${GH_OWNER}:\${REPAIR_BRANCH}" --json baseRefName,headRefName,headRefOid,isCrossRepository,headRepositoryOwner,headRepository,author,state
          jq '.headRepositoryOwner.login and .headRepository.name and .author.login == env.TRUSTED_AUTHOR' file
      - name: Classify repair trigger
        id: trigger
        run: |
          jq '.workflow_run.head_repository.full_name and .workflow_run.head_branch and .workflow_run.head_sha and .workflow_run.pull_requests' "$GITHUB_EVENT_PATH"
  repair-nightly-ci:
    needs: validate-provenance
    if: needs.validate-provenance.outputs.safe == 'true' && github.event.workflow_run.head_sha == needs.validate-provenance.outputs.head_sha
    steps:
      - name: Create Cursor cloud repair agent
        env:
          CURSOR_API_KEY: \${{ secrets.CURSOR_API_KEY }}
          REPAIR_PR_URL: \${{ needs.validate-provenance.outputs.pr_url }}
        run: |
          echo "Refusing to send prUrl without a validated Cursor repair PR"
          jq -n '{ repos: [{ prUrl: env.REPAIR_PR_URL }] }'
          curl https://api.cursor.com/v1/agents
`;

const SUPPLY_CHAIN_ALLOWLIST = fixture`
name: Supply chain provenance
on:
  workflow_run:
    workflows: ["OpenBurnBar Release"]
    types: [completed]
permissions:
  contents: read
  id-token: write
jobs:
  attest-release:
    if: github.event.workflow_run.conclusion == 'success' && startsWith(github.event.workflow_run.head_branch, 'v')
    steps:
      - run: echo "\${{ secrets.GITHUB_TOKEN }}"
`;

const VULNERABLE_LEGACY_PATTERN = fixture`
name: Codex Nightly CI Repair
on:
  workflow_run:
    workflows: [Workflow Lint]
permissions:
  contents: write
  pull-requests: write
concurrency:
  group: codex-nightly-ci-repair-\${{ github.event.workflow_run.head_branch || github.ref_name || github.run_id }}
jobs:
  repair-nightly-ci:
    env:
      GH_TOKEN: \${{ github.token }}
      OPENAI_API_KEY: \${{ secrets.OPENAI_API_KEY }}
    steps:
      - name: Locate open Codex repair PR
        run: gh pr list --search "\"codex-nightly-ci-repair\" in:title,body" --json number,url
      - name: Classify repair trigger
        run: jq '.workflow_run.pull_requests[]?.number == 123' "$GITHUB_EVENT_PATH"
      - name: Prepare repair branch
        run: gh pr checkout 123 --repo "$GH_REPO"
`;

function buildTree(files) {
  const root = mkdtempSync(join(tmpdir(), "repair-provenance-"));
  roots.push(root);
  const workflowDir = join(root, ".github", "workflows");
  mkdirSync(workflowDir, { recursive: true });
  for (const [name, content] of Object.entries(files)) {
    writeFileSync(join(workflowDir, name), content);
  }
  return root;
}

function runGate(root) {
  try {
    execFileSync("node", [GATE], {
      env: { ...process.env, AGENT_REPAIR_PROVENANCE_ROOT: root },
      stdio: "pipe",
    });
    return 0;
  } catch (err) {
    return err.status ?? 1;
  }
}

let passed = 0;
let failed = 0;
function expect(label, files, wantExit) {
  const got = runGate(buildTree(files));
  if (got === wantExit) {
    console.log(`  ✓ ${label} (exit ${got})`);
    passed += 1;
  } else {
    console.error(`  ✗ ${label}: expected exit ${wantExit}, got ${got}`);
    failed += 1;
  }
}

console.log("Self-test: verify-agent-repair-loop-provenance.mjs\n");

expect(
  "remediated Codex, Cursor, and allowlisted supply-chain pass",
  {
    "codex-nightly-ci-repair.yml": REMEDIATED_CODEX,
    "cursor-nightly-ci-repair.yml": REMEDIATED_CURSOR,
    "supply-chain-provenance.yml": SUPPLY_CHAIN_ALLOWLIST,
  },
  0,
);

expect(
  "current marker/number/checkout/job-secret pattern fails",
  { "codex-nightly-ci-repair.yml": VULNERABLE_LEGACY_PATTERN },
  1,
);

expect(
  "stale SHA binding omission fails",
  {
    "codex-nightly-ci-repair.yml": REMEDIATED_CODEX.replaceAll(
      ".workflow_run.head_sha",
      ".workflow_run.id",
    ),
  },
  1,
);

expect(
  "gh pr checkout regression fails",
  {
    "codex-nightly-ci-repair.yml":
      REMEDIATED_CODEX + "\n# regression\nrun: gh pr checkout 99\n",
  },
  1,
);

expect(
  "job-wide secret regression fails",
  {
    "codex-nightly-ci-repair.yml": REMEDIATED_CODEX.replace(
      "  repair-nightly-ci:\n    needs:",
      "  repair-nightly-ci:\n    env:\n      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}\n    needs:",
    ),
  },
  1,
);

expect(
  "missing persist-credentials:false fails",
  {
    "codex-nightly-ci-repair.yml": REMEDIATED_CODEX.replace(
      "          persist-credentials: false\n",
      "",
    ),
  },
  1,
);

expect(
  "Cursor prUrl without validated fail-closed guard fails",
  {
    "cursor-nightly-ci-repair.yml": REMEDIATED_CURSOR.replace(
      '          echo "Refusing to send prUrl without a validated Cursor repair PR"\n',
      "",
    ),
  },
  1,
);

console.log(
  `\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`,
);
process.exit(failed === 0 ? 0 : 1);
