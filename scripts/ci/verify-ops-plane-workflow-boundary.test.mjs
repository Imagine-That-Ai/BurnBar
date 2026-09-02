#!/usr/bin/env node
/**
 * Self-test for scripts/ci/verify-ops-plane-workflow-boundary.mjs.
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
const GATE = join(SCRIPT_DIR, "verify-ops-plane-workflow-boundary.mjs");
const WORKFLOW = ".github/workflows/ops-plane-verify.yml";
const roots = [];

process.on("exit", () => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

function buildTree(mutator = () => {}) {
  const root = mkdtempSync(join(tmpdir(), "ops-plane-boundary-"));
  roots.push(root);
  mkdirSync(join(root, ".github", "workflows"), { recursive: true });
  copyFileSync(join(REPO_ROOT, WORKFLOW), join(root, WORKFLOW));
  mutator(root);
  return root;
}

function mutate(root, edit) {
  const path = join(root, WORKFLOW);
  const original = readFileSync(path, "utf8");
  const updated = edit(original);
  if (updated === original) throw new Error("mutation did not change workflow");
  writeFileSync(path, updated);
}

function runGate(root) {
  try {
    execFileSync("node", [GATE], {
      env: { ...process.env, OPS_PLANE_WORKFLOW_BOUNDARY_ROOT: root },
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

console.log("Self-test: verify-ops-plane-workflow-boundary.mjs\n");

expect("current ops-plane workflow passes", () => {}, 0);

expect(
  "detector outside production environment fails",
  (root) => mutate(root, (text) => text.replace("    environment: production\n    outputs:\n", "    outputs:\n")),
  1,
);

expect(
  "top-level OIDC permission fails",
  (root) =>
    mutate(root, (text) =>
      text.replace("permissions:\n  contents: read\n", "permissions:\n  contents: read\n  id-token: write\n"),
    ),
  1,
);

expect(
  "verify job without job-level OIDC fails",
  (root) =>
    mutate(root, (text) =>
      text.replace("    permissions:\n      contents: read\n      id-token: write\n", ""),
    ),
  1,
);

expect(
  "detector missing secret probe fails",
  (root) =>
    mutate(root, (text) =>
      text.replace("          GCP_SA_KEY: ${{ secrets.GCP_SA_KEY }}\n", ""),
    ),
  1,
);

expect(
  "verify missing detector dependency fails",
  (root) => mutate(root, (text) => text.replace("    needs: detect-secrets\n", "")),
  1,
);

expect(
  "scheduled no-secret path not fail-closed fails",
  (root) =>
    mutate(root, (text) =>
      text.replace(
        "verification could not run. Failing closed so the gap is visible instead of reporting a false green.\" >&2\n            exit 1\n          fi\n",
        "verification could not run.\" >&2\n            echo \"soft skip\"\n          fi\n",
      ),
    ),
  1,
);

// --- W0-5: the WIF-only alert-plane drift lane ---

expect(
  "WIF drift lane demoted to secret auth fails",
  (root) =>
    mutate(root, (text) =>
      text.replace(
        "          workload_identity_provider: ${{ vars.OPS_VERIFY_WIF_PROVIDER }}\n          service_account: ${{ vars.OPS_VERIFY_SERVICE_ACCOUNT }}\n",
        "          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}\n          service_account: ${{ secrets.GCP_DEPLOY_SERVICE_ACCOUNT }}\n",
      ),
    ),
  1,
);

expect(
  "WIF drift lane bound to a production environment fails",
  (root) =>
    mutate(root, (text) =>
      text.replace(
        "  alert-plane-drift:\n    if: github.event_name != 'pull_request'\n    runs-on: ubuntu-latest\n",
        "  alert-plane-drift:\n    if: github.event_name != 'pull_request'\n    runs-on: ubuntu-latest\n    environment: production\n",
      ),
    ),
  1,
);

expect(
  "WIF drift lane pull_request guard removed fails",
  (root) =>
    mutate(root, (text) => text.replace("  alert-plane-drift:\n    if: github.event_name != 'pull_request'\n", "  alert-plane-drift:\n")),
  1,
);

expect(
  "WIF drift lane without the fail-closed marker fails",
  (root) => mutate(root, (text) => text.replaceAll("wif-not-provisioned", "wif-missing-fine")),
  1,
);

expect(
  "WIF drift lane deleted entirely fails",
  (root) =>
    mutate(root, (text) =>
      text.replace(/  alert-plane-drift:\n(?: .*\n|\n)*/, ""),
    ),
  1,
);

expect(
  "flat concurrency group restored fails (W0-5 wedge)",
  (root) =>
    mutate(root, (text) =>
      text.replace(
        "  group: ops-plane-verify-${{ github.event_name }}-${{ github.ref }}\n  cancel-in-progress: ${{ github.event_name != 'workflow_dispatch' }}",
        "  group: ops-plane-verify\n  cancel-in-progress: false",
      ),
    ),
  1,
);

if (failed > 0) {
  console.error(`\nFAIL: ${failed} ops-plane workflow boundary self-test case(s) failed.`);
  process.exit(1);
}

console.log(`\nPASS: ${passed} ops-plane workflow boundary self-test case(s) passed.`);
