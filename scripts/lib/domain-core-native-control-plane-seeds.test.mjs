import assert from "node:assert/strict";
import { lstatSync, readFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { NATIVE_RELEASE_CONTROL_PLANE_SEEDS } from "./domain-core-native-control-plane-seeds.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const EXECUTABLE_REFERENCE =
  /(?:^|[\s"'(])((?:scripts|tools)\/[A-Za-z0-9_./-]+\.(?:js|mjs|py|sh))/gmu;
const MODULE_IMPORT = /from\s+["'](\.\.?\/[A-Za-z0-9_./-]+\.mjs)["']/gmu;

test("native control-plane seeds are sorted, unique, regular repo files", () => {
  assert.deepEqual(
    NATIVE_RELEASE_CONTROL_PLANE_SEEDS,
    [...NATIVE_RELEASE_CONTROL_PLANE_SEEDS].sort(),
  );
  assert.equal(
    new Set(NATIVE_RELEASE_CONTROL_PLANE_SEEDS).size,
    NATIVE_RELEASE_CONTROL_PLANE_SEEDS.length,
  );
  for (const path of NATIVE_RELEASE_CONTROL_PLANE_SEEDS) {
    assert.equal(path.startsWith("/") || path.includes(".."), false, path);
    const stat = lstatSync(resolve(ROOT, path));
    assert.equal(stat.isFile(), true, path);
    assert.equal(stat.isSymbolicLink(), false, path);
  }
});

test("every executable referenced by native release workflows is seeded", () => {
  const seeds = new Set(NATIVE_RELEASE_CONTROL_PLANE_SEEDS);
  for (const workflow of [
    ".github/workflows/release.yml",
    ".github/workflows/openburnbar-release-windows.yml",
  ]) {
    const source = readFileSync(resolve(ROOT, workflow), "utf8");
    for (const match of source.matchAll(EXECUTABLE_REFERENCE)) {
      assert.equal(seeds.has(match[1]), true, `${workflow}: ${match[1]}`);
    }
  }
});

test("seeded JavaScript release executables include their complete relative import closure", () => {
  const seeds = new Set(NATIVE_RELEASE_CONTROL_PLANE_SEEDS);
  const pending = [...seeds].filter((path) => path.endsWith(".mjs"));
  const visited = new Set();
  while (pending.length > 0) {
    const path = pending.pop();
    if (visited.has(path)) continue;
    visited.add(path);
    const source = readFileSync(resolve(ROOT, path), "utf8");
    for (const match of source.matchAll(MODULE_IMPORT)) {
      const imported = relative(
        ROOT,
        resolve(dirname(resolve(ROOT, path)), match[1]),
      );
      assert.equal(seeds.has(imported), true, `${path}: ${imported}`);
      if (!visited.has(imported)) pending.push(imported);
    }
  }
});

test("native observer source and immutable signer pins cannot fall out of the seed set", () => {
  const seeds = new Set(NATIVE_RELEASE_CONTROL_PLANE_SEEDS);
  for (const required of [
    "AgentLens/App/AgentLensApp.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarCore/DomainCoreReleaseIdentityReporter.swift",
    "android/openburnbar-domain-core/src/androidTest/java/com/openburnbar/domaincore/DomainCoreNativeLoadTest.kt",
    "config/android-upload-certificate.sha256",
    "config/apple-release-signing-policy.json",
    "scripts/ci/create-apple-android-release-publication.mjs",
    "scripts/ci/hydrate-apple-android-release-evidence.mjs",
    "scripts/ci/publish-apple-android-release.mjs",
    "scripts/ci/verify-domain-core-native-release-artifact.sh",
    "scripts/ci/verify-domain-core-android-universal-artifact.mjs",
    "scripts/ci/verify-domain-core-observed-identity.mjs",
    "windows/tests/quota/DomainCoreQuotaBridgeTests.cs",
  ]) {
    assert.equal(seeds.has(required), true, required);
  }
});
