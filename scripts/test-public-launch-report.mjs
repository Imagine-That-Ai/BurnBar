#!/usr/bin/env node
/**
 * Unit tests for the T31 public launch report validator.
 */

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import {
  templatePublicLaunchReport,
  validatePublicLaunchReport,
} from "./validate-public-launch-report.mjs";

const valid = templatePublicLaunchReport();
valid.generatedAt = "2026-06-01T00:00:00.000Z";

assert.deepEqual(validatePublicLaunchReport(valid), { ok: true, errors: [] });

{
  const broken = structuredClone(valid);
  broken.remoteConfig.public_paid_launch = "false";
  const result = validatePublicLaunchReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("remoteConfig.public_paid_launch must be true"));
}

{
  const broken = structuredClone(valid);
  broken.githubRelease.draft = true;
  const result = validatePublicLaunchReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("githubRelease.draft must be false"));
}

{
  const broken = structuredClone(valid);
  broken.website.pricingHTTPStatus = 503;
  const result = validatePublicLaunchReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("website.pricingHTTPStatus must be 200"));
}

{
  const broken = structuredClone(valid);
  broken.launchChannelsPosted = broken.launchChannelsPosted.filter((channel) => channel !== "product_hunt");
  const result = validatePublicLaunchReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("product_hunt")));
}

{
  const broken = structuredClone(valid);
  broken.evidence = broken.evidence.filter((item) => item.kind !== "website-pricing-capture");
  const result = validatePublicLaunchReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("evidence must include website-pricing-capture"));
}

const temp = mkdtempSync(join(tmpdir(), "openburnbar-public-launch-"));
try {
  const validPath = join(temp, "public-launch-report.json");
  writeFileSync(validPath, JSON.stringify(valid, null, 2));
  const okRun = spawnSync(process.execPath, ["scripts/validate-public-launch-report.mjs", validPath], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.equal(okRun.status, 0, okRun.stderr || okRun.stdout);
  assert.match(okRun.stdout, /"ok": true/);

  const badPath = join(temp, "bad.json");
  const bad = structuredClone(valid);
  bad.monitoringDashboardsLive = false;
  writeFileSync(badPath, JSON.stringify(bad, null, 2));
  const badRun = spawnSync(process.execPath, ["scripts/validate-public-launch-report.mjs", badPath], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.notEqual(badRun.status, 0);
  assert.match(badRun.stderr, /monitoringDashboardsLive must be true/);
} finally {
  rmSync(temp, { recursive: true, force: true });
}

console.log("public-launch-report: validator tests passed");
