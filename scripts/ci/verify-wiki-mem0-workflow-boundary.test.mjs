#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-wiki-mem0-workflow-boundary.mjs.
 */

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const GATE = join(SCRIPT_DIR, "verify-wiki-mem0-workflow-boundary.mjs");
const roots = [];
process.on("exit", () =>
  roots.forEach((dir) => rmSync(dir, { recursive: true, force: true })),
);

const fixture = (strings, ...values) =>
  String.raw({ raw: strings.raw }, ...values).replaceAll("\\${", "${");

const GOOD_WORKFLOW = fixture`
name: Wiki mem0 Reconcile
on:
  workflow_dispatch:
permissions:
  contents: read
jobs:
  reconcile:
    if: github.event_name == 'schedule' || github.ref_name == github.event.repository.default_branch
    runs-on: ubuntu-latest
    permissions:
      contents: read
    outputs:
      base-sha: \${{ steps.capture-base.outputs.sha }}
    steps:
      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd
        with:
          ref: \${{ github.event.repository.default_branch }}
          persist-credentials: false
      - name: Capture reconcile base
        id: capture-base
        run: echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
      - name: Reconcile droid-wiki to mem0
        run: node scripts/wiki/mem0-sync.mjs --all --verbose
        env:
          MEM0_BURNBAR_API_KEY: \${{ secrets.MEM0_BURNBAR_API_KEY }}
      - name: Stage refreshed manifest
        run: cp droid-wiki/.mem0-manifest.json "$RUNNER_TEMP/mem0-manifest/mem0-manifest.json"
      - name: Upload refreshed manifest
        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4
        with:
          name: wiki-mem0-manifest
          path: \${{ runner.temp }}/mem0-manifest/mem0-manifest.json
  commit-refreshed-manifest:
    needs: reconcile
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd
        with:
          ref: \${{ needs.reconcile.outputs.base-sha }}
          persist-credentials: false
      - name: Download refreshed manifest
        uses: actions/download-artifact@634f93cb2916e3fdff6788551b99b062d0335ce0
        with:
          name: wiki-mem0-manifest
      - name: Restore refreshed manifest
        run: cp "$RUNNER_TEMP/mem0-manifest/mem0-manifest.json" droid-wiki/.mem0-manifest.json
      - name: Commit refreshed manifest
        run: git push "https://x-access-token:\${GITHUB_TOKEN}@github.com/\${GITHUB_REPOSITORY}.git" HEAD:main
        env:
          GITHUB_TOKEN: \${{ github.token }}
`;

function buildTree(workflow) {
  const root = mkdtempSync(join(tmpdir(), "wiki-mem0-boundary-"));
  roots.push(root);
  const workflowDir = join(root, ".github", "workflows");
  mkdirSync(workflowDir, { recursive: true });
  writeFileSync(join(workflowDir, "wiki-mem0-reconcile.yml"), workflow);
  return root;
}

function runGate(root) {
  try {
    execFileSync("node", [GATE], {
      env: { ...process.env, WIKI_MEM0_BOUNDARY_ROOT: root },
      stdio: "pipe",
    });
    return 0;
  } catch (error) {
    return error.status ?? 1;
  }
}

let passed = 0;
let failed = 0;
function expect(label, workflow, wantExit) {
  const got = runGate(buildTree(workflow));
  if (got === wantExit) {
    console.log(`  PASS ${label} (exit ${got})`);
    passed += 1;
  } else {
    console.error(`  FAIL ${label}: expected exit ${wantExit}, got ${got}`);
    failed += 1;
  }
}

console.log("Self-test: verify-wiki-mem0-workflow-boundary.mjs\n");

expect("split read/write workflow passes", GOOD_WORKFLOW, 0);

expect(
  "top-level scalar read-all workflow passes",
  GOOD_WORKFLOW.replace(
    "permissions:\n  contents: read",
    "permissions: read-all",
  ),
  0,
);

