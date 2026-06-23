#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-native-build-workflow-secret-boundary.mjs.
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
const GATE = join(SCRIPT_DIR, "verify-native-build-workflow-secret-boundary.mjs");
const WORKFLOWS = [
  ".github/workflows/iroh-xcframework.yml",
  ".github/workflows/build-iroh-android-aar.yml",
  ".github/workflows/build-burnbar-remote-android-aar.yml",
];
const roots = [];

process.on("exit", () =>
  roots.forEach((dir) => rmSync(dir, { recursive: true, force: true })),
);

function buildTree(mutator = () => {}) {
  const root = mkdtempSync(join(tmpdir(), "native-build-boundary-"));
  roots.push(root);
  mkdirSync(join(root, ".github", "workflows"), { recursive: true });
  for (const relativePath of WORKFLOWS) {
    copyFileSync(join(REPO_ROOT, relativePath), join(root, relativePath));
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
      env: { ...process.env, NATIVE_BUILD_WORKFLOW_BOUNDARY_ROOT: root },
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
    console.log(`  PASS ${label} (exit ${got})`);
    passed += 1;
  } else {
    console.error(`  FAIL ${label}: expected exit ${wantExit}, got ${got}`);
    failed += 1;
  }
}

console.log("Self-test: verify-native-build-workflow-secret-boundary.mjs\n");

expect("current native build workflows pass", () => {}, 0);

expect(
  "job-level secret in xcframework workflow fails",
  (root) =>
    mutate(root, ".github/workflows/iroh-xcframework.yml", (text) =>
      text.replace(
        "    steps:\n",
        "    env:\n      NATIVE_BUILD_TOKEN: ${{ secrets.NATIVE_BUILD_TOKEN }}\n\n    steps:\n",
      ),
    ),
  1,
);

expect(
  "step-level secret in Android workflow fails",
  (root) =>
    mutate(root, ".github/workflows/build-iroh-android-aar.yml", (text) =>
      text.replace(
        "      - name: Host-side cargo check (sanity)\n",
        "      - name: Host-side cargo check (sanity)\n        env:\n          NATIVE_BUILD_TOKEN: ${{ secrets.NATIVE_BUILD_TOKEN }}\n",
      ),
    ),
  1,
);

expect(
  "checkout credentials persistence fails",
  (root) =>
    mutate(root, ".github/workflows/build-burnbar-remote-android-aar.yml", (text) =>
      text.replace("        with:\n          persist-credentials: false\n", ""),
    ),
  1,
);

expect(
  "contents write permission fails",
  (root) =>
    mutate(root, ".github/workflows/iroh-xcframework.yml", (text) =>
      text.replace("  contents: read\n", "  contents: write\n"),
    ),
  1,
);

expect(
  "id-token write permission fails",
  (root) =>
    mutate(root, ".github/workflows/build-iroh-android-aar.yml", (text) =>
      text.replace("  contents: read\n", "  contents: read\n  id-token: write\n"),
    ),
  1,
);

expect(
  "pull_request_target trigger fails",
  (root) =>
    mutate(root, ".github/workflows/build-burnbar-remote-android-aar.yml", (text) =>
      text.replace("  pull_request:\n", "  pull_request_target:\n"),
    ),
  1,
);

expect(
  "missing pull_request trigger fails",
  (root) =>
    mutate(root, ".github/workflows/iroh-xcframework.yml", (text) =>
      text.replace(
        "  pull_request:\n    paths:\n      - \"crates/openburnbar-iroh/**\"\n      - \"scripts/build-iroh-xcframework.sh\"\n      - \".github/workflows/iroh-xcframework.yml\"\n      - \"OpenBurnBarCore/Package.swift\"\n",
        "",
      ),
    ),
  1,
);

if (failed > 0) {
  console.error(`\n${failed} self-test case(s) failed; ${passed} passed.`);
  process.exit(1);
}

console.log(`\nAll ${passed} self-test cases passed.`);
