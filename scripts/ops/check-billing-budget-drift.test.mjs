#!/usr/bin/env node
/**
 * Self-test for scripts/ops/check-billing-budget-drift.mjs (offline).
 * Run: node --test scripts/ops/check-billing-budget-drift.test.mjs
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { diffBillingBudget, faithfulSnapshot, loadCommitted } from "./check-billing-budget-drift.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const CLI = join(HERE, "check-billing-budget-drift.mjs");
const committed = loadCommitted();

test("committed contract is complete and scoped to the project", () => {
  assert.equal(committed.displayName, "burnbar-ops-alert-budget");
  assert.equal(committed.projectId, "burnbar");
  assert.ok(committed.amountUsd > 0);
  assert.deepEqual(committed.thresholdPercents, [0.5, 0.9, 1.0]);
  assert.match(committed.pubsubTopic, /^projects\/burnbar\/topics\//u);
});

test("faithful snapshot matches; each mutation drifts with a named difference", () => {
  assert.equal(diffBillingBudget(committed, faithfulSnapshot(committed)).ok, true);
  const mutate = (apply) => { const snapshot = faithfulSnapshot(committed); apply(snapshot[0]); return diffBillingBudget(committed, snapshot); };
  assert.match(mutate((b) => { b.amount.specifiedAmount.units = "50"; }).differences[0], /^amount:/u);
  assert.match(mutate((b) => { b.thresholdRules.shift(); }).differences[0], /^thresholds:/u);
  assert.match(mutate((b) => { b.budgetFilter.projects = []; }).differences[0], /^project filter:.*account-wide/u);
  assert.match(mutate((b) => { b.notificationsRule = {}; }).differences[0], /^notification topic:/u);
  assert.match(diffBillingBudget(committed, []).differences[0], /^missing:/u);
});

test("CLI: --self-test passes, --live matches exit 0 and drifts exit 1, no account exits 2", () => {
  assert.equal(spawnSync(process.execPath, [CLI, "--self-test"], { encoding: "utf8" }).status, 0);
  const dir = mkdtempSync(join(tmpdir(), "budget-drift-"));
  try {
    const good = join(dir, "good.json");
    writeFileSync(good, JSON.stringify(faithfulSnapshot(committed)));
    assert.equal(spawnSync(process.execPath, [CLI, "--live", good], { encoding: "utf8" }).status, 0);
    const bad = join(dir, "bad.json");
    writeFileSync(bad, JSON.stringify([]));
    const drift = spawnSync(process.execPath, [CLI, "--live", bad], { encoding: "utf8" });
    assert.equal(drift.status, 1);
    assert.match(drift.stdout, /DRIFT/u);
    const unconfigured = spawnSync(process.execPath, [CLI], { encoding: "utf8", env: { ...process.env, OPS_BILLING_ACCOUNT: "" } });
    assert.equal(unconfigured.status, 2);
    assert.match(unconfigured.stderr, /billing-account-not-configured/u);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
