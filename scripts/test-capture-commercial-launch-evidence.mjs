#!/usr/bin/env node
/**
 * Regression tests for commercial launch evidence capture.
 */

import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptsDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(scriptsDir);
const script = join(scriptsDir, "capture-commercial-launch-evidence.mjs");
const root = mkdtempSync(join(tmpdir(), "openburnbar-capture-evidence-"));
const evidenceDir = join(root, "launch-evidence");
const inputPath = join(root, "proof.json");
const latestPath = join(evidenceDir, "latest-paid-proof.json");

mkdirSync(evidenceDir, { recursive: true, mode: 0o755 });
chmodSync(evidenceDir, 0o755);
writeFileSync(latestPath, "{\"stale\":true}\n", { mode: 0o644 });
chmodSync(latestPath, 0o644);
writeFileSync(inputPath, JSON.stringify({ ok: true, channel: "test" }), { mode: 0o600 });

const result = spawnSync(process.execPath, [
  script,
  "--kind",
  "paid-proof",
  "--input",
  inputPath,
  "--dir",
  evidenceDir,
], {
  cwd: repoRoot,
  encoding: "utf8",
});

assert.equal(result.status, 0, result.stderr || result.stdout);

const capture = JSON.parse(result.stdout);
assert.equal(capture.ok, true);
assert.equal(capture.kind, "paid-proof");
assert.equal(statSync(evidenceDir).mode & 0o777, 0o700);
assert.equal(statSync(capture.outputPath).mode & 0o777, 0o600);
assert.equal(statSync(capture.latestPath).mode & 0o777, 0o600);

console.log("capture-commercial-launch-evidence permission tests passed");
