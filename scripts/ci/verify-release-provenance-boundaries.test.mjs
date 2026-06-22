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
jobs:
  build-and-release:
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
      - name: Sigstore blob attestations (SBOM + VEX + checksums + binaries)
        env:
          RELEASE_REF: \${{ steps.version.outputs.tag_ref }}
          RELEASE_COMMIT: \${{ steps.version.outputs.release_commit }}
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
  publish:
    steps:
      - name: Publish release assets
        run: |
          if ((\${#PROVENANCE_PATHS[@]} == 0)); then
            echo "::error::Release provenance bundles missing after artifact download."
            exit 1
          fi
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
        run: cosign attest --yes "$SBOM_PATH"
`;

function buildTree(
  releaseWorkflow = GOOD_RELEASE,
  provenanceWorkflow = GOOD_SUPPLY_CHAIN,
) {
  const root = mkdtempSync(join(tmpdir(), "release-provenance-boundary-"));
  roots.push(root);
  const workflowDir = join(root, ".github", "workflows");
  mkdirSync(workflowDir, { recursive: true });
  writeFileSync(join(workflowDir, "release.yml"), releaseWorkflow);
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
function expect(label, releaseWorkflow, provenanceWorkflow, wantExit) {
  const got = runGate(buildTree(releaseWorkflow, provenanceWorkflow));
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
    "  build-and-release:\n    steps:",
    "  build-and-release:\n    permissions:\n      contents: write\n    steps:",
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release publish missing provenance bundle fail-closed check fails",
  GOOD_RELEASE.replace(
    "if ((${#PROVENANCE_PATHS[@]} == 0)); then",
    'if [[ -z "${PROVENANCE_PATHS[*]:-}" ]]; then',
  ),
  GOOD_SUPPLY_CHAIN,
  1,
);

expect(
  "release publish neutered provenance bundle guard body fails",
  GOOD_RELEASE.replace(
    'if ((${#PROVENANCE_PATHS[@]} == 0)); then\n            echo "::error::Release provenance bundles missing after artifact download."\n            exit 1\n          fi',
    'if ((${#PROVENANCE_PATHS[@]} == 0)); then\n            echo "warning: missing bundles"\n          fi',
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
    '      - name: Attest early\n        run: cosign attest --yes "$SBOM_PATH"\n      - name: Check out release tag\n',
  ),
  1,
);

expect(
  "supply-chain workflow attest before manual ref guard fails",
  GOOD_RELEASE,
  GOOD_SUPPLY_CHAIN.replace(
    '          tag_ref="refs/tags/${TAG}"\n',
    '          tag_ref="refs/tags/${TAG}"\n          cosign attest --yes "$SBOM_PATH"\n',
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
