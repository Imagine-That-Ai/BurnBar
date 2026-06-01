#!/usr/bin/env node
/**
 * Unit tests for the final GTM launch evidence bundle validator.
 */

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { spawnSync } from "node:child_process";
import { templateCommercialCanaryReport } from "./validate-commercial-canary-report.mjs";
import { templateCommercialRollbackDrill } from "./validate-commercial-rollback-drill.mjs";
import { templateMatrix } from "./validate-cross-channel-paid-path-matrix.mjs";
import { templatePublicLaunchReport } from "./validate-public-launch-report.mjs";
import {
  templateLaunchEvidenceBundle,
  validateLaunchEvidenceBundle,
} from "./validate-launch-evidence-bundle.mjs";

function writeJSON(path, value) {
  writeFileSync(path, JSON.stringify(value, null, 2));
}

function validFixture(dir) {
  const manifest = templateLaunchEvidenceBundle();
  manifest.generatedAt = "2026-06-01T00:00:00.000Z";

  writeJSON(join(dir, "latest-commercial-launch-gate.json"), {
    verdict: { status: "READY_FOR_LIVE_PAID_PROOF" },
    checks: { repo: { ok: true } },
  });

  for (const proof of manifest.paidProofs) {
    writeJSON(join(dir, proof.path), { ok: true, proofID: proof.id });
  }

  const matrix = templateMatrix();
  matrix.generatedAt = "2026-06-01T00:00:00.000Z";
  for (const row of matrix.rows) {
    row.evidence = [{ kind: "paid-proof", path: `launch-evidence/${row.id}.json` }];
  }
  writeJSON(join(dir, "cross-channel-paid-path-matrix.json"), matrix);

  const canaryReport = templateCommercialCanaryReport();
  canaryReport.generatedAt = "2026-06-01T00:00:00.000Z";
  canaryReport.cloudGrossMarginPercent = 82;
  canaryReport.cloudProGrossMarginPercent = 55;
  writeJSON(join(dir, "canary-report.json"), canaryReport);
  const rollbackDrill = templateCommercialRollbackDrill();
  rollbackDrill.generatedAt = "2026-06-01T00:00:00.000Z";
  writeJSON(join(dir, "rollback-drill.json"), rollbackDrill);
  const publicLaunch = templatePublicLaunchReport();
  publicLaunch.generatedAt = "2026-06-01T00:00:00.000Z";
  writeJSON(join(dir, "public-launch-report.json"), publicLaunch);
  writeFileSync(join(dir, "dashboard-revenue-margin.png"), "placeholder image evidence");
  return manifest;
}

const temp = mkdtempSync(join(tmpdir(), "openburnbar-launch-bundle-"));
try {
  const manifest = validFixture(temp);
  const manifestPath = join(temp, "final-launch-evidence.json");
  writeJSON(manifestPath, manifest);

  assert.deepEqual(validateLaunchEvidenceBundle(manifest, { manifestPath }), { ok: true, errors: [] });

  {
    const broken = structuredClone(manifest);
    broken.paidProofs = broken.paidProofs.filter((proof) => proof.id !== "google_play_cloud_pro");
    const result = validateLaunchEvidenceBundle(broken, { manifestPath });
    assert.equal(result.ok, false);
    assert.ok(result.errors.includes("missing paid proof: google_play_cloud_pro"));
  }

  {
    const broken = structuredClone(manifest);
    const weakCanary = templateCommercialCanaryReport();
    weakCanary.generatedAt = "2026-06-01T00:00:00.000Z";
    weakCanary.hoursObserved = 24;
    weakCanary.paidUsersObserved = 10;
    writeJSON(join(temp, broken.canary.path), weakCanary);
    assert.deepEqual(validateLaunchEvidenceBundle(broken, { manifestPath, stage: "paid-proof" }), {
      ok: true,
      errors: [],
    });
    const result = validateLaunchEvidenceBundle(broken, { manifestPath });
    assert.equal(result.ok, false);
    assert.ok(result.errors.includes("canary: canary must observe at least 72 hours or 25 paid users"));
    const publicResult = validateLaunchEvidenceBundle(broken, { manifestPath, stage: "public-release" });
    assert.equal(publicResult.ok, false);
    assert.ok(publicResult.errors.includes("canary: canary must observe at least 72 hours or 25 paid users"));
    const restoredCanary = templateCommercialCanaryReport();
    restoredCanary.generatedAt = "2026-06-01T00:00:00.000Z";
    restoredCanary.cloudGrossMarginPercent = 82;
    restoredCanary.cloudProGrossMarginPercent = 55;
    writeJSON(join(temp, manifest.canary.path), restoredCanary);
  }

  {
    const result = validateLaunchEvidenceBundle(manifest, {
      manifestPath,
      requireDoneStamp: true,
      donePath: join(temp, "LAUNCH_DONE.md"),
    });
    assert.equal(result.ok, false);
    assert.ok(result.errors.some((error) => error.endsWith("LAUNCH_DONE.md is required")));
  }

  {
    const broken = structuredClone(manifest);
    const badReport = templatePublicLaunchReport();
    badReport.generatedAt = "2026-06-01T00:00:00.000Z";
    badReport.remoteConfig.public_paid_launch = "false";
    writeJSON(join(temp, broken.release.publicLaunchReport.path), badReport);
    const result = validateLaunchEvidenceBundle(broken, { manifestPath });
    assert.equal(result.ok, false);
    assert.ok(
      result.errors.includes("release.publicLaunchReport: remoteConfig.public_paid_launch must be true"),
    );
    const restored = templatePublicLaunchReport();
    restored.generatedAt = "2026-06-01T00:00:00.000Z";
    writeJSON(join(temp, manifest.release.publicLaunchReport.path), restored);
  }

  const doneRefs = [
    basename(manifestPath),
    manifest.launchGate.path,
    manifest.crossChannelMatrix.path,
    manifest.canary.path,
    manifest.rollbackDrill.path,
    manifest.release.publicLaunchReport.path,
    ...manifest.paidProofs.map((proof) => proof.path),
  ];
  writeFileSync(
    join(temp, "LAUNCH_DONE.md"),
    ["# LAUNCH DONE", "", ...doneRefs.map((ref) => `- ${ref}`), ""].join("\n"),
  );
  assert.deepEqual(
    validateLaunchEvidenceBundle(manifest, {
      manifestPath,
      requireDoneStamp: true,
      donePath: join(temp, "LAUNCH_DONE.md"),
    }),
    { ok: true, errors: [] },
  );

  const okRun = spawnSync(process.execPath, ["scripts/validate-launch-evidence-bundle.mjs", manifestPath], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.equal(okRun.status, 0, okRun.stderr || okRun.stdout);
  assert.match(okRun.stdout, /"ok": true/);

  const paidProofRun = spawnSync(
    process.execPath,
    ["scripts/validate-launch-evidence-bundle.mjs", "--stage", "paid-proof", manifestPath],
    {
      cwd: new URL("..", import.meta.url),
      encoding: "utf8",
    },
  );
  assert.equal(paidProofRun.status, 0, paidProofRun.stderr || paidProofRun.stdout);

  const doneRun = spawnSync(
    process.execPath,
    ["scripts/validate-launch-evidence-bundle.mjs", "--require-done-stamp", manifestPath],
    {
      cwd: new URL("..", import.meta.url),
      encoding: "utf8",
    },
  );
  assert.notEqual(doneRun.status, 0);
  assert.match(doneRun.stderr, /LAUNCH_DONE\.md is required/);
} finally {
  rmSync(temp, { recursive: true, force: true });
}

console.log("launch-evidence-bundle: validator tests passed");
