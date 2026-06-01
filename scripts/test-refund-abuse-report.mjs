#!/usr/bin/env node
/**
 * Unit tests for the T32 refund/abuse report validator.
 */

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { templateRefundAbuseReport, validateRefundAbuseReport } from "./validate-refund-abuse-report.mjs";

const valid = templateRefundAbuseReport();
valid.generatedAt = "2026-06-01T00:00:00.000Z";

assert.deepEqual(validateRefundAbuseReport(valid), { ok: true, errors: [] });

{
  const broken = structuredClone(valid);
  broken.refundCasesCovered = broken.refundCasesCovered.filter((item) => item !== "stripe_chargeback");
  const result = validateRefundAbuseReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("stripe_chargeback")));
}

{
  const broken = structuredClone(valid);
  broken.entitlementRemovedWithinReconciliationWindow = false;
  const result = validateRefundAbuseReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("entitlementRemovedWithinReconciliationWindow must be true"));
}

{
  const broken = structuredClone(valid);
  broken.suspendedUserDeniedSurfaces = broken.suspendedUserDeniedSurfaces.filter((item) => item !== "remote_mcp");
  const result = validateRefundAbuseReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("remote_mcp")));
}

{
  const broken = structuredClone(valid);
  broken.userQuotaDailyRefreshLimit = "30";
  const result = validateRefundAbuseReport(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("userQuotaDailyRefreshLimit must be 5"));
}

const temp = mkdtempSync(join(tmpdir(), "openburnbar-refund-abuse-"));
try {
  const validPath = join(temp, "refund-abuse-report.json");
  writeFileSync(validPath, JSON.stringify(valid, null, 2));
  const okRun = spawnSync(process.execPath, ["scripts/validate-refund-abuse-report.mjs", validPath], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.equal(okRun.status, 0, okRun.stderr || okRun.stdout);
  assert.match(okRun.stdout, /"ok": true/);

  const badPath = join(temp, "bad.json");
  const bad = structuredClone(valid);
  bad.remoteMcpGrantsRevoked = false;
  writeFileSync(badPath, JSON.stringify(bad, null, 2));
  const badRun = spawnSync(process.execPath, ["scripts/validate-refund-abuse-report.mjs", badPath], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.notEqual(badRun.status, 0);
  assert.match(badRun.stderr, /remoteMcpGrantsRevoked must be true/);
} finally {
  rmSync(temp, { recursive: true, force: true });
}

console.log("refund-abuse-report: validator tests passed");