expect(
  "flow-style reconcile needs passes",
  GOOD_WORKFLOW.replace("    needs: reconcile", "    needs: [reconcile]"),
  0,
);

expect(
  "workflow-scope contents write fails",
  GOOD_WORKFLOW.replace(
    "permissions:\n  contents: read",
    "permissions:\n  contents: write",
  ),
  1,
);

expect(
  "reconcile job contents write fails",
  GOOD_WORKFLOW.replace("      contents: read", "      contents: write"),
  1,
);

expect(
  "reconcile job scalar write-all fails",
  GOOD_WORKFLOW.replace(
    "    permissions:\n      contents: read",
    "    permissions: write-all",
  ),
  1,
);

expect(
  "reconcile job extra write scope fails",
  GOOD_WORKFLOW.replace(
    "      contents: read",
    "      contents: read\n      pull-requests: write",
  ),
  1,
);

expect(
  "reconcile job flow-style extra write scope fails",
  GOOD_WORKFLOW.replace(
    "    permissions:\n      contents: read",
    "    permissions: { contents: read, pull-requests: write }",
  ),
  1,
);

expect(
  "reconcile job missing default-branch dispatch gate fails",
  GOOD_WORKFLOW.replace(
    "    if: github.event_name == 'schedule' || github.ref_name == github.event.repository.default_branch\n",
    "",
  ),
  1,
);

expect(
  "reconcile checkout missing default-branch ref fails",
  GOOD_WORKFLOW.replace(
    "          ref: ${{ github.event.repository.default_branch }}\n",
    "",
  ),
  1,
);

expect(
  "workflow-level mem0 env fails",
  GOOD_WORKFLOW.replace(
    "jobs:\n",
    "env:\n  MEM0_BURNBAR_API_KEY: ${{ secrets.MEM0_BURNBAR_API_KEY }}\njobs:\n",
  ),
  1,
);

expect(
  "commit job extra write scope fails",
  GOOD_WORKFLOW.replace(
    "      contents: write",
    "      contents: write\n      pull-requests: write",
  ),
  1,
);

expect(
  "single job with mem0 secret and git push fails",
  GOOD_WORKFLOW.replace(
    "  commit-refreshed-manifest:",
    "      - name: Bad push\n        run: git push origin HEAD:main\n        env:\n          GITHUB_TOKEN: ${{ github.token }}\n  commit-refreshed-manifest:",
  ),
  1,
);

expect(
  "commit job receiving mem0 secret fails",
  GOOD_WORKFLOW.replace(
    "          GITHUB_TOKEN: ${{ github.token }}",
    "          GITHUB_TOKEN: ${{ github.token }}\n          MEM0_BURNBAR_API_KEY: ${{ secrets.MEM0_BURNBAR_API_KEY }}",
  ),
  1,
);

expect(
  "commit job missing reconcile dependency fails",
  GOOD_WORKFLOW.replace("    needs: reconcile\n", ""),
  1,
);

expect(
  "commit job missing artifact download fails",
  GOOD_WORKFLOW.replace(
    "actions/download-artifact@634f93cb2916e3fdff6788551b99b062d0335ce0",
    "actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd",
  ),
  1,
);

expect(
  "commit job missing reconcile base checkout fails",
  GOOD_WORKFLOW.replace(
    "          ref: ${{ needs.reconcile.outputs.base-sha }}\n",
    "",
  ),
  1,
);

expect(
  "mem0 secret on additional reconcile step fails",
  GOOD_WORKFLOW.replace(
    "      - name: Stage refreshed manifest",
    "      - name: Extra helper\n        run: echo helper\n        env:\n          MEM0_BURNBAR_API_KEY: ${{ secrets.MEM0_BURNBAR_API_KEY }}\n      - name: Stage refreshed manifest",
  ),
  1,
);

console.log(
  `\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`,
);
process.exit(failed === 0 ? 0 : 1);
