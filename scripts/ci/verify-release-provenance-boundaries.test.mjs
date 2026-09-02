#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-release-provenance-boundaries.mjs.
 */

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const GATE = join(SCRIPT_DIR, "verify-release-provenance-boundaries.mjs");
const roots = [];
process.on("exit", () =>
  roots.forEach((dir) => rmSync(dir, { recursive: true, force: true })),
);

const fixture = (strings, ...values) =>
  String.raw({ raw: strings.raw }, ...values).replaceAll("\\${", "${");

const GOOD_RELEASE = fixture`
name: OpenBurnBar Release
permissions:
  contents: write
  id-token: write
  attestations: write
on:
  push:
    tags:
      - "v*"
  workflow_dispatch:
    inputs:
      tag:
        required: true
        type: string
      run_mobile_unit_tests:
        required: false
        type: boolean
        default: true
      mobile_unit_test_bypass_reason:
        required: false
        type: string
        default: ""
jobs:
  release-preflight:
    steps:
      - name: Resolve release tag and version
        id: version
        env:
          INPUT_TAG: \${{ github.event.inputs.tag }}
        run: |
          set -euo pipefail
          if [[ "\${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then
            TAG_NAME="\${INPUT_TAG}"
          else
            TAG_NAME="\${GITHUB_REF_NAME}"
          fi
          tag_ref="refs/tags/\${TAG_NAME}"
          if [[ "\${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "\${GITHUB_REF}" != "$tag_ref" ]]; then
            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."
            exit 1
          fi
          git fetch --force --tags origin "+\${tag_ref}:\${tag_ref}"
          git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"
          if ! release_commit="$(git rev-list -n 1 "\${tag_ref}^{commit}")"; then
            exit 1
          fi
          if ! git merge-base --is-ancestor "$release_commit" origin/main; then
            exit 1
          fi
      - name: Check out release tag
        env:
          RELEASE_COMMIT: \${{ steps.version.outputs.release_commit }}
        run: |
          set -euo pipefail
          git checkout --detach "$RELEASE_COMMIT"
          test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"

      - name: Scan publishable tree for secrets
        run: ./scripts/security/scan-publishable-tree.sh
      - name: BurnBar product release preflight
        run: python3 scripts/ci/check_burnbar_release_preflight.py --allow-owner-emergency-approval --expected-release-tag "\${{ steps.version.outputs.tag_name }}"
      - name: Validate mobile unit test bypass reason
        if: \${{ github.event_name == 'workflow_dispatch' && !inputs.run_mobile_unit_tests }}
        env:
          MOBILE_UNIT_TEST_BYPASS_REASON: \${{ inputs.mobile_unit_test_bypass_reason }}
        run: |
          set -euo pipefail
          compact="\${MOBILE_UNIT_TEST_BYPASS_REASON//[[:space:]]/}"
          if [[ -z "$compact" ]]; then
            echo "::error::run_mobile_unit_tests=false requires mobile_unit_test_bypass_reason with independent mobile validation evidence."
            exit 1
          fi
          if ((\${#MOBILE_UNIT_TEST_BYPASS_REASON} < 80)); then
            echo "::error::mobile_unit_test_bypass_reason must include owner approval plus independent mobile validation evidence."
            exit 1
          fi
          if ! grep -Eiq '\b(owner|approved|approval|approver)\b' <<<"\${MOBILE_UNIT_TEST_BYPASS_REASON}"; then
            echo "::error::mobile_unit_test_bypass_reason must name owner approval."
            exit 1
          fi
          if ! grep -Eiq '\b(mobile|ios|simulator|OpenBurnBarMobileTests|test-openburnbar-mobile)\b' <<<"\${MOBILE_UNIT_TEST_BYPASS_REASON}"; then
            echo "::error::mobile_unit_test_bypass_reason must describe the independent mobile validation evidence."
            exit 1
          fi
          if ! grep -Eiq '(https://github\.com/Imagine-That-Ai/BurnBar/(actions/runs/[0-9]+|pull/[0-9]+)|[0-9a-f]{40})' <<<"\${MOBILE_UNIT_TEST_BYPASS_REASON}"; then
            echo "::error::mobile_unit_test_bypass_reason must include a GitHub run/PR URL or 40-character commit SHA for auditability."
            exit 1
          fi
  build-and-release:
    needs: release-preflight
    steps:
      - name: Check out release tag for packaging
        env:
          RELEASE_COMMIT: \${{ needs.release-preflight.outputs.release_commit }}
        run: |
          set -euo pipefail
          git checkout --detach "$RELEASE_COMMIT"
          test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"
      - name: Install Sparkle signing tools
        run: |
          set -euo pipefail
          brew install --cask sparkle
          SPARKLE_CASKROOM="$(brew --prefix)/Caskroom/sparkle"
          SPARKLE_SIGN_UPDATE="$(
            find "$SPARKLE_CASKROOM" -name sign_update -type f -print -quit 2>/dev/null || true
          )"
          if [[ -z "$SPARKLE_SIGN_UPDATE" ]]; then
            exit 1
          fi
          SPARKLE_CASKROOM_REAL="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$SPARKLE_CASKROOM")"
          SPARKLE_SIGN_UPDATE_REAL="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$SPARKLE_SIGN_UPDATE")"
          if [[ -L "$SPARKLE_SIGN_UPDATE" ]]; then
            echo "::error::Sparkle sign_update must be a regular file from the Homebrew cask, not a symlink: $SPARKLE_SIGN_UPDATE"
            exit 1
          fi
          case "$SPARKLE_SIGN_UPDATE_REAL" in
            "$SPARKLE_CASKROOM_REAL"/*) ;;
            *)
              echo "::error::Sparkle sign_update resolved outside the Homebrew Sparkle cask: $SPARKLE_SIGN_UPDATE_REAL"
              exit 1
              ;;
          esac
          if [[ ! -x "$SPARKLE_SIGN_UPDATE" ]]; then
            exit 1
          fi
      - name: Generate direct-download update feeds
        env:
          DMG_PATH: \${{ steps.dmg.outputs.dmg_path }}
          ZIP_PATH: \${{ steps.zip.outputs.zip_path }}
          SOURCE_PATH: \${{ steps.corresponding-source.outputs.source_path }}
        run: |
          DMG_NAME="$(basename "$DMG_PATH")"
          ZIP_NAME="$(basename "$ZIP_PATH")"
          SOURCE_NAME="$(basename "$SOURCE_PATH")"
          APPCAST_PATH="$RUNNER_TEMP/appcast.xml"
          LATEST_PATH="$RUNNER_TEMP/latest-macos.json"
          node scripts/generate-macos-appcast.mjs \
            --release-dir "$RUNNER_TEMP" \
            --dmg-name "$DMG_NAME" \
            --zip-name "$ZIP_NAME" \
            --source-archive-name "$SOURCE_NAME" \
            --appcast-name "$(basename "$APPCAST_PATH")" \
            --latest-name "$(basename "$LATEST_PATH")"
      - name: Sigstore blob attestations (SBOM + VEX + checksums + binaries)
        env:
          RELEASE_REF: \${{ needs.release-preflight.outputs.tag_ref }}
          RELEASE_COMMIT: \${{ needs.release-preflight.outputs.release_commit }}
        run: |
          python3 - <<'PY'
          import os
          import subprocess
          commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
          release_commit = os.environ["RELEASE_COMMIT"]
          if commit != release_commit:
              raise SystemExit("release checkout drifted")
          predicate = {
              "release": {
                  "commit": release_commit,
                  "ref": os.environ["RELEASE_REF"],
              },
          }
          PY
          cosign attest-blob --yes
  prepare-release-publication:
    needs:
      - release-preflight
      - release-swift-gate
      - release-app-gate
      - release-sqlcipher-gate
      - release-mobile-gate
      - release-android-gate
      - release-functions-gate
      - release-extension-gate
      - release-supply-chain-gate
      - build-and-release
      - domain-core-ios-release-evidence
      - smoke-test
      - apple-native-prepublication
    steps:
      - name: Stage the complete general release asset set
        run: |
          set -euo pipefail
          if ((\${#PROVENANCE_PATHS[@]} == 0)); then
            echo "::error::Release provenance bundles missing after artifact download."
            exit 1
          fi
  domain-core-native-release-evidence:
    needs:
      - release-preflight
      - domain-core-native-release-gate
      - build-and-release
      - apple-native-prepublication
      - prepare-release-publication
    if: \${{ needs.prepare-release-publication.result == 'success' && needs.apple-native-prepublication.result == 'success' }}
    steps:
      - name: Publish the complete verified release set from one draft state machine
        run: |
          set -euo pipefail
          if ((\${#asset_args[@]} == 0)); then
            echo "::error::No general release publication assets were retained."
            exit 1
          fi
          node scripts/ci/publish-apple-android-release.mjs --manifest "$manifest"
`;

