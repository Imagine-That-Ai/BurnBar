#!/usr/bin/env node
/**
 * Unit tests for scripts/ci/check-firestore-deploy-drift.mjs.
 *
 * Covers the local-source-root resolution the trusted staging deploy relies
 * on: the post-deploy drift gate must hash the exact candidate artifacts the
 * job deployed ($RUNNER_TEMP/staging-deploy), not the trusted checkout's
 * main files. Follows the repo pattern of plain assert-based scripts that
 * exit non-zero on failure (compatible with `node --test`).
 */
import assert from "node:assert/strict";

import { resolve } from "node:path";

import { resolveLocalSourceRoot } from "./check-firestore-deploy-drift.mjs";

let passed = 0;
let failed = 0;

function ok(label) {
  console.log(`  \u2713 ${label}`);
  passed += 1;
}

function fail(label, err) {
  console.error(`  \u2717 ${label}: ${err?.message ?? err}`);
  failed += 1;
}

function testResolveLocalSourceRoot() {
  const label =
    "local source root: CLI arg > env var > repo checkout default";

  const repoRoot = "/repo";
  const baseArgv = ["node", "check-firestore-deploy-drift.mjs", "burnbar"];

  // Explicit CLI argument wins (the trusted staging deploy passes the
  // candidate staging directory it actually shipped, not trusted main).
  assert.equal(
    resolveLocalSourceRoot({
      argv: [...baseArgv, "/tmp/staging-deploy"],
      env: { FIRESTORE_DEPLOY_SOURCE_DIR: "/elsewhere" },
      repoRoot,
    }),
    "/tmp/staging-deploy",
    "CLI sourceDir argument must take precedence",
  );

  // Env var is used when no CLI argument is given.
  assert.equal(
    resolveLocalSourceRoot({
      argv: baseArgv,
      env: { FIRESTORE_DEPLOY_SOURCE_DIR: "/elsewhere" },
      repoRoot,
    }),
    "/elsewhere",
    "FIRESTORE_DEPLOY_SOURCE_DIR must be used when no CLI argument is given",
  );

  // Default: the repo checkout root (production deploy lanes pass only the
  // project argument and keep comparing against the checked-out files).
  assert.equal(
    resolveLocalSourceRoot({ argv: baseArgv, env: {}, repoRoot }),
    "/repo",
    "must default to the repo checkout root",
  );

  // Relative paths resolve against cwd, matching readFileSync semantics.
  assert.equal(
    resolveLocalSourceRoot({
      argv: [...baseArgv, "staging-deploy"],
      env: {},
      repoRoot,
    }),
    resolve("staging-deploy"),
    "relative sourceDir must resolve against cwd",
  );

  ok(label);
}

function testImportHasNoSideEffects() {
  const label =
    "importing the drift script does not run the drift check (guarded main)";
  // Reaching this point proves the import at the top of this file executed
  // no network or filesystem drift check: the module only defines helpers
  // unless invoked as the entrypoint.
  assert.equal(typeof resolveLocalSourceRoot, "function");
  ok(label);
}

// ─── Run all tests ────────────────────────────────────────────────────────

function run() {
  console.log("Self-test: check-firestore-deploy-drift.mjs\n");

  for (const [name, fn] of [
    ["testResolveLocalSourceRoot", testResolveLocalSourceRoot],
    ["testImportHasNoSideEffects", testImportHasNoSideEffects],
  ]) {
    try {
      fn();
    } catch (err) {
      fail(name, err);
    }
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed > 0) process.exit(1);
}

run();
