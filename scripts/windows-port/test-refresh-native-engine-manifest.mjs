#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { refreshNativeEngineManifest, REQUIRED_RESOURCE_BUNDLE } from "./refresh-native-engine-manifest.mjs";
import { validateNativeEngineLayout } from "./validate-native-engine-layout.mjs";

function createFixture() {
  const root = mkdtempSync(join(tmpdir(), "obb-native-manifest-"));
  const bundle = join(root, REQUIRED_RESOURCE_BUNDLE);
  mkdirSync(bundle);
  writeFileSync(join(root, "OpenBurnBarCoreCAbi.dll"), "signed engine bytes");
  writeFileSync(join(bundle, "catalog.json"), '{"schemaVersion":1}\n');
  writeFileSync(
    join(root, "native-engine-manifest.json"),
    JSON.stringify({
      schemaVersion: 1,
      engine: "OpenBurnBarCoreCAbi.dll",
      files: [
        { fileName: "OpenBurnBarCoreCAbi.dll", sha256: "0".repeat(64), sizeBytes: 1 },
        { fileName: `${REQUIRED_RESOURCE_BUNDLE}/catalog.json`, sha256: "0".repeat(64), sizeBytes: 1 },
      ],
    }),
  );
  return root;
}

test("refreshes hashes and sizes after signing mutates the native engine", () => {
  const root = createFixture();
  try {
    const manifest = refreshNativeEngineManifest(root);
    const engineBytes = readFileSync(join(root, "OpenBurnBarCoreCAbi.dll"));
    const engineEntry = manifest.files.find((entry) => entry.fileName === "OpenBurnBarCoreCAbi.dll");
    assert.equal(engineEntry.sha256, createHash("sha256").update(engineBytes).digest("hex"));
    assert.equal(engineEntry.sizeBytes, engineBytes.byteLength);
    assert.deepEqual(validateNativeEngineLayout(root), { ok: true, errors: [] });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("fails closed when a manifest file is missing", () => {
  const root = createFixture();
  try {
    rmSync(join(root, "OpenBurnBarCoreCAbi.dll"));
    assert.throws(() => refreshNativeEngineManifest(root), /manifest file is missing/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("fails closed on an unsafe manifest path", () => {
  const root = createFixture();
  try {
    const manifestPath = join(root, "native-engine-manifest.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.files[0].fileName = "../OpenBurnBarCoreCAbi.dll";
    writeFileSync(manifestPath, JSON.stringify(manifest));
    assert.throws(() => refreshNativeEngineManifest(root), /safe relative path/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
