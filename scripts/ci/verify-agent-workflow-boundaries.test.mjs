#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-agent-workflow-boundaries.mjs.
 *
 * Run:  node scripts/ci/verify-agent-workflow-boundaries.test.mjs
 * Exit: 0 = all self-test cases passed; 1 = the oracle misbehaved.
 */

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const GATE = join(SCRIPT_DIR, "verify-agent-workflow-boundaries.mjs");
const roots = [];
process.on("exit", () =>
  roots.forEach((dir) => rmSync(dir, { recursive: true, force: true })),
);

const fixture = (strings, ...values) =>
  String.raw({ raw: strings.raw }, ...values).replaceAll("\\${", "${");

const REMEDIATED_DROID = fixture`
name: Droid Tag
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  pull_request_review:
    types: [submitted]
  pull_request:
    types: [opened, edited]
jobs:
  droid:
    if: |
      (
        github.event_name == 'issue_comment' &&
        github.event.issue.pull_request == null
      ) ||
      (
        github.event_name == 'pull_request_review_comment' &&
        github.event.pull_request.head.repo.full_name == github.repository
      ) ||
      (
        github.event_name == 'pull_request_review' &&
        github.event.pull_request.head.repo.full_name == github.repository
      ) ||
      (
        github.event_name == 'pull_request' &&
        github.event.pull_request.head.repo.full_name == github.repository
      )
    env:
      FACTORY_API_KEY_AVAILABLE: \${{ secrets.FACTORY_API_KEY != '' }}
    permissions:
      contents: read
      pull-requests: write
      issues: write
    steps:
      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd
        with:
          persist-credentials: false
      - name: Skip
        if: env.FACTORY_API_KEY_AVAILABLE == 'false'
        run: echo skip
      - name: Run Droid Exec
        if: env.FACTORY_API_KEY_AVAILABLE == 'true'
        uses: Factory-AI/droid-action@7c7bfea2aa3bb7ea87579402cc1d89dbcf6b13b3
        with:
          factory_api_key: \${{ secrets.FACTORY_API_KEY }}
`;

const LEGACY_DROID = fixture`
name: Droid Tag
on:
  issue_comment:
    types: [created]
jobs:
  droid:
    env:
      FACTORY_API_KEY: \${{ secrets.FACTORY_API_KEY }}
    permissions:
      contents: write
      pull-requests: write
      issues: write
      id-token: write
    steps:
      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd
      - uses: Factory-AI/droid-action@7c7bfea2aa3bb7ea87579402cc1d89dbcf6b13b3
        with:
          factory_api_key: \${{ env.FACTORY_API_KEY }}
`;

const REMEDIATED_DROID_CLI = fixture`
name: Droid Wiki Refresh
permissions:
  contents: read
on:
  push:
    branches: [main]
jobs:
  wiki-refresh:
    steps:
      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd
        with:
          persist-credentials: false
      - name: Generate Wiki
        env:
          FACTORY_API_KEY: \${{ secrets.FACTORY_API_KEY }}
        run: |
          set -euo pipefail
          if [[ -z "\${FACTORY_API_KEY}" ]]; then
            echo "::error::FACTORY_API_KEY is unavailable"
            exit 1
          fi
          droid exec --auto medium "/wiki"
`;

const LEGACY_DROID_CLI = fixture`
name: Droid Wiki Refresh
permissions:
  contents: read
on:
  push:
    branches: [main]
jobs:
  wiki-refresh:
    steps:
      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd
      - name: Generate Wiki
        env:
          FACTORY_API_KEY: \${{ secrets.FACTORY_API_KEY }}
        run: droid exec --auto medium "/wiki"
`;

function buildTree(files) {
  const root = mkdtempSync(join(tmpdir(), "agent-workflow-boundary-"));
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
      env: { ...process.env, AGENT_WORKFLOW_BOUNDARY_ROOT: root },
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

console.log("Self-test: verify-agent-workflow-boundaries.mjs\n");

expect("remediated Droid workflow passes", { "droid.yml": REMEDIATED_DROID }, 0);

expect("remediated Droid CLI workflow passes", { "droid-wiki-refresh.yml": REMEDIATED_DROID_CLI }, 0);

expect("legacy job-wide secret, write token, OIDC, and checkout credential pattern fails", { "droid.yml": LEGACY_DROID }, 1);

expect("legacy Droid CLI workflow without key preflight or checkout isolation fails", { "droid-wiki-refresh.yml": LEGACY_DROID_CLI }, 1);

expect(
  "missing same-repository PR guard fails",
  {
    "droid.yml": REMEDIATED_DROID.replaceAll(
      "github.event.pull_request.head.repo.full_name == github.repository",
      "contains(github.event.comment.body, '@droid')",
    ),
  },
  1,
);

expect(
  "missing non-PR issue comment guard fails",
  {
    "droid.yml": REMEDIATED_DROID.replace("github.event.issue.pull_request == null", "true"),
  },
  1,
);

expect(
  "missing checkout credential isolation fails",
  {
    "droid.yml": REMEDIATED_DROID.replace("          persist-credentials: false\n", ""),
  },
  1,
);

expect(
  "job-wide Factory secret regression fails",
  {
    "droid.yml": REMEDIATED_DROID.replace(
      "      FACTORY_API_KEY_AVAILABLE: ${{ secrets.FACTORY_API_KEY != '' }}",
      "      FACTORY_API_KEY: ${{ secrets.FACTORY_API_KEY }}",
    ),
  },
  1,
);

expect(
  "write-token regression fails",
  {
    "droid.yml": REMEDIATED_DROID.replace("      contents: read", "      contents: write"),
  },
  1,
);

console.log(
  `\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`,
);
process.exit(failed === 0 ? 0 : 1);
