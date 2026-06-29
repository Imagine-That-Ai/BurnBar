#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-hosting-deploy-boundary.mjs.
 */

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const GATE = join(SCRIPT_DIR, "verify-hosting-deploy-boundary.mjs");
const roots = [];
process.on("exit", () =>
  roots.forEach((dir) => rmSync(dir, { recursive: true, force: true })),
);

const fixture = (strings, ...values) =>
  String.raw({ raw: strings.raw }, ...values).replaceAll("\\${", "${");

const GOOD = fixture`
name: Deploy Production (Hosting)
permissions:
  contents: read
on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      dry_run:
        required: false
        type: boolean
jobs:
  build-hosting-artifacts:
    steps:
      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd
      - name: Verify hosting deploy ref
        env:
          EVENT_NAME: \${{ github.event_name }}
        run: |
          set -euo pipefail
          if [[ "$EVENT_NAME" == "workflow_dispatch" && "$GITHUB_REF" != "refs/heads/main" ]]; then
            echo "::error::Manual hosting deploys must run from refs/heads/main."
            exit 1
          fi
          git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"
          if ! git merge-base --is-ancestor "$GITHUB_SHA" origin/main; then
            echo "::error::Hosting deploy commit is not reachable from origin/main."
            exit 1
          fi
      - name: Build immutable hosting outputs
        run: npm run build --prefix website
      - name: Upload immutable hosting artifact
        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4
  deploy-hosting:
    needs: build-hosting-artifacts
    if: \${{ github.event.inputs.dry_run != 'true' }}
    environment: production
    permissions:
      contents: read
      id-token: write
    steps:
      - name: Download immutable hosting artifact
        uses: actions/download-artifact@634f93cb2916e3fdff6788551b99b062d0335ce0
      - name: Verify hosting artifact and CI config
        env:
          FIREBASE_HOSTING_CI_CONFIG: \${{ runner.temp }}/hosting-artifact/firebase-hosting.ci.json
        run: sha256sum -c SHA256SUMS
      - uses: actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e
        with:
          node-version: 22
      - name: Authenticate to Google Cloud (hosting-only WIF/OIDC)
        id: hosting_auth
        uses: google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093
        with:
          token_format: access_token
      - name: Deploy Hosting (marketing + console)
        env:
          ARTIFACT_ROOT: \${{ runner.temp }}/hosting-artifact
          FIREBASE_HOSTING_CI_CONFIG: \${{ runner.temp }}/hosting-artifact/firebase-hosting.ci.json
          FIREBASE_HOSTING_REST_ACCESS_TOKEN: \${{ steps.hosting_auth.outputs.access_token }}
        run: |
          node "$ARTIFACT_ROOT/scripts/ci/deploy-firebase-hosting-rest.mjs" \
            --project burnbar \
            --config "$FIREBASE_HOSTING_CI_CONFIG" \
            --firebaserc "$ARTIFACT_ROOT/.firebaserc"
`;

function buildTree(workflow) {
  const root = mkdtempSync(join(tmpdir(), "hosting-deploy-boundary-"));
  roots.push(root);
  const workflowDir = join(root, ".github", "workflows");
  mkdirSync(workflowDir, { recursive: true });
  writeFileSync(join(workflowDir, "deploy-hosting.yml"), workflow);
  return root;
}

