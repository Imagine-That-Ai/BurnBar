import assert from "node:assert/strict";
import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { NATIVE_RELEASE_CONTROL_PLANE_SEEDS } from "./domain-core-native-control-plane-seeds.mjs";
import { discoverControlPlaneClosure } from "./domain-core-native-control-plane-discovery.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const WORKFLOWS = [
  ".github/workflows/release.yml",
  ".github/workflows/openburnbar-release-windows.yml",
];

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

test("every release workflow dependency and recursive local child is seeded", () => {
  const seeds = new Set(NATIVE_RELEASE_CONTROL_PLANE_SEEDS);
  const closure = discoverControlPlaneClosure(ROOT, WORKFLOWS);
  for (const path of closure) {
    assert.equal(seeds.has(path), true, `unseeded release dependency: ${path}`);
  }
});

test("discovery follows dot-slash, side-effect, dynamic, require, and child execution references", () => {
  const root = mkdtempSync(join(tmpdir(), "native-control-plane-discovery-"));
  try {
    mkdirSync(join(root, ".github/workflows"), { recursive: true });
    mkdirSync(join(root, "scripts/lib"), { recursive: true });
    mkdirSync(join(root, "config"), { recursive: true });
    writeFileSync(
      join(root, ".github/workflows/release.yml"),
      'run: node ./scripts/root.mjs && bash scripts/child.sh\n',
    );
    writeFileSync(
      join(root, "scripts/root.mjs"),
      [
        'import "./side.js";',
        'await import("./dynamic.mjs");',
        'require("./common.cjs");',
        'spawnSync("python3", ["scripts/child.py"]);',
        'readFileSync("config/policy.json");',
      ].join("\n"),
    );
    for (const path of [
      "scripts/side.js",
      "scripts/dynamic.mjs",
      "scripts/common.cjs",
      "scripts/child.py",
      "scripts/child.sh",
      "config/policy.json",
    ]) {
      mkdirSync(dirname(join(root, path)), { recursive: true });
      writeFileSync(join(root, path), "{}\n");
    }
    assert.deepEqual(
      discoverControlPlaneClosure(root, [".github/workflows/release.yml"]),
      [
        ".github/workflows/release.yml",
        "config/policy.json",
        "scripts/child.py",
        "scripts/child.sh",
        "scripts/common.cjs",
        "scripts/dynamic.mjs",
        "scripts/root.mjs",
        "scripts/side.js",
      ],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
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
    "scripts/ci/verify-domain-core-observed-identity.mjs",
    "windows/tests/quota/DomainCoreQuotaBridgeTests.cs",
  ]) {
    assert.equal(seeds.has(required), true, required);
  }
});
