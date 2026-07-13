#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { validateNativeEngineLayout, REQUIRED_RESOURCE_BUNDLE } from "./validate-native-engine-layout.mjs";

function writeFixture() {
  const root = mkdtempSync(join(tmpdir(), "obb-native-layout-"));
  const bundle = join(root, REQUIRED_RESOURCE_BUNDLE);
  mkdirSync(bundle);
  const engine = join(root, "OpenBurnBarCoreCAbi.dll");
  const resource = join(bundle, "catalog.json");
  writeFileSync(engine, "engine");
  writeFileSync(resource, '{"schemaVersion":1}\n');
  const files = [engine, resource].map((path) => ({
    fileName: path === engine ? "OpenBurnBarCoreCAbi.dll" : `${REQUIRED_RESOURCE_BUNDLE}/catalog.json`,
    sha256: createHash("sha256").update(readFileSync(path)).digest("hex"),
    sizeBytes: readFileSync(path).length,
  }));
  writeFileSync(join(root, "native-engine-manifest.json"), JSON.stringify({
    schemaVersion: 1,
    engine: "OpenBurnBarCoreCAbi.dll",
    files,
  }));
  return { root, bundle };
}

test("accepts a published engine with the resource bundle", () => {
  const { root } = writeFixture();
  const result = validateNativeEngineLayout(root);
  assert.deepEqual(result, { ok: true, errors: [] });
});

test("rejects a published engine without the resource bundle", () => {
  const { root, bundle } = writeFixture();
  rmSync(bundle, { recursive: true, force: true });
  const result = validateNativeEngineLayout(root);
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /resource bundle|manifest files/);
});
