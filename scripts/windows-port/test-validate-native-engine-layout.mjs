#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { validateNativeEngineLayout, REQUIRED_RESOURCE_BUNDLES } from "./validate-native-engine-layout.mjs";

function writeFixture() {
  const root = mkdtempSync(join(tmpdir(), "obb-native-layout-"));
  const engine = join(root, "OpenBurnBarCoreCAbi.dll");
  writeFileSync(engine, "engine");
  const resources = REQUIRED_RESOURCE_BUNDLES.map((bundleName, index) => {
    const bundle = join(root, bundleName);
    mkdirSync(bundle);
    const resource = join(bundle, index === 0 ? "MiningPickIcon.svg" : "secret-pattern-corpus.json");
    writeFileSync(resource, '{"schemaVersion":1}\n');
    return { bundleName, bundle, resource };
  });
  const files = [
    { path: engine, fileName: "OpenBurnBarCoreCAbi.dll" },
    ...resources.map(({ bundleName, resource }) => ({
      path: resource,
      fileName: `${bundleName}/${resource.split(/[\\/]/).at(-1)}`,
    })),
  ].map(({ path, fileName }) => ({
    fileName,
    sha256: createHash("sha256").update(readFileSync(path)).digest("hex"),
    sizeBytes: readFileSync(path).length,
  }));
  writeFileSync(join(root, "native-engine-manifest.json"), JSON.stringify({
    schemaVersion: 1,
    engine: "OpenBurnBarCoreCAbi.dll",
    files,
  }));
  return { root, resources };
}

test("accepts a published engine with the resource bundle", () => {
  const { root } = writeFixture();
  const result = validateNativeEngineLayout(root);
  assert.deepEqual(result, { ok: true, errors: [] });
});

test("rejects a published engine when either resource bundle is missing", () => {
  for (const missingBundle of REQUIRED_RESOURCE_BUNDLES) {
    const { root, resources } = writeFixture();
    const bundle = resources.find(({ bundleName }) => bundleName === missingBundle).bundle;
    rmSync(bundle, { recursive: true, force: true });
    const result = validateNativeEngineLayout(root);
    assert.equal(result.ok, false);
    assert.match(result.errors.join("\n"), new RegExp(missingBundle));
    rmSync(root, { recursive: true, force: true });
  }
});