const GOOD_DEPLOY_PRODUCTION = fixture`
name: Deploy Production (Cloud Functions)
permissions:
  contents: read
on:
  push:
    tags:
      - "v*"
  workflow_dispatch:
    inputs:
      tag:
        required: false
        type: string
      dry_run:
        required: false
        type: boolean
jobs:
  deploy-functions:
    steps:
      - name: BurnBar product release preflight
        if: steps.tag.outputs.dry_run != 'true'
        run: python3 scripts/ci/check_burnbar_release_preflight.py
`;

const GOOD_SUPPLY_CHAIN = fixture`
name: Supply chain provenance
on:
  workflow_dispatch:
    inputs:
      tag:
        required: true
        type: string
  workflow_run:
    workflows: ["OpenBurnBar Release"]
    types: [completed]
permissions:
  contents: read
  id-token: write
  attestations: write
jobs:
  attest-release:
    steps:
      - name: Resolve release tag
        id: tag
        env:
          EVENT_NAME: \${{ github.event_name }}
          INPUT_TAG: \${{ github.event.inputs.tag }}
          RUN_HEAD: \${{ github.event.workflow_run.head_branch }}
          RUN_HEAD_SHA: \${{ github.event.workflow_run.head_sha }}
        run: |
          set -euo pipefail
          if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then
            TAG="\${INPUT_TAG}"
          else
            TAG="\${RUN_HEAD}"
          fi
          tag_ref="refs/tags/\${TAG}"
          if [[ "$EVENT_NAME" == "workflow_dispatch" && "\${GITHUB_REF}" != "$tag_ref" ]]; then
            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."
            exit 1
          fi
          git fetch --force --tags origin "+\${tag_ref}:\${tag_ref}"
          git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"
          if ! commit="$(git rev-list -n 1 "\${tag_ref}^{commit}")"; then
            exit 1
          fi
          if ! git merge-base --is-ancestor "$commit" origin/main; then
            exit 1
          fi
          if [[ "$EVENT_NAME" != "workflow_dispatch" && ( -z "\${RUN_HEAD_SHA:-}" || "$RUN_HEAD_SHA" != "$commit" ) ]]; then
            exit 1
          fi
      - name: Check out release tag
        env:
          RELEASE_COMMIT: \${{ steps.tag.outputs.commit }}
        run: |
          set -euo pipefail
          git checkout --detach "$RELEASE_COMMIT"
          test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"
      - name: Attest SBOM and VEX
        run: cosign attest-blob --yes "$SBOM_PATH"
`;

