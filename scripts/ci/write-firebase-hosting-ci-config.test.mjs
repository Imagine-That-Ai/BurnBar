#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const generator = resolve(repoRoot, "scripts/ci/write-firebase-hosting-ci-config.mjs");

function generate(args) {
  return spawnSync(process.execPath, [generator, ...args], {
    cwd: repoRoot,
    encoding: "utf8",
  });
}

test("firestore mode binds an explicit staging bucket without default discovery", () => {
  const directory = mkdtempSync(join(tmpdir(), "firebase-ci-config-"));
  try {
    const output = join(directory, "firebase-firestore.ci.json");
    const bucket = "burnbar-staging.firebasestorage.app";
    const result = generate([
      "--mode",
      "firestore",
      "--storage-bucket",
      bucket,
      "--output",
      output,
      "--check",
    ]);
    assert.equal(result.status, 0, result.stderr);

    const config = JSON.parse(readFileSync(output, "utf8"));
    assert.ok(Array.isArray(config.storage));
    assert.equal(config.storage.length, 1);
    assert.equal(config.storage[0].bucket, bucket);
    assert.ok(config.storage[0].rules.endsWith("/storage.rules"));
    assert.equal(JSON.stringify(config).includes("predeploy"), false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("firestore mode preserves production object form without an explicit bucket", () => {
  const directory = mkdtempSync(join(tmpdir(), "firebase-ci-config-"));
  try {
    const output = join(directory, "firebase-firestore.ci.json");
    const result = generate(["--mode", "firestore", "--output", output, "--check"]);
    assert.equal(result.status, 0, result.stderr);

    const config = JSON.parse(readFileSync(output, "utf8"));
    assert.equal(Array.isArray(config.storage), false);
    assert.equal(config.storage.bucket, undefined);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("explicit bucket names fail closed on invalid input", () => {
  const result = generate([
    "--mode",
    "firestore",
    "--storage-bucket",
    "https://Invalid/Bucket",
    "--output",
    join(tmpdir(), "must-not-write-firebase-config.json"),
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /valid lowercase Cloud Storage bucket name/);
});
