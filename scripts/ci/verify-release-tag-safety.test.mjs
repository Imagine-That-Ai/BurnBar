#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-release-tag-safety.mjs.
 *
 * Proves pre-fix impossibility (the gate fails on original workflows) and
 * post-fix correctness (the gate passes on fixed workflows, and targeted
 * mutations that weaken any invariant are caught).
 */

import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, "..", "..");
const GATE = join(SCRIPT_DIR, "verify-release-tag-safety.mjs");
const WORKFLOWS_DIR = join(REPO_ROOT, ".github", "workflows");
const roots = [];

process.on("exit", () => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

function buildTree(mutator = () => {}) {
  const root = mkdtempSync(join(tmpdir(), "release-tag-safety-"));
  roots.push(root);
  mkdirSync(join(root, ".github", "workflows"), { recursive: true });
  mkdirSync(join(root, "scripts", "ci"), { recursive: true });
  copyFileSync(
    join(WORKFLOWS_DIR, "deploy-production.yml"),
    join(root, ".github", "workflows", "deploy-production.yml"),
  );
  copyFileSync(
    join(WORKFLOWS_DIR, "deploy-cloud-run.yml"),
    join(root, ".github", "workflows", "deploy-cloud-run.yml"),
  );
  copyFileSync(
    join(SCRIPT_DIR, "verify-existing-tag-dry-run-recovery.mjs"),
    join(root, "scripts", "ci", "verify-existing-tag-dry-run-recovery.mjs"),
  );
  copyFileSync(
    join(SCRIPT_DIR, "release-dry-run-attestation.mjs"),
    join(root, "scripts", "ci", "release-dry-run-attestation.mjs"),
  );
  mutator(root);
  return root;
}

function mutate(root, file, edit) {
  const path = join(root, ".github", "workflows", file);
  const original = readFileSync(path, "utf8");
  const updated = edit(original);
  if (updated === original) throw new Error(`mutation did not change ${file}`);
  writeFileSync(path, updated);
}

function mutateAttestation(root, edit) {
  const path = join(root, "scripts", "ci", "release-dry-run-attestation.mjs");
  const original = readFileSync(path, "utf8");
  const updated = edit(original);
  if (updated === original) {
    throw new Error("mutation did not change release-dry-run-attestation.mjs");
  }
  writeFileSync(path, updated);
}

function runGate(root) {
  try {
    execFileSync("node", [GATE], {
      env: { ...process.env, RELEASE_TAG_SAFETY_ROOT: root },
      stdio: "pipe",
    });
    return 0;
  } catch (error) {
    return error.status ?? 1;
  }
}

let passed = 0;
let failed = 0;

function expect(label, mutator, wantExit) {
  const root = buildTree(mutator);
  const got = runGate(root);
  if (got === wantExit) {
    passed += 1;
    console.log(`  PASS: ${label}`);
  } else {
    failed += 1;
    console.error(`  FAIL: ${label} (expected exit ${wantExit}, got ${got})`);
  }
}

const PROD = "deploy-production.yml";
const CLOUD = "deploy-cloud-run.yml";

console.log("Self-test: verify-release-tag-safety.mjs\n");

/* ── Post-fix: current workflows pass ── */
expect("current fixed workflows pass", () => {}, 0);

/* ── Pre-fix impossibility: remove candidate_sha + two-phase logic ── */
expect(
  "pre-fix production (no candidate_sha) fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        /      candidate_sha:\n        description: "Full immutable release-candidate SHA"\n        required: false\n        type: string\n/,
        "",
      ),
    ),
  1,
);

expect(
  "pre-fix cloud-run (no candidate_sha) fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        /      candidate_sha:\n        description: "Full immutable release-candidate SHA"\n        required: false\n        type: string\n/,
        "",
      ),
    ),
  1,
);