function buildTree(
  releaseWorkflow = GOOD_RELEASE,
  provenanceWorkflow = GOOD_SUPPLY_CHAIN,
  deployProductionWorkflow = GOOD_DEPLOY_PRODUCTION,
) {
  const root = mkdtempSync(join(tmpdir(), "release-provenance-boundary-"));
  roots.push(root);
  const workflowDir = join(root, ".github", "workflows");
  mkdirSync(workflowDir, { recursive: true });
  writeFileSync(join(workflowDir, "release.yml"), releaseWorkflow);
  writeFileSync(
    join(workflowDir, "deploy-production.yml"),
    deployProductionWorkflow,
  );
  writeFileSync(
    join(workflowDir, "supply-chain-provenance.yml"),
    provenanceWorkflow,
  );
  return root;
}

function runGate(root) {
  try {
    execFileSync("node", [GATE], {
      env: { ...process.env, RELEASE_PROVENANCE_BOUNDARY_ROOT: root },
      stdio: "pipe",
    });
    return { status: 0, output: "" };
  } catch (error) {
    return {
      status: error.status ?? 1,
      output:
        `${error.stdout?.toString() ?? ""}${error.stderr?.toString() ?? ""}`.trim(),
    };
  }
}

let passed = 0;
let failed = 0;
function expect(
  label,
  releaseWorkflow,
  provenanceWorkflow,
  wantExit,
  deployProductionWorkflow = GOOD_DEPLOY_PRODUCTION,
) {
  const got = runGate(
    buildTree(releaseWorkflow, provenanceWorkflow, deployProductionWorkflow),
  );
  if (got.status === wantExit) {
    console.log(`  PASS ${label} (exit ${got.status})`);
    passed += 1;
  } else {
    console.error(
      `  FAIL ${label}: expected exit ${wantExit}, got ${got.status}`,
    );
    if (got.output) console.error(got.output);
    failed += 1;
  }
}

console.log("Self-test: verify-release-provenance-boundaries.mjs\n");