function runGate(root) {
  try {
    execFileSync("node", [GATE], {
      env: { ...process.env, HOSTING_DEPLOY_BOUNDARY_ROOT: root },
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

console.log("Self-test: verify-hosting-deploy-boundary.mjs\n");

expect("current hardened hosting workflow passes", GOOD, 0);
expect(
  "missing manual main-ref guard fails",
  GOOD.replace(
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "$GITHUB_REF" != "refs/heads/main" ]]; then',
    'if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then',
  ),
  1,
);
expect(
  "comment-only manual main-ref guard fails",
  GOOD.replace(
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "$GITHUB_REF" != "refs/heads/main" ]]; then',
    '# if [[ "$EVENT_NAME" == "workflow_dispatch" && "$GITHUB_REF" != "refs/heads/main" ]]; then',
  ),
  1,
);
expect(
  "manual guard without exit fails",
  GOOD.replace(
    '            exit 1\n          fi\n          git fetch',
    '            echo "::warning::continuing"\n          fi\n          git fetch',
  ),
  1,
);
expect(
  "missing origin-main reachability check fails",
  GOOD.replace(
    'if ! git merge-base --is-ancestor "$GITHUB_SHA" origin/main; then',
    'if [[ -n "$GITHUB_SHA" ]]; then',
  ),
  1,
);
expect(
  "ref guard after artifact upload fails",
  GOOD.replace(
    /      - name: Verify hosting deploy ref[\s\S]*?      - name: Build immutable hosting outputs/u,
    '      - name: Build immutable hosting outputs',
  ).replace(
    "      - name: Upload immutable hosting artifact",
    `      - name: Upload immutable hosting artifact
      - name: Verify hosting deploy ref
        env:
          EVENT_NAME: \${{ github.event_name }}
        run: |
          set -euo pipefail
          if [[ "$EVENT_NAME" == "workflow_dispatch" && "$GITHUB_REF" != "refs/heads/main" ]]; then
            echo "::error::Manual hosting deploys must run from refs/heads/main."
            exit 1
          fi
          git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"
          if ! git merge-base --is-ancestor "$GITHUB_SHA" origin/main; then
            echo "::error::Hosting deploy commit is not reachable from origin/main."
            exit 1
          fi`,
  ),
  1,
);
expect(
  "deploy job checkout fails",
  GOOD.replace(
    "      - name: Download immutable hosting artifact",
    "      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd\n      - name: Download immutable hosting artifact",
  ),
  1,
);
expect(
  "auth before artifact verification fails",
  GOOD.replace(
    "      - name: Verify hosting artifact and CI config",
    "      - name: Authenticate to Google Cloud (hosting-only WIF/OIDC)\n        uses: google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093\n      - name: Verify hosting artifact and CI config",
  ).replace(
    "      - name: Authenticate to Google Cloud (hosting-only WIF/OIDC)\n        uses: google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093\n      - name: Deploy Hosting",
    "      - name: Deploy Hosting",
  ),
  1,
);
expect(
  "npm after credentialed path fails",
  GOOD.replace(
    "      - name: Deploy Hosting (marketing + console)",
    "      - name: Run post-auth npm\n        run: npm ci\n      - name: Deploy Hosting (marketing + console)",
  ),
  1,
);
expect(
  "legacy Firebase token auth fails",
  GOOD.replace(
    '          node "$ARTIFACT_ROOT/scripts/ci/deploy-firebase-hosting-rest.mjs" \\\n            --project burnbar \\\n            --config "$FIREBASE_HOSTING_CI_CONFIG" \\\n            --firebaserc "$ARTIFACT_ROOT/.firebaserc"',
    '          firebase deploy --only hosting --token "$FIREBASE_HOSTING_OIDC_ACCESS_TOKEN"',
  ),
  1,
);
expect(
  "artifact config moved outside artifact root fails",
  GOOD.replaceAll(
    "${{ runner.temp }}/hosting-artifact/firebase-hosting.ci.json",
    "${{ runner.temp }}/firebase-hosting.ci.json",
  ),
  1,
);
expect(
  "Hosting REST deployer Node 24 runtime fails",
  GOOD.replace("node-version: 22", "node-version: 24"),
  1,
);
expect(
  "artifact-downloaded REST deployer executable-bit requirement fails",
  GOOD.replace(
    '          node "$ARTIFACT_ROOT/scripts/ci/deploy-firebase-hosting-rest.mjs"',
    '          test -x "$ARTIFACT_ROOT/scripts/ci/deploy-firebase-hosting-rest.mjs"\n          node "$ARTIFACT_ROOT/scripts/ci/deploy-firebase-hosting-rest.mjs"',
  ),
  1,
);
expect(
  "self-authorized hold bypass input fails",
  GOOD.replace(
    "      dry_run:\n        required: false\n        type: boolean",
    "      dry_run:\n        required: false\n        type: boolean\n      release_hold_bypass_reason:\n        required: false\n        type: string",
  ),
  1,
);

if (failed > 0) {
  console.error(`\nFAIL: ${failed} failed, ${passed} passed`);
  process.exit(1);
}

console.log(`\nPASS: ${passed} hosting deploy boundary self-test case(s) passed.`);
