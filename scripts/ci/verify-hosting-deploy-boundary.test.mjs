#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-hosting-deploy-boundary.mjs.
 */

import { execFileSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const GATE = join(SCRIPT_DIR, "verify-hosting-deploy-boundary.mjs");
const WORKFLOW = readFileSync(
  join(SCRIPT_DIR, "..", "..", ".github", "workflows", "deploy-hosting.yml"),
  "utf8",
);
for (const helper of [
  "scripts/lib/atomic-regular-file.mjs",
  "scripts/lib/firebase-hosting-rest-url.mjs",
]) {
  if (!WORKFLOW.includes(`cp ${helper} "$ARTIFACT_ROOT/scripts/lib/"`)) {
    throw new Error(
      `immutable Hosting artifact omits imported helper: ${helper}`,
    );
  }
}
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
    tags: ["v*"]
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
          REQUESTED_PROFILE: \${{ inputs.domain_core_profile || 'public-production' }}
        run: |
          set -euo pipefail
          git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"
          release_tag=""
          if [[ "$GITHUB_REF" == "refs/heads/main" ]]; then
            commit="$GITHUB_SHA"
          elif [[ "$GITHUB_REF" =~ ^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.-]+)?$ ]]; then
            release_tag="\${GITHUB_REF#refs/tags/}"
            git fetch --force --tags origin "+$GITHUB_REF:$GITHUB_REF"
            commit="$(git rev-parse "$GITHUB_REF^{commit}")"
            [[ "$GITHUB_SHA" == "$commit" ]] || { echo "::error::Release tag moved away from workflow commit."; exit 1; }
          else
            echo "::error::Hosting deploys require main or an exact stable v* tag."
            exit 1
          fi
          if ! git merge-base --is-ancestor "$commit" origin/main; then
            echo "::error::Hosting deploy commit is not reachable from origin/main."
            exit 1
          fi
          profile="public-production"
          if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then
            profile="$REQUESTED_PROFILE"
          fi
          if [[ "$profile" == "public-production-rollback" ]]; then
            if [[ "$EVENT_NAME" != "workflow_dispatch" || -z "$release_tag" ]]; then
              echo "::error::Rollback is manual-only and must target an exact stable release tag."
              exit 1
            fi
          fi
      - name: Resolve signed public domain-core profile
        env:
          CANDIDATE_COMMIT: \${{ steps.activation.outputs.candidate_commit || steps.ref.outputs.commit }}
          RELEASE_TAG: \${{ steps.ref.outputs.release_tag }}
        run: |
          if [[ -n "$RELEASE_TAG" ]]; then
            echo "stable"
          fi
      - name: Build immutable hosting outputs
        run: npm run build --prefix website
      - name: Stage hosting deploy artifact
        env:
          CANDIDATE_COMMIT: \${{ steps.activation.outputs.candidate_commit || steps.ref.outputs.commit }}
          RELEASE_TAG: \${{ steps.ref.outputs.release_tag }}
        run: |
          if [[ -n "$RELEASE_TAG" ]]; then
            echo "stable"
          fi
          verify_args=(
            --expected-candidate-commit "$CANDIDATE_COMMIT"
          )
          if [[ -n "$RELEASE_TAG" ]]; then
            verify_args+=(
              --expected-release-commit "$RELEASE_COMMIT"
            )
          fi
      - name: Upload immutable hosting artifact
  deploy-hosting:
    needs: build-hosting-artifacts
    if: >-
      \${{ !cancelled()
          && needs.build-hosting-artifacts.result == 'success'
          && (github.event_name != 'workflow_dispatch' || inputs.dry_run != true) }}
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
  "deploy job without a status-check function fails (a skipped upstream gate job silently propagates a skip onto the credentialed deploy)",
  GOOD.replace(
    "!cancelled()\n          && needs.build-hosting-artifacts.result == 'success'\n          && ",
    "",
  ),
  1,
);
expect(
  "deploy job that drops the successful-build requirement fails",
  GOOD.replace(
    "\n          && needs.build-hosting-artifacts.result == 'success'",
    "",
  ),
  1,
);
expect(
  "missing stable tag trigger fails",
  GOOD.replace('    tags: ["v*"]\n', ""),
  1,
);
expect(
  "nonstable tag selector fails",
  GOOD.replace(
    "^refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+(\\+[0-9A-Za-z.-]+)?$",
    "^refs/tags/v.*$",
  ),
  1,
);
expect(
  "moved release tag guard missing fails",
  GOOD.replace(
    '            [[ "$GITHUB_SHA" == "$commit" ]] || { echo "::error::Release tag moved away from workflow commit."; exit 1; }',
    '            echo "::warning::tag movement ignored"',
  ),
  1,
);
expect(
  "missing origin-main reachability check fails",
  GOOD.replace(
    'if ! git merge-base --is-ancestor "$commit" origin/main; then',
    'if [[ -n "$commit" ]]; then',
  ),
  1,
);
expect(
  "ref guard after artifact upload fails",
  GOOD.replace(
    /      - name: Verify hosting deploy ref[\s\S]*?      - name: Build immutable hosting outputs/u,
    "      - name: Build immutable hosting outputs",
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
expect(
  "staging verify against RELEASE_COMMIT instead of CANDIDATE_COMMIT fails",
  GOOD.replace(
    '--expected-candidate-commit "$CANDIDATE_COMMIT"',
    '--expected-candidate-commit "$RELEASE_COMMIT"',
  ),
  1,
);
expect(
  "staging step missing CANDIDATE_COMMIT env fails",
  GOOD.replace(
    "      - name: Stage hosting deploy artifact\n        env:\n          CANDIDATE_COMMIT: ${{ steps.activation.outputs.candidate_commit || steps.ref.outputs.commit }}\n          RELEASE_TAG: ${{ steps.ref.outputs.release_tag }}",
    "      - name: Stage hosting deploy artifact\n        env:\n          RELEASE_TAG: ${{ steps.ref.outputs.release_tag }}",
  ),
  1,
);
expect(
  "staging step missing conditional release flag guard fails",
  GOOD.replace(
    '          if [[ -n "$RELEASE_TAG" ]]; then\n            echo "stable"\n          fi\n          verify_args=(\n            --expected-candidate-commit "$CANDIDATE_COMMIT"\n          )\n          if [[ -n "$RELEASE_TAG" ]]; then\n            verify_args+=(\n              --expected-release-commit "$RELEASE_COMMIT"\n            )\n          fi',
    '          verify_args=(\n            --expected-candidate-commit "$CANDIDATE_COMMIT"\n          )',
  ),
  1,
);
expect(
  "resolve profile step missing conditional release flag guard fails",
  GOOD.replace(
    '      - name: Resolve signed public domain-core profile\n        env:\n          CANDIDATE_COMMIT: ${{ steps.activation.outputs.candidate_commit || steps.ref.outputs.commit }}\n          RELEASE_TAG: ${{ steps.ref.outputs.release_tag }}\n        run: |\n          if [[ -n "$RELEASE_TAG" ]]; then\n            echo "stable"\n          fi',
    "      - name: Resolve signed public domain-core profile\n        env:\n          CANDIDATE_COMMIT: ${{ steps.activation.outputs.candidate_commit || steps.ref.outputs.commit }}\n          RELEASE_TAG: ${{ steps.ref.outputs.release_tag }}\n        run: echo done",
  ),
  1,
);

if (failed > 0) {
  console.error(`\nFAIL: ${failed} failed, ${passed} passed`);
  process.exit(1);
}

console.log(
  `\nPASS: ${passed} hosting deploy boundary self-test case(s) passed.`,
);
