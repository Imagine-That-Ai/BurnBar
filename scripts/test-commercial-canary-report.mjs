#!/usr/bin/env node
/**
 * Unit tests for the T30 commercial canary validator.
 */

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import {
  templateCommercialCanaryReport,
  validateCommercialCanaryReport,
} from "./validate-commercial-canary-report.mjs";

const valid = templateCommercialCanaryReport();
valid.generatedAt = "2026-06-01T00:00:00.000Z";

assert.deepEqual(validateCommercialCanaryReport(valid), { ok: true, errors: [] });

{
  const broken = structuredClone(valid);
  broken.appCheckDeniedPercent = 1;
  const result = validateCommercialCanaryReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("appCheckDeniedPercent must be < 1"));
}

{
  const broken = structuredClone(valid);
  broken.entitlementFailurePercent = 0.5;
  const result = validateCommercialCanaryReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("entitlementFailurePercent must be < 0.5"));
}

{
  const broken = structuredClone(valid);
  broken.mediaProjectedSpendUSD = 601;
  broken.computerUseProjectedSpendUSD = 1501;
  const result = validateCommercialCanaryReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("mediaProjectedSpendUSD must be <= 600"));
  assert.ok(result.errors.includes("computerUseProjectedSpendUSD must be <= 1500"));
}

{
  const broken = structuredClone(valid);
  broken.remoteConfig.public_paid_launch = "true";
  const result = validateCommercialCanaryReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("remoteConfig.public_paid_launch must be false"));
}

{
  const broken = structuredClone(valid);
  broken.evidence = broken.evidence.filter((item) => item.kind !== "incident-log");
  const result = validateCommercialCanaryReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("evidence must include incident-log"));
}

const temp = mkdtempSync(join(tmpdir(), "openburnbar-canary-report-"));
try {
  const validPath = join(temp, "canary-report.json");
  writeFileSync(validPath, JSON.stringify(valid, null, 2));
  const okRun = spawnSync(process.execPath, ["scripts/validate-commercial-canary-report.mjs", validPath], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.equal(okRun.status, 0, okRun.stderr || okRun.stdout);
  assert.match(okRun.stdout, /"ok": true/);

  const badPath = join(temp, "bad.json");
  const bad = structuredClone(valid);
  bad.noOpenP0P1 = false;
  writeFileSync(badPath, JSON.stringify(bad, null, 2));
  const badRun = spawnSync(process.execPath, ["scripts/validate-commercial-canary-report.mjs", badPath], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.notEqual(badRun.status, 0);
  assert.match(badRun.stderr, /noOpenP0P1 must be true/);
} finally {
  rmSync(temp, { recursive: true, force: true });
}

console.log("commercial-canary-report: validator tests passed");
