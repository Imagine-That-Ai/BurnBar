const assert = require("node:assert/strict");
const path = require("node:path");

const [committedDir, generatedDir] = process.argv.slice(2);
if (!committedDir || !generatedDir) {
  throw new Error("usage: node-package-equivalence.cjs <committed> <generated>");
}

const committed = require(path.join(committedDir, "openburnbar_domain_core.js"));
const generated = require(path.join(generatedDir, "openburnbar_domain_core.js"));
assert.deepEqual(Object.keys(committed).sort(), Object.keys(generated).sort());

const calls = [
  (api) => api.domainCoreAbiVersion(),
  (api) => api.domainCoreVersion(),
  (api) => api.domainCoreSourceFingerprint(),
  (api) => api.isLegacyKimiWireEvent("KIMI", "chatcmpl-123"),
  (api) => api.calculateTokenCostNanoUsd(
    new BigUint64Array([3_000_000_000n, 15_000_000_000n, 0n, 500_000_000n]),
    new BigUint64Array([500n, 200n, 100n, 300n]),
    false,
  ),
  (api) => Array.from(api.priceLegacyKimiWireEvent(1000n, 300n, 200n, 100n)),
];
for (const call of calls) assert.deepEqual(call(committed), call(generated));

console.log("domain-core Node Wasm packages are API- and behavior-equivalent");
