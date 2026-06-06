import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { PLATFORM_CRYPTO_CAPABILITIES, LIBSIGNAL_BEARING_MODELS } from "./index.js";

// Bind the JS crypto matrix to the canonical machine-readable manifest, NOT to a
// private literal. This closes the JS<->JSON drift gap: editing the JS matrix to
// a different value (even with its own self-test updated) now fails here unless
// docs/security/crypto-architecture-policy.json is changed in lockstep. The
// Python checker independently binds that JSON to its hardcoded copy, so this
// test completes the JS == JSON == Python chain.
const manifestPath = fileURLToPath(
  new URL("../../../docs/security/crypto-architecture-policy.json", import.meta.url),
);
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

test("JS PLATFORM_CRYPTO_CAPABILITIES equals the canonical crypto-architecture-policy.json matrix", () => {
  assert.deepStrictEqual(
    PLATFORM_CRYPTO_CAPABILITIES,
    manifest.platforms,
    "JS matrix drifted from docs/security/crypto-architecture-policy.json (the canonical source of truth)",
  );
});

test("JS LIBSIGNAL_BEARING_MODELS equals the manifest libsignalBearingModels", () => {
  assert.deepStrictEqual(
    LIBSIGNAL_BEARING_MODELS,
    manifest.libsignalBearingModels,
    "JS libsignal-bearing model list drifted from the manifest",
  );
});
