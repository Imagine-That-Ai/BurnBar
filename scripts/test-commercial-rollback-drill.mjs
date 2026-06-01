#!/usr/bin/env node
/**
 * Unit tests for the T33 commercial rollback drill validator.
 */

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import {
  templateCommercialRollbackDrill,
  validateCommercialRollbackDrill,
} from "./validate-commercial-rollback-drill.mjs";

const valid = templateCommercialRollbackDrill();
valid.generatedAt = "2026-06-01T00:00:00.000Z";

assert.deepEqual(validateCommercialRollbackDrill(valid), { ok: true, errors: [] });

{
  const broken = structuredClone(valid);
  broken.remoteConfigPatch.media_kill_switch = "false";
  const result = validateCommercialRollbackDrill(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("remoteConfigPatch.media_kill_switch must be true"));
}

{
  const broken = structuredClone(valid);
  broken.remoteConfigPublished = true;
  const result = validateCommercialRollbackDrill(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("remoteConfigPublished must be false for dry-run rollback evidence"));
}

{
  const broken = structuredClone(valid);
  broken.controls = broken.controls.filter((control) => control.id !== "stripe_console_access");
  const result = validateCommercialRollbackDrill(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.includes("missing control: stripe_console_access"));
}

{
  const broken = structuredClone(valid);
  broken.triggersCovered = broken.triggersCovered.filter((trigger) => trigger !== "security_incident");
  const result = validateCommercialRollbackDrill(broken);
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("security_incident")));
}

const temp = mkdtempSync(join(tmpdir(), "openburnbar-rollback-drill-"));
try {
  const validPath = join(temp, "rollback-drill.json");
  writeFileSync(validPath, JSON.stringify(valid, null, 2));
  const okRun = spawnSync(process.execPath, ["scripts/validate-commercial-rollback-drill.mjs", validPath], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.equal(okRun.status, 0, okRun.stderr || okRun.stdout);
  assert.match(okRun.stdout, /"ok": true/);

  const badPath = join(temp, "bad.json");
  const bad = structuredClone(valid);
  bad.killSwitchHaltVerified = false;
  writeFileSync(badPath, JSON.stringify(bad, null, 2));
  const badRun = spawnSync(process.execPath, ["scripts/validate-commercial-rollback-drill.mjs", badPath], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.notEqual(badRun.status, 0);
  assert.match(badRun.stderr, /killSwitchHaltVerified must be true/);
} finally {
  rmSync(temp, { recursive: true, force: true });
}

console.log("commercial-rollback-drill: validator tests passed");
