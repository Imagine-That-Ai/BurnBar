import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, cpSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..", "..");
const SCRIPT = resolve(HERE, "..", "check-budget-enforcement-fixture.mjs");

const COPIES = [
  "tests/fixtures/budget-enforcement/budget-enforcement-vectors.json",
  // Phase-2 WS-B packet B1: fixture co-moved with BudgetGateContractVectorTests
  // into OpenBurnBarKernelModelsTests.
  "OpenBurnBarCore/Tests/OpenBurnBarKernelModelsTests/Fixtures/budget-enforcement-vectors.json",
  "android/app/src/test/resources/budget-enforcement/budget-enforcement-vectors.json",
];
const ENT_COPIES = [
  "tests/fixtures/budget-enforcement/entitlement-vectors.json",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/entitlement-vectors.json",
];

function makeTree() {
  const root = mkdtempSync(join(tmpdir(), "bev-"));
  for (const rel of [...COPIES, ...ENT_COPIES]) {
    const dst = join(root, rel);
    mkdirSync(dirname(dst), { recursive: true });
    cpSync(resolve(REPO, rel), dst);
  }
  return root;
}

function run(root) {
  try {
    execFileSync("node", [SCRIPT], { env: { ...process.env, BUDGET_FIXTURE_REPO_ROOT: root }, stdio: "pipe" });
    return 0;
  } catch (e) {
    return e.status ?? 1;
  }
}

test("passes on the committed fixtures", () => {
  const root = makeTree();
  try {
    assert.equal(run(root), 0);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("fails when a committed copy drifts (byte-identity)", () => {
  const root = makeTree();
  try {
    const p = join(root, COPIES[1]);
    const j = JSON.parse(readFileSync(p, "utf8"));
    j.vectors[0].description = "drifted";
    writeFileSync(p, JSON.stringify(j));
    assert.equal(run(root), 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("fails when a scope is dropped from every copy (coverage matrix)", () => {
  const root = makeTree();
  try {
    for (const rel of COPIES) {
      const p = join(root, rel);
      const j = JSON.parse(readFileSync(p, "utf8"));
      j.vectors = j.vectors.filter((v) => !v.rules.some((r) => r.scope === "organization"));
      writeFileSync(p, JSON.stringify(j));
    }
    assert.equal(run(root), 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("fails when a copy is deleted (fail-closed on deletion)", () => {
  const root = makeTree();
  try {
    rmSync(join(root, COPIES[2]));
    assert.equal(run(root), 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