/* ── Remove IS_DRY_RUN branching entirely (revert to old logic) ── */
expect(
  "production: no IS_DRY_RUN branch fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text
        .replace(
          /          IS_DRY_RUN="false"\n          if \[\[ "\$EVENT_NAME" == "workflow_dispatch" && "\$INPUT_DRY_RUN" == "true" \]\]; then\n            IS_DRY_RUN="true"\n          fi\n\n/,
          "",
        )
        .replace(
          /          if \[\[ "\$IS_DRY_RUN" == "true" \|\| "\$IS_EXISTING_TAG_RETRY" == "true" \]\]; then[\s\S]*?          else\n/,
          "          ",
        )
        .replace(
          /            commit="\$INPUT_CANDIDATE_SHA"\n          else\n[\s\S]*?          fi\n\n/,
          "",
        )
        .replace(
          'echo "dry_run=$IS_DRY_RUN"',
          'echo "dry_run=$([[ "$EVENT_NAME" == "workflow_dispatch" && "$INPUT_DRY_RUN" == "true" ]] && echo true || echo false)"',
        ),
    ),
  1,
);

/* ── Dry-run without candidate_sha requirement fails ── */
expect(
  "production: dry-run without candidate_sha requirement fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '            if [[ -z "$INPUT_CANDIDATE_SHA" ]]; then\n              echo "::error::Manual release control requires candidate_sha (full immutable release SHA)."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

/* ── Dry-run without SHA format validation fails ── */
expect(
  "production: dry-run without 40-char SHA validation fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '            if ! [[ "$INPUT_CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]]; then\n              echo "::error::candidate_sha must be a full 40-char hex SHA, got: $INPUT_CANDIDATE_SHA"\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

/* ── Manual control without main-only guard fails ── */
expect(
  "production: manual control without main-only guard fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '            if [[ "$EVENT_NAME" != "workflow_dispatch" || "$GITHUB_REF" != "refs/heads/main" || "$REF_NAME" != "main" ]]; then\n              echo "::error::Manual release control must be dispatched from main; tag-selected reruns are forbidden."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

/* ── Dry-run without origin/main comparison fails ── */
expect(
  "production: future-tag dry-run without candidate==main check fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '            elif [[ "$INPUT_CANDIDATE_SHA" != "$main_sha" ]]; then\n              echo "::error::candidate_sha $INPUT_CANDIDATE_SHA != origin/main $main_sha."\n              echo "::error::A future-tag dry-run must prove the exact commit that will be tagged is current main."\n              exit 1\n',
        "",
      ),
    ),
  1,
);

/* ── Ordinary path allowing manual dispatch fails ── */
expect(
  "production: ordinary path allowing manual dispatch fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '            if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then\n              echo "::error::Manual real deploys must use existing_tag_retry=true from main; tag-selected dispatches and reruns are forbidden."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

/* ── Same mutations for cloud-run (symmetry) ── */
expect(
  "cloud-run: dry-run without candidate_sha requirement fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '            if [[ -z "$INPUT_CANDIDATE_SHA" ]]; then\n              echo "::error::Manual release control requires candidate_sha (full immutable release SHA)."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: dry-run without SHA validation fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '            if ! [[ "$INPUT_CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]]; then\n              echo "::error::candidate_sha must be a full 40-char hex SHA, got: $INPUT_CANDIDATE_SHA"\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: manual control without main-only guard fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '            if [[ "$EVENT_NAME" != "workflow_dispatch" || "$GITHUB_REF" != "refs/heads/main" || "$REF_NAME" != "main" ]]; then\n              echo "::error::Manual release control must be dispatched from main; tag-selected reruns are forbidden."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: future-tag dry-run without candidate==main check fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '            elif [[ "$INPUT_CANDIDATE_SHA" != "$main_sha" ]]; then\n              echo "::error::candidate_sha $INPUT_CANDIDATE_SHA != origin/main $main_sha."\n              echo "::error::A future-tag dry-run must prove the exact commit that will be tagged is current main."\n              exit 1\n',
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: ordinary path allowing manual dispatch fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '            if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then\n              echo "::error::Manual real deploys must use existing_tag_retry=true from main; tag-selected dispatches and reruns are forbidden."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

/* ── Remove v* push trigger fails ── */
expect(
  "production: removing v* push trigger fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '  push:\n    tags:\n      - "v*"\n  workflow_dispatch:',
        "  workflow_dispatch:",
      ),
    ),
  1,
);

expect(
  "cloud-run: removing v* push trigger fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '  push:\n    tags:\n      - "v*"\n  workflow_dispatch:',
        "  workflow_dispatch:",
      ),
    ),
  1,
);

/* ── Remove dry_run output emission fails ── */
expect(
  "production: emitting inline dry_run instead of IS_DRY_RUN fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        'echo "dry_run=$IS_DRY_RUN"',
        'echo "dry_run=$([[ "$EVENT_NAME" == "workflow_dispatch" && "$INPUT_DRY_RUN" == "true" ]] && echo true || echo false)"',
      ),
    ),
  1,
);

expect(
  "cloud-run: emitting inline dry_run instead of IS_DRY_RUN fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        'echo "dry_run=$IS_DRY_RUN"',
        'echo "dry_run=$([[ "$EVENT_NAME" == "workflow_dispatch" && "$INPUT_DRY_RUN" == "true" ]] && echo true || echo false)"',
      ),
    ),
  1,
);

/* ── Deploy-job dry_run gate removal for cloud-run fails ── */
expect(
  "cloud-run: deploy job without dry_run gate fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        "    if: needs.resolve-release.outputs.dry_run != 'true'",
        "    if: true",
      ),
    ),
  1,
);

/* ── Attestation mutations ── */
expect(
  "production: removing publish attestation step fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        "      - name: Publish dry-run attestation\n        if: steps.tag.outputs.dry_run == 'true'\n",
        "",
      ),
    ),
  1,
);

expect(
  "production: removing verify attestation step fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        "      - name: Verify dry-run attestations\n        if: steps.tag.outputs.dry_run != 'true'\n",
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: removing publish attestation step fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace("      - name: Publish dry-run attestation\n", ""),
    ),
  1,
);

expect(
  "cloud-run: removing verify-attestations job fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        /  verify-attestations:\n    name: Verify dry-run attestations[\s\S]*?run: node .*release-dry-run-attestation\.mjs verify --sha "\$ATTEST_SHA" --tag "\$ATTEST_TAG" --control-sha "\$ATTEST_CONTROL_SHA"\n/,
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: removing verify-attestations from deploy needs fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace("      - verify-attestations\n", ""),
    ),
  1,
);

expect(
  "production: removing statuses:write permission fails",
  (root) =>
    mutate(root, PROD, (text) => text.replace("      statuses: write\n", "")),
  1,
);

expect(
  "production: attestation verify without actions:read fails",
  (root) =>
    mutate(root, PROD, (text) => text.replace("      actions: read\n", "")),
  1,
);

expect(
  "cloud-run: attestation verify without actions:read fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        "    permissions:\n      actions: read\n      contents: read\n      statuses: read\n",
        "    permissions:\n      contents: read\n      statuses: read\n",
      ),
    ),
  1,
);

expect(
  "cloud-run: attestation verify with OIDC fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        "    permissions:\n      actions: read\n      contents: read\n      statuses: read\n",
        "    permissions:\n      actions: read\n      contents: read\n      id-token: write\n      statuses: read\n",
      ),
    ),
  1,
);

expect(
  "production: attestation helper staged after candidate checkout fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '      - name: Stage trusted release attestation helper\n        run: install -m 0700 scripts/ci/release-dry-run-attestation.mjs "$RUNNER_TEMP/release-dry-run-attestation.mjs"\n\n',
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: mutable main attestation helper checkout fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        "          ref: ${{ github.sha }}\n",
        "          ref: main\n",
      ),
    ),
  1,
);

/* ── Production deploy-job dry_run gate removal fails ── */
expect(
  "production: credentialed deploy job without dry_run gate fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        "          && needs.prepare-functions-deploy.outputs.dry_run != 'true' }}",
        "          && true }}",
      ),
    ),
  1,
);

/* ── Existing-tag recovery guard mutations ── */
expect(
  "production: existing-tag recovery without main-only guard fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '            if [[ "$EVENT_NAME" != "workflow_dispatch" || "$GITHUB_REF" != "refs/heads/main" || "$REF_NAME" != "main" ]]; then\n              echo "::error::Manual release control must be dispatched from main; tag-selected reruns are forbidden."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: existing-tag recovery without annotated-tag guard fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '              if [[ "$(git cat-file -t "$tag_ref")" != "tag" ]]; then\n                echo "::error::Existing-tag control requires an annotated release tag: $TAG."\n                exit 1\n              fi\n',
        "",
      ),
    ),
  1,
);

expect(
  "production: existing-tag recovery without exact peel binding fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '              if [[ "$tag_commit" != "$INPUT_CANDIDATE_SHA" ]]; then\n                echo "::error::Existing tag $TAG peels to $tag_commit, not candidate_sha $INPUT_CANDIDATE_SHA."\n                exit 1\n              fi\n',
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: existing-tag recovery without GitHub-state verifier fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        /                node scripts\/ci\/verify-existing-tag-dry-run-recovery\.mjs \\\n                  --sha "\$INPUT_CANDIDATE_SHA" \\\n                  --tag "\$TAG" \\\n                  --plane deploy-cloud-run\n/,
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: recovery resolver without deployments read permission fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace("      deployments: read\n", ""),
    ),
  1,
);

expect(
  "production: recovery resolver with production environment fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        "    runs-on: ubuntu-latest\n    timeout-minutes: 60\n",
        "    runs-on: ubuntu-latest\n    timeout-minutes: 60\n    environment: production\n",
      ),
    ),
  1,
);

expect(
  "production: removing dedicated existing-tag retry input fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        /      existing_tag_retry:\n        description: "Current-main controlled real retry for an existing stable tag"\n        required: false\n        type: boolean\n        default: false\n/,
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: removing exact release-control run-name receipt fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(/^run-name: release-control\/deploy-cloud-run\/.*\n/mu, ""),
    ),
  1,
);

expect(
  "production: existing-tag retry without publication recheck fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace("                  --mode real-retry\n", ""),
    ),
  1,
);

expect(
  "cloud-run: existing-tag retry without exact control-SHA binding fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '                  --control-sha "$GITHUB_SHA"\n',
        '                  --control-sha "$INPUT_CANDIDATE_SHA"\n',
      ),
    ),
  1,
);

expect(
  "production: rollback environment before retry authority fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        "          && !inputs.existing_tag_retry }}\n",
        "          }}\n",
      ),
    ),
  1,
);

expect(
  "cloud-run: candidate checkout before attestation authority fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        "    steps:\n      - name: Check out trusted release attestation helper\n",
        "    steps:\n      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd\n        with:\n          ref: ${{ needs.resolve-release.outputs.commit }}\n\n      - name: Check out trusted release attestation helper\n",
      ),
    ),
  1,
);

expect(
  "attestation verifier without exact display-title receipt fails",
  (root) =>
    mutateAttestation(root, (text) =>
      text.replace(
        "      run?.display_title === receiptTitle({ plane, tag, sha, controlSha }),\n",
        "      true,\n",
      ),
    ),
  1,
);

if (failed > 0) {
  console.error(
    `\nFAIL: ${failed} release-tag-safety self-test case(s) failed.`,
  );
  process.exit(1);
}

console.log(`\nPASS: ${passed} release-tag-safety self-test case(s) passed.`);