expect(
  "tag-bound release and provenance workflows pass",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN,
  0,
);

expect(
  "flow-style packaging needs retain the release-preflight boundary",
  GOOD_RELEASE.replace(
    "  build-and-release:\n    needs: release-preflight",
    "  build-and-release:\n    needs:\n      [\n        release-preflight,\n        domain-core-native-release-gate,\n      ]",
  ),
  GOOD_SUPPLY_CHAIN,
  0,
);

expect(
  "release workflow hold bypass input fails",
  GOOD_RELEASE.replace(
    "      tag:\n        required: true\n        type: string",
    "      tag:\n        required: true\n        type: string\n      release_hold_bypass_reason:\n        required: false\n        type: string",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow conditional product preflight fails",
  GOOD_RELEASE.replace(
    '      - name: BurnBar product release preflight\n        run: python3 scripts/ci/check_burnbar_release_preflight.py --allow-owner-emergency-approval --expected-release-tag "${{ steps.version.outputs.tag_name }}"',
    "      - name: BurnBar product release preflight\n        if: ${{ inputs.release_hold_bypass_reason == '' }}\n        run: python3 scripts/ci/check_burnbar_release_preflight.py --allow-owner-emergency-approval --expected-release-tag \"${{ steps.version.outputs.tag_name }}\"",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow owner emergency missing expected tag fails",
  GOOD_RELEASE.replace(
    ' --expected-release-tag "${{ steps.version.outputs.tag_name }}"',
    "",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "production deploy hold bypass input fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN,
  1,
  GOOD_DEPLOY_PRODUCTION.replace(
    "      dry_run:\n        required: false\n        type: boolean",
    "      dry_run:\n        required: false\n        type: boolean\n      release_hold_bypass_reason:\n        required: false\n        type: string",
  ),
);

expect(
  "production deploy conditional product preflight fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN,
  1,
  GOOD_DEPLOY_PRODUCTION.replace(
    "        if: steps.tag.outputs.dry_run != 'true'\n",
    "        if: ${{ inputs.release_hold_bypass_reason == '' }}\n",
  ),
);

expect(
  "production deploy inverted dry-run preflight guard fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN,
  1,
  GOOD_DEPLOY_PRODUCTION.replace(
    "        if: steps.tag.outputs.dry_run != 'true'\n",
    "        if: steps.tag.outputs.dry_run == 'true'\n",
  ),
);

expect(
  "production deploy stacked dry-run preflight guard fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN,
  1,
  GOOD_DEPLOY_PRODUCTION.replace(
    "        if: steps.tag.outputs.dry_run != 'true'\n",
    "        if: steps.tag.outputs.dry_run != 'true' || inputs.force == 'true'\n",
  ),
);

expect(
  "release workflow dry-run skip on product preflight fails",
  GOOD_RELEASE.replace(
    "      - name: BurnBar product release preflight\n",
    "      - name: BurnBar product release preflight\n        if: steps.tag.outputs.dry_run != 'true'\n",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow missing manual tag-ref guard fails",
  GOOD_RELEASE.replace(
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow comment-only manual tag-ref guard fails",
  GOOD_RELEASE.replace(
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'echo "manual dispatch"\n          # if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow decoy-step manual tag-ref guard fails",
  GOOD_RELEASE.replace(
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then',
  ).replace(
    "      - name: Resolve release tag and version\n",
    '      - name: Decoy release guard\n        if: false\n        run: |\n          set -euo pipefail\n          tag_ref="refs/tags/${TAG_NAME}"\n          if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1\n          fi\n          git fetch --force --tags origin "+${tag_ref}:${tag_ref}"\n      - name: Resolve release tag and version\n',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow same-name conditional decoy step fails",
  GOOD_RELEASE.replace(
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then',
  ).replace(
    "      - name: Resolve release tag and version\n",
    '      - name: Resolve release tag and version\n        if: false\n        run: |\n          set -euo pipefail\n          tag_ref="refs/tags/${TAG_NAME}"\n          if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1\n          fi\n          git fetch --force --tags origin "+${tag_ref}:${tag_ref}"\n      - name: Resolve release tag and version\n',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow quoted same-name conditional decoy step fails",
  GOOD_RELEASE.replace(
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then',
  ).replace(
    "      - name: Resolve release tag and version\n",
    '      - name: "Resolve release tag and version"\n        if: false\n        run: |\n          set -euo pipefail\n          tag_ref="refs/tags/${TAG_NAME}"\n          if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1\n          fi\n          git fetch --force --tags origin "+${tag_ref}:${tag_ref}"\n      - name: Resolve release tag and version\n',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow anchored same-name conditional decoy step fails",
  GOOD_RELEASE.replace(
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then',
  ).replace(
    "      - name: Resolve release tag and version\n",
    '      - name: &release_resolve Resolve release tag and version\n        if: false\n        run: |\n          set -euo pipefail\n          tag_ref="refs/tags/${TAG_NAME}"\n          if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1\n          fi\n          git fetch --force --tags origin "+${tag_ref}:${tag_ref}"\n      - name: Resolve release tag and version\n',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow heredoc-only manual tag-ref guard fails",
  GOOD_RELEASE.replace(
    'if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1\n          fi',
    'cat <<\'EOF\'\n          if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1\n          fi\n          EOF\n          if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then\n            exit 1\n          fi',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow neutered manual tag-ref guard body fails",
  GOOD_RELEASE.replace(
    'echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1',
    'echo "warning: manual ref drift"',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow unreachable manual tag-ref exit fails",
  GOOD_RELEASE.replace(
    'echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1',
    'echo "warning: manual ref drift"\n            false && exit 1',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow short-circuit escape before final exit fails",
  GOOD_RELEASE.replace(
    'echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1',
    'echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            [[ "${ALLOW_REF_DRIFT:-}" == "1" ]] && exit 0\n            exit 1',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow nested-if unreachable final exit fails",
  GOOD_RELEASE.replace(
    'echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1',
    'echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            if false; then\n              exit 1\n            fi',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow missing fail-closed shell mode fails",
  GOOD_RELEASE.replace("set -euo pipefail", "set -u"),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow checkout step missing fail-closed shell mode fails",
  GOOD_RELEASE.replace(
    "      - name: Check out release tag\n        env:\n          RELEASE_COMMIT: ${{ steps.version.outputs.release_commit }}\n        run: |\n          set -euo pipefail",
    "      - name: Check out release tag\n        env:\n          RELEASE_COMMIT: ${{ steps.version.outputs.release_commit }}\n        run: |\n          set -u",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow global Sparkle signer search fails",
  GOOD_RELEASE.replace(
    'find "$SPARKLE_CASKROOM" -name sign_update -type f -print -quit',
    'find "$SPARKLE_CASKROOM" /Applications -name sign_update \\( -type f -o -type l \\) -print -quit',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow symlink Sparkle signer acceptance fails",
  GOOD_RELEASE.replace(
    'find "$SPARKLE_CASKROOM" -name sign_update -type f -print -quit',
    'find "$SPARKLE_CASKROOM" -name sign_update \\( -type f -o -type l \\) -print -quit',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow missing Sparkle signer canonical containment check fails",
  GOOD_RELEASE.replace(
    '          case "$SPARKLE_SIGN_UPDATE_REAL" in\n            "$SPARKLE_CASKROOM_REAL"/*) ;;\n            *)\n              echo "::error::Sparkle sign_update resolved outside the Homebrew Sparkle cask: $SPARKLE_SIGN_UPDATE_REAL"\n              exit 1\n              ;;\n          esac\n',
    "",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow raw appcast output path fails",
  GOOD_RELEASE.replace(
    '--appcast-name "$(basename "$APPCAST_PATH")"',
    '--appcast-name "$APPCAST_PATH"',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow raw latest output path fails",
  GOOD_RELEASE.replace(
    '--latest-name "$(basename "$LATEST_PATH")"',
    '--latest-name "$LATEST_PATH"',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow neutralized ancestor check fails",
  GOOD_RELEASE.replace(
    'if ! git merge-base --is-ancestor "$release_commit" origin/main; then',
    'if ! git merge-base --is-ancestor "$release_commit" origin/main || true; then',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow neutered tag resolution guard body fails",
  GOOD_RELEASE.replace(
    'if ! release_commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then\n            exit 1\n          fi',
    'if ! release_commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then\n            echo "missing tag"\n          fi',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow neutered ancestor guard body fails",
  GOOD_RELEASE.replace(
    'if ! git merge-base --is-ancestor "$release_commit" origin/main; then\n            exit 1\n          fi',
    'if ! git merge-base --is-ancestor "$release_commit" origin/main; then\n            echo "not on main"\n          fi',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow neutralized checkout equality check fails",
  GOOD_RELEASE.replace(
    'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"',
    'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT" || true',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow chained checkout equality check fails",
  GOOD_RELEASE.replace(
    'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"',
    'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT" || echo drift',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow missing exact commit checkout fails",
  GOOD_RELEASE.replace(
    'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"',
    'echo "checked out release"',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow data-only checkout equality check fails",
  GOOD_RELEASE.replace(
    'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"',
    'echo \'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"\'',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow heredoc-only checkout equality check fails",
  GOOD_RELEASE.replace(
    'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"',
    'cat <<\'EOF\'\n          test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"\n          EOF',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release predicate missing checkout drift check fails",
  GOOD_RELEASE.replace(
    'if commit != release_commit:\n              raise SystemExit("release checkout drifted")',
    "print(commit)",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release predicate neutered checkout drift body fails",
  GOOD_RELEASE.replace(
    'if commit != release_commit:\n              raise SystemExit("release checkout drifted")',
    "if commit != release_commit:\n              pass",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release predicate unreachable checkout drift raise fails",
  GOOD_RELEASE.replace(
    'if commit != release_commit:\n              raise SystemExit("release checkout drifted")',
    'if commit != release_commit:\n              if False:\n                  raise SystemExit("release checkout drifted")',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release predicate string-literal checkout drift guard fails",
  GOOD_RELEASE.replace(
    'if commit != release_commit:\n              raise SystemExit("release checkout drifted")',
    '"""\n          if commit != release_commit:\n              raise SystemExit("release checkout drifted")\n          """',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow continue-on-error guard fails",
  GOOD_RELEASE.replace(
    "      - name: Resolve release tag and version\n",
    "      - name: Resolve release tag and version\n        continue-on-error: true\n",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow expression continue-on-error guard fails",
  GOOD_RELEASE.replace(
    "      - name: Resolve release tag and version\n",
    "      - name: Resolve release tag and version\n        continue-on-error: \\${{ fromJSON('true') }}\n",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow uppercase continue-on-error guard fails",
  GOOD_RELEASE.replace(
    "      - name: Resolve release tag and version\n",
    "      - name: Resolve release tag and version\n        continue-on-error: True\n",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow job-level permission override fails",
  GOOD_RELEASE.replace(
    "  build-and-release:\n    needs: release-preflight\n    steps:",
    "  build-and-release:\n    needs: release-preflight\n    permissions:\n      contents: write\n    steps:",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release publication preparation missing provenance bundle fail-closed check fails",
  GOOD_RELEASE.replace(
    "if ((${#PROVENANCE_PATHS[@]} == 0)); then",
    'if [[ -z "${PROVENANCE_PATHS[*]:-}" ]]; then',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release publication preparation Bash 4-only mapfile fails on macOS runner compatibility",
  GOOD_RELEASE.replace(
    "if ((${#PROVENANCE_PATHS[@]} == 0)); then",
    'mapfile -t PROVENANCE_PATHS < <(find "$RUNNER_TEMP" -type f -name "*.sigstore.json" -print)\n          if ((${#PROVENANCE_PATHS[@]} == 0)); then',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release publication preparation neutered provenance bundle guard body fails",
  GOOD_RELEASE.replace(
    'if ((${#PROVENANCE_PATHS[@]} == 0)); then\n            echo "::error::Release provenance bundles missing after artifact download."\n            exit 1\n          fi',
    'if ((${#PROVENANCE_PATHS[@]} == 0)); then\n            echo "warning: missing bundles"\n          fi',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release attestation env not bound to preflight outputs fails",
  GOOD_RELEASE.replace(
    "          RELEASE_REF: ${{ needs.release-preflight.outputs.tag_ref }}\n          RELEASE_COMMIT: ${{ needs.release-preflight.outputs.release_commit }}",
    "          RELEASE_REF: ${{ steps.version.outputs.tag_ref }}\n          RELEASE_COMMIT: ${{ steps.version.outputs.release_commit }}",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release publication preparation missing a validation lane need fails",
  GOOD_RELEASE.replace("      - release-swift-gate\n", ""),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release publication preparation always() lane bypass fails",
  GOOD_RELEASE.replace(
    "  prepare-release-publication:\n    needs:",
    "  prepare-release-publication:\n    if: ${{ always() }}\n    needs:",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "atomic publication missing preparation dependency fails",
  GOOD_RELEASE.replace("      - prepare-release-publication\n", ""),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "atomic publication weakened success condition fails",
  GOOD_RELEASE.replace(
    "needs.prepare-release-publication.result == 'success' && needs.apple-native-prepublication.result == 'success'",
    "needs.prepare-release-publication.result != 'cancelled'",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "atomic publication empty retained release-set guard fails",
  GOOD_RELEASE.replace(
    "if ((${#asset_args[@]} == 0)); then",
    'if [[ -z "${asset_args[*]:-}" ]]; then',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "atomic publication command removal fails",
  GOOD_RELEASE.replace(
    'node scripts/ci/publish-apple-android-release.mjs --manifest "$manifest"',
    'echo "publication skipped"',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release packaging job not consuming preflight outputs fails",
  GOOD_RELEASE.replace(
    "  build-and-release:\n    needs: release-preflight\n",
    "  build-and-release:\n",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release packaging checkout missing commit equality proof fails",
  GOOD_RELEASE.replace(
    '          RELEASE_COMMIT: ${{ needs.release-preflight.outputs.release_commit }}\n        run: |\n          set -euo pipefail\n          git checkout --detach "$RELEASE_COMMIT"\n          test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"',
    '          RELEASE_COMMIT: ${{ needs.release-preflight.outputs.release_commit }}\n        run: |\n          set -euo pipefail\n          git checkout --detach "$RELEASE_COMMIT"',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release preflight missing publishable-tree secret scan fails",
  GOOD_RELEASE.replace(
    "      - name: Scan publishable tree for secrets\n        run: ./scripts/security/scan-publishable-tree.sh\n",
    "",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow missing mobile bypass validation step fails",
  GOOD_RELEASE.replace(
    /      - name: Validate mobile unit test bypass reason[\s\S]*?      - name: Generate direct-download update feeds/u,
    "      - name: Generate direct-download update feeds",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow weak mobile bypass length guard fails",
  GOOD_RELEASE.replace(
    "if ((${#MOBILE_UNIT_TEST_BYPASS_REASON} < 80)); then",
    "if ((${#MOBILE_UNIT_TEST_BYPASS_REASON} < 1)); then",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow missing mobile bypass owner approval evidence fails",
  GOOD_RELEASE.replace(
    '          if ! grep -Eiq \'\\b(owner|approved|approval|approver)\\b\' <<<"${MOBILE_UNIT_TEST_BYPASS_REASON}"; then\n            echo "::error::mobile_unit_test_bypass_reason must name owner approval."\n            exit 1\n          fi\n',
    "",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release workflow missing mobile bypass run evidence fails",
  GOOD_RELEASE.replace(
    '          if ! grep -Eiq \'(https://github\\.com/Imagine-That-Ai/BurnBar/(actions/runs/[0-9]+|pull/[0-9]+)|[0-9a-f]{40})\' <<<"${MOBILE_UNIT_TEST_BYPASS_REASON}"; then\n            echo "::error::mobile_unit_test_bypass_reason must include a GitHub run/PR URL or 40-character commit SHA for auditability."\n            exit 1\n          fi\n',
    "",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "supply-chain workflow missing manual tag-ref guard fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then',
  ),
  1,
);

expect(
  "supply-chain workflow decoy-step manual tag-ref guard fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then',
  ).replace(
    "      - name: Resolve release tag\n",
    '      - name: Decoy provenance guard\n        if: false\n        run: |\n          set -euo pipefail\n          tag_ref="refs/tags/${TAG}"\n          if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1\n          fi\n          git fetch --force --tags origin "+${tag_ref}:${tag_ref}"\n      - name: Resolve release tag\n',
  ),
  1,
);

expect(
  "supply-chain workflow same-name conditional decoy step fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then',
  ).replace(
    "      - name: Resolve release tag\n",
    '      - name: Resolve release tag\n        if: false\n        run: |\n          set -euo pipefail\n          tag_ref="refs/tags/${TAG}"\n          if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1\n          fi\n          git fetch --force --tags origin "+${tag_ref}:${tag_ref}"\n      - name: Resolve release tag\n',
  ),
  1,
);

expect(
  "supply-chain workflow quoted same-name conditional decoy step fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then',
  ).replace(
    "      - name: Resolve release tag\n",
    '      - name: \'Resolve release tag\'\n        if: false\n        run: |\n          set -euo pipefail\n          tag_ref="refs/tags/${TAG}"\n          if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1\n          fi\n          git fetch --force --tags origin "+${tag_ref}:${tag_ref}"\n      - name: Resolve release tag\n',
  ),
  1,
);

expect(
  "supply-chain workflow anchored same-name conditional decoy step fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    'if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then',
    'if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then',
  ).replace(
    "      - name: Resolve release tag\n",
    '      - name: &supply_chain_resolve Resolve release tag\n        if: false\n        run: |\n          set -euo pipefail\n          tag_ref="refs/tags/${TAG}"\n          if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n            echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1\n          fi\n          git fetch --force --tags origin "+${tag_ref}:${tag_ref}"\n      - name: Resolve release tag\n',
  ),
  1,
);

expect(
  "supply-chain workflow neutered manual tag-ref guard body fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    'echo "::error::Select the release tag as the workflow dispatch ref so keyless provenance is tag-bound."\n            exit 1',
    'echo "warning: manual ref drift"',
  ),
  1,
);

expect(
  "supply-chain workflow neutered tag resolution guard body fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    'if ! commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then\n            exit 1\n          fi',
    'if ! commit="$(git rev-list -n 1 "${tag_ref}^{commit}")"; then\n            echo "missing tag"\n          fi',
  ),
  1,
);

expect(
  "supply-chain workflow neutered ancestor guard body fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    'if ! git merge-base --is-ancestor "$commit" origin/main; then\n            exit 1\n          fi',
    'if ! git merge-base --is-ancestor "$commit" origin/main; then\n            echo "not on main"\n          fi',
  ),
  1,
);

expect(
  "supply-chain workflow_run missing head-sha binding fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    'if [[ "$EVENT_NAME" != "workflow_dispatch" && ( -z "${RUN_HEAD_SHA:-}" || "$RUN_HEAD_SHA" != "$commit" ) ]]; then',
    'if [[ "$EVENT_NAME" != "workflow_dispatch" ]]; then',
  ),
  1,
);

expect(
  "supply-chain workflow_run neutered head-sha guard body fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    'if [[ "$EVENT_NAME" != "workflow_dispatch" && ( -z "${RUN_HEAD_SHA:-}" || "$RUN_HEAD_SHA" != "$commit" ) ]]; then\n            exit 1\n          fi',
    'if [[ "$EVENT_NAME" != "workflow_dispatch" && ( -z "${RUN_HEAD_SHA:-}" || "$RUN_HEAD_SHA" != "$commit" ) ]]; then\n            echo "head drift"\n          fi',
  ),
  1,
);

expect(
  "supply-chain workflow disabled errexit fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace("set -euo pipefail", "set +e"),
  1,
);

expect(
  "supply-chain workflow requesting contents write instead of read fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace("contents: read", "contents: write"),
  1,
);

expect(
  "supply-chain workflow hidden contents write fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    "attestations: write",
    "attestations: write\n  contents: write",
  ),
  1,
);

expect(
  "supply-chain workflow continue-on-error guard fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    "      - name: Resolve release tag\n",
    "      - name: Resolve release tag\n        continue-on-error: true\n",
  ),
  1,
);

expect(
  "supply-chain workflow expression continue-on-error guard fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    "      - name: Resolve release tag\n",
    "      - name: Resolve release tag\n        continue-on-error: \\${{ fromJSON('true') }}\n",
  ),
  1,
);

expect(
  "supply-chain workflow uppercase continue-on-error guard fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    "      - name: Resolve release tag\n",
    "      - name: Resolve release tag\n        continue-on-error: TRUE\n",
  ),
  1,
);

expect(
  "supply-chain workflow job-level permission override fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    "  attest-release:\n    steps:",
    "  attest-release:\n    permissions:\n      contents: read\n    steps:",
  ),
  1,
);

expect(
  "supply-chain workflow_run branch filter fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    "    types: [completed]\n",
    "    types: [completed]\n    branches: [main]\n",
  ),
  1,
);

expect(
  "supply-chain workflow attest before checkout fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    "      - name: Check out release tag\n",
    '      - name: Attest early\n        run: cosign attest-blob --yes "$SBOM_PATH"\n      - name: Check out release tag\n',
  ),
  1,
);

expect(
  "supply-chain workflow attest before manual ref guard fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    '          tag_ref="refs/tags/${TAG}"\n',
    '          tag_ref="refs/tags/${TAG}"\n          cosign attest-blob --yes "$SBOM_PATH"\n',
  ),
  1,
);

expect(
  "supply-chain workflow missing origin main fetch fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    'git fetch --force origin "+refs/heads/main:refs/remotes/origin/main"',
    'echo "main already fetched"',
  ),
  1,
);

if (failed > 0) {
  console.error(`\nFAIL: ${failed} test(s) failed; ${passed} passed.`);
  process.exit(1);
}

console.log(
  `\nPASS: ${passed} release provenance boundary verifier tests passed.`,
);
