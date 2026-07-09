import { strict as assert } from "node:assert";
import { resolve } from "node:path";
import test from "node:test";

import { buildValidationMatrix } from "./community-permission-validation.mjs";

const FIXED_EVIDENCE_DIR = "/tmp/community-permission-evidence";

function matrixOptions(overrides = {}) {
  return {
    platforms: ["android", "ios", "macos", "windows"],
    modes: ["denied", "granted", "unavailable"],
    execute: false,
    json: false,
    androidPackage: "com.openburnbar",
    appleBundleId: "ai.burnbar.OpenBurnBar",
    iosBundleId: "ai.burnbar.OpenBurnBarMobile",
    windowsAumid: "OpenBurnBar.App_8wekyb3d8bbwe!App",
    device: "",
    evidenceDir: FIXED_EVIDENCE_DIR,
    ...overrides,
  };
}

test("buildValidationMatrix covers required platform/mode pairs", () => {
  const matrix = buildValidationMatrix(matrixOptions());
  const keys = new Set(matrix.scenarios.map((s) => `${s.platform}/${s.mode}`));

  assert.equal(matrix.scenarios.length, 12);
  assert.ok(keys.has("android/denied"));
  assert.ok(keys.has("android/granted"));
  assert.ok(keys.has("ios/denied"));
  assert.ok(keys.has("ios/granted"));
  assert.ok(keys.has("macos/denied"));
  assert.ok(keys.has("macos/granted"));
  assert.ok(keys.has("windows/denied"));
  assert.ok(keys.has("windows/unavailable"));
});

test("evidence paths are deterministic under a fixed evidence directory", () => {
  const matrix = buildValidationMatrix(matrixOptions());
  for (const scenario of matrix.scenarios) {
    assert.deepEqual(scenario.evidence, [
      resolve(FIXED_EVIDENCE_DIR, `${scenario.platform}-${scenario.mode}.png`),
      ...(scenario.platform === "android"
        ? [resolve(FIXED_EVIDENCE_DIR, `${scenario.platform}-${scenario.mode}.logcat.txt`)]
        : []),
    ]);
  }
});

test("windows unavailable scenario forbids inventing a raw city fallback", () => {
  const matrix = buildValidationMatrix(matrixOptions());
  const scenario = matrix.scenarios.find((s) => s.platform === "windows" && s.mode === "unavailable");
  assert.ok(scenario);
  const joined = JSON.stringify(scenario);
  assert.match(joined, /city tier falls back to broader boards/i);
  assert.doesNotMatch(joined, /inventing a city/i);
});