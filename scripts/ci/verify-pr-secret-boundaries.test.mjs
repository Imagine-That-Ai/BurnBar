#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-pr-secret-boundaries.mjs.
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
const GATE = join(SCRIPT_DIR, "verify-pr-secret-boundaries.mjs");
const roots = [];

process.on("exit", () =>
  roots.forEach((dir) => rmSync(dir, { recursive: true, force: true })),
);

function buildTree(mutator = () => {}) {
  const root = mkdtempSync(join(tmpdir(), "pr-secret-boundary-"));
  roots.push(root);
  mkdirSync(join(root, ".github", "workflows"), { recursive: true });
  mkdirSync(join(root, "scripts", "ci"), { recursive: true });
  for (const path of [
    ".github/workflows/qa.yml",
    ".github/workflows/code-quality.yml",
    ".github/workflows/workflow-lint.yml",
  ]) {
    copyFileSync(join(REPO_ROOT, path), join(root, path));
  }
  mutator(root);
  return root;
}

function mutate(root, relativePath, edit) {
  const path = join(root, relativePath);
  const original = readFileSync(path, "utf8");
  const updated = edit(original);
  if (updated === original) {
    throw new Error(`mutation did not change ${relativePath}`);
  }
  writeFileSync(path, updated);
}

function runGate(root) {
  try {
    execFileSync("node", [GATE], {
      env: { ...process.env, PR_SECRET_BOUNDARY_ROOT: root },
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
    console.log(`  ✓ ${label} (exit ${got})`);
    passed += 1;
  } else {
    console.error(`  ✗ ${label}: expected exit ${wantExit}, got ${got}`);
    failed += 1;
  }
}

console.log("Self-test: verify-pr-secret-boundaries.mjs\n");

expect("current workflow fixtures pass", () => {}, 0);

expect(
  "QA same-repo-only gate without trusted author fails",
  (root) =>
    mutate(root, ".github/workflows/qa.yml", (text) =>
      text.replace(
        'github.event_name != \'pull_request\' || (github.event.pull_request.head.repo.full_name == github.repository && contains(fromJSON(\'["OWNER","MEMBER","COLLABORATOR"]\'), github.event.pull_request.author_association))',
        "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository",
      ),
    ),
  1,
);

expect(
  "QA secret-bearing step without INTERNAL_RUN gate fails",
  (root) =>
    mutate(root, ".github/workflows/qa.yml", (text) =>
      text.replace("        if: env.INTERNAL_RUN == 'true'\n", ""),
    ),
  1,
);

expect(
  "QA secret outside Run QA fails",
  (root) =>
    mutate(root, ".github/workflows/qa.yml", (text) =>
      text.replace(
        "      - name: Install ImageMagick\n",
        "      - name: Install ImageMagick\n        env:\n          FACTORY_API_KEY: ${{ secrets.FACTORY_API_KEY }}\n",
      ),
    ),
  1,
);

expect(
  "Android secret gate without trusted author fails",
  (root) =>
    mutate(root, ".github/workflows/code-quality.yml", (text) =>
      text.replace(
        'github.event_name != \'pull_request\' || (github.event.pull_request.head.repo.full_name == github.repository && contains(fromJSON(\'["OWNER","MEMBER","COLLABORATOR"]\'), github.event.pull_request.author_association))',
        "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository",
      ),
    ),
  1,
);

expect(
  "Android real Firebase injection without trusted gate fails",
  (root) =>
    mutate(root, ".github/workflows/code-quality.yml", (text) =>
      text.replace(
        "        if: env.TRUSTED_PR_SECRET_RUN == 'true' && env.HAS_ANDROID_FIREBASE_SECRET == 'true'\n",
        "",
      ),
    ),
  1,
);

expect(
  "Android non-secret fallback removal fails",
  (root) =>
    mutate(root, ".github/workflows/code-quality.yml", (text) =>
      text.replace(
        [
          "      - name: Use Android Firebase template for untrusted PRs",
          "        if: env.TRUSTED_PR_SECRET_RUN != 'true' || env.HAS_ANDROID_FIREBASE_SECRET != 'true'",
          "        run: cp android/app/google-services.json.template android/app/google-services.json",
          "",
        ].join("\n"),
        "",
      ),
    ),
  1,
);

expect(
  "Android Firebase secret in fallback step fails",
  (root) =>
    mutate(root, ".github/workflows/code-quality.yml", (text) =>
      text.replace(
        "      - name: Use Android Firebase template for untrusted PRs\n",
        "      - name: Use Android Firebase template for untrusted PRs\n        env:\n          GOOGLE_SERVICES_JSON_BASE64: ${{ secrets.GOOGLE_SERVICES_JSON_BASE64 }}\n",
      ),
    ),
  1,
);

expect(
  "workflow-lint verifier command removal fails",
  (root) =>
    mutate(root, ".github/workflows/workflow-lint.yml", (text) =>
      text.replace(
        "        run: node scripts/ci/verify-pr-secret-boundaries.mjs",
        "        run: echo skipped-pr-secret-boundaries",
      ),
    ),
  1,
);

if (failed > 0) {
  console.error(
    `\nFAIL: ${failed} self-test case(s) failed; ${passed} passed.`,
  );
  process.exit(1);
}

console.log(`\nPASS: ${passed} PR secret boundary self-test case(s) passed.`);
