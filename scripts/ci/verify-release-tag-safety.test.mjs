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
  copyFileSync(
    join(WORKFLOWS_DIR, "deploy-production.yml"),
    join(root, ".github", "workflows", "deploy-production.yml"),
  );
  copyFileSync(
    join(WORKFLOWS_DIR, "deploy-cloud-run.yml"),
    join(root, ".github", "workflows", "deploy-cloud-run.yml"),
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
        /      candidate_sha:\n        description: "Full SHA of the release candidate on origin\/main \(dry_run only\)"\n        required: false\n        type: string\n/,
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
        /      candidate_sha:\n        description: "Full SHA of the release candidate on origin\/main \(dry_run only\)"\n        required: false\n        type: string\n/,
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
          /          if \[\[ "\$IS_DRY_RUN" == "true" \]\]; then[\s\S]*?          else\n/,
          "          ",
        )
        .replace(/            commit="\$INPUT_CANDIDATE_SHA"\n          else\n[\s\S]*?          fi\n\n/, "")
        .replace('echo "dry_run=$IS_DRY_RUN"', 'echo "dry_run=$([[ "$EVENT_NAME" == "workflow_dispatch" && "$INPUT_DRY_RUN" == "true" ]] && echo true || echo false)"'),
    ),
  1,
);

/* ── Dry-run without candidate_sha requirement fails ── */
expect(
  "production: dry-run without candidate_sha requirement fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '            if [[ -z "$INPUT_CANDIDATE_SHA" ]]; then\n              echo "::error::Dry-run dispatch requires candidate_sha (full SHA on origin/main)."\n              exit 1\n            fi\n',
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

/* ── Dry-run allowing tag ref fails ── */
expect(
  "production: dry-run allowing tag ref fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '            if [[ "$GITHUB_REF" == "$tag_ref" ]]; then\n              echo "::error::Dry-run must not run from a tag ref ($tag_ref). Dispatch from a non-tag branch or SHA ref."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

/* ── Dry-run without origin/main comparison fails ── */
expect(
  "production: dry-run without candidate==main check fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '            main_sha="$(git rev-parse origin/main)"\n            if [[ "$INPUT_CANDIDATE_SHA" != "$main_sha" ]]; then\n              echo "::error::candidate_sha $INPUT_CANDIDATE_SHA != origin/main $main_sha."\n              echo "::error::Dry-run must prove the exact commit that will be tagged is current main."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

/* ── Non-dry-run without tag ref requirement fails ── */
expect(
  "production: non-dry-run without tag ref guard fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '            if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n              echo "::error::Manual production deploy for ${TAG} must run from ${tag_ref}, not ${GITHUB_REF}."\n              echo "::error::Select the release tag as the workflow dispatch ref so production credentials stay tag-bound."\n              exit 1\n            fi\n',
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
        '            if [[ -z "$INPUT_CANDIDATE_SHA" ]]; then\n              echo "::error::Dry-run dispatch requires candidate_sha (full SHA on origin/main)."\n              exit 1\n            fi\n',
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
  "cloud-run: dry-run allowing tag ref fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '            if [[ "$GITHUB_REF" == "$tag_ref" ]]; then\n              echo "::error::Dry-run must not run from a tag ref ($tag_ref). Dispatch from a non-tag branch or SHA ref."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: dry-run without candidate==main check fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '            main_sha="$(git rev-parse origin/main)"\n            if [[ "$INPUT_CANDIDATE_SHA" != "$main_sha" ]]; then\n              echo "::error::candidate_sha $INPUT_CANDIDATE_SHA != origin/main $main_sha."\n              echo "::error::Dry-run must prove the exact commit that will be tagged is current main."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: non-dry-run without tag ref guard fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '            if [[ "$EVENT_NAME" == "workflow_dispatch" && "${GITHUB_REF}" != "$tag_ref" ]]; then\n              echo "::error::Manual Cloud Run deploy for ${TAG} must run from ${tag_ref}, not ${GITHUB_REF}."\n              echo "::error::Select the release tag as the workflow dispatch ref so production credentials stay tag-bound."\n              exit 1\n            fi\n',
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
        '  workflow_dispatch:',
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
        '  workflow_dispatch:',
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
      text.replace(
        "      - name: Publish dry-run attestation\n",
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: removing verify-attestations job fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        /  verify-attestations:\n    name: Verify dry-run attestations[\s\S]*?run: node scripts\/ci\/release-dry-run-attestation\.mjs verify --sha "\$ATTEST_SHA" --tag "\$ATTEST_TAG"\n/,
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
    mutate(root, PROD, (text) =>
      text.replace("      statuses: write\n", ""),
    ),
  1,
);

/* ── Sentry gating mutation ── */
expect(
  "production: Sentry without dry_run gate fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        "        if: env.HAS_SENTRY_AUTH_TOKEN == 'true' && steps.tag.outputs.dry_run != 'true'",
        "        if: env.HAS_SENTRY_AUTH_TOKEN == 'true'",
      ),
    ),
  1,
);

/* ── Tag-existence check mutations ── */
expect(
  "production: dry-run without tag-existence check fails",
  (root) =>
    mutate(root, PROD, (text) =>
      text.replace(
        '            git fetch --force --tags origin\n            if git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then\n              echo "::error::Future tag ${TAG} already exists. Dry-run validates a candidate BEFORE the tag is created."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

expect(
  "cloud-run: dry-run without tag-existence check fails",
  (root) =>
    mutate(root, CLOUD, (text) =>
      text.replace(
        '            git fetch --force --tags origin\n            if git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then\n              echo "::error::Future tag ${TAG} already exists. Dry-run validates a candidate BEFORE the tag is created."\n              exit 1\n            fi\n',
        "",
      ),
    ),
  1,
);

if (failed > 0) {
  console.error(`\nFAIL: ${failed} release-tag-safety self-test case(s) failed.`);
  process.exit(1);
}

console.log(`\nPASS: ${passed} release-tag-safety self-test case(s) passed.`);