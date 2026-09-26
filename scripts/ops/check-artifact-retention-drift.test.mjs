#!/usr/bin/env node
/**
 * Self-test for scripts/ops/check-artifact-retention-drift.mjs (offline).
 * Run: node --test scripts/ops/check-artifact-retention-drift.test.mjs
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { diffRetentionPolicies, faithfulSnapshot, loadCommitted } from "./check-artifact-retention-drift.mjs";

const committed = loadCommitted();

test("committed contract names the gcf-artifacts repo, both projects, and a KEEP floor", () => {
  assert.equal(committed.repository, "gcf-artifacts");
  assert.equal(committed.location, "us-central1");
  assert.deepEqual(committed.projects, ["burnbar", "burnbar-staging"]);
  assert.deepEqual(committed.requiredPolicies, [
    { name: "rollback-retention", action: "KEEP", keepCount: 3 },
  ]);
});

test("faithful snapshot matches; each mutation drifts with a named difference", () => {
  assert.equal(diffRetentionPolicies(committed, faithfulSnapshot(committed)).ok, true);
  const firstProject = committed.projects[0];
  const mutate = (apply) => {
    const snapshot = faithfulSnapshot(committed);
    apply(snapshot[firstProject].cleanupPolicies);
    return diffRetentionPolicies(committed, snapshot);
  };
  assert.match(mutate((policies) => { delete policies["rollback-retention"]; }).differences[0], new RegExp(`^${firstProject}: required policy`, "u"));
  assert.match(mutate((policies) => { policies["rollback-retention"].mostRecentVersions.keepCount = 1; }).differences[0], /keepCount/u);
  assert.match(mutate((policies) => { policies["rollback-retention"].action = "DELETE"; }).differences[0], /action/u);
});

test("keepCount above the floor still matches; missing project drifts", () => {
  const raised = faithfulSnapshot(committed);
  raised[committed.projects[0]].cleanupPolicies["rollback-retention"].mostRecentVersions.keepCount = 10;
  assert.equal(diffRetentionPolicies(committed, raised).ok, true);
  const missingProject = faithfulSnapshot(committed);
  delete missingProject[committed.projects[0]];
  assert.equal(diffRetentionPolicies(committed, missingProject).ok, false);
});

test("extra live policies beyond the contract do not drift", () => {
  const snapshot = faithfulSnapshot(committed);
  snapshot[committed.projects[0]].cleanupPolicies["future-experiment"] = { action: "DELETE" };
  assert.equal(diffRetentionPolicies(committed, snapshot).ok, true);
});
