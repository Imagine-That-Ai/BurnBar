#!/usr/bin/env node
/**
 * Unit tests for the GTM T29 cross-channel paid-path matrix validator.
 */

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import {
  templateMatrix,
  validateCrossChannelPaidPathMatrix,
} from "./validate-cross-channel-paid-path-matrix.mjs";

const valid = templateMatrix();
valid.generatedAt = "2026-06-01T00:00:00.000Z";
for (const row of valid.rows) {
  row.evidence = [{ kind: "paid-proof", path: `launch-evidence/${row.id}.json` }];
}

assert.deepEqual(validateCrossChannelPaidPathMatrix(valid), { ok: true, errors: [] });

{
  const broken = structuredClone(valid);
  broken.rows = broken.rows.filter((row) => row.id !== "google_play_cloud_pro_topup");
  const result = validateCrossChannelPaidPathMatrix(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("missing row: google_play_cloud_pro_topup"));
}

{
  const broken = structuredClone(valid);
  const row = broken.rows.find((item) => item.id === "legacy_hosted_quota_group_a_only");
  row.featureGates.groupB = true;
  const result = validateCrossChannelPaidPathMatrix(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("legacy_hosted_quota_group_a_only: groupB gate mismatch"));
}

{
  const broken = structuredClone(valid);
  broken.security.clientSelfGrantDenied = false;
  for (const row of broken.rows) delete row.featureGates.clientSelfGrantDenied;
  const result = validateCrossChannelPaidPathMatrix(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("client self-grant denial evidence is required")));
}

const temp = mkdtempSync(join(tmpdir(), "openburnbar-paid-matrix-"));
try {
  const validPath = join(temp, "matrix.json");
  writeFileSync(validPath, JSON.stringify(valid, null, 2));
  const okRun = spawnSync(process.execPath, ["scripts/validate-cross-channel-paid-path-matrix.mjs", validPath], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.equal(okRun.status, 0, okRun.stderr || okRun.stdout);
  assert.match(okRun.stdout, /"ok": true/);

  const badPath = join(temp, "bad.json");
  const bad = structuredClone(valid);
  bad.rows[0].ok = false;
  writeFileSync(badPath, JSON.stringify(bad, null, 2));
  const badRun = spawnSync(process.execPath, ["scripts/validate-cross-channel-paid-path-matrix.mjs", badPath], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.notEqual(badRun.status, 0);
  assert.match(badRun.stderr, /ok must be true/);

  const stdinRun = spawnSync(
    process.execPath,
    ["scripts/validate-cross-channel-paid-path-matrix.mjs", "-"],
    {
      cwd: new URL("..", import.meta.url),
      encoding: "utf8",
      input: JSON.stringify(valid),
    },
  );
  assert.equal(stdinRun.status, 0, stdinRun.stderr || stdinRun.stdout);
} finally {
  rmSync(temp, { recursive: true, force: true });
}

console.log("cross-channel-paid-path-matrix: validator tests passed");
