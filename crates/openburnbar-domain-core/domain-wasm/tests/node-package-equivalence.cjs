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
  (api) => api.domainCoreVersion(),
  (api) => api.isLegacyKimiWireEvent("KIMI", "chatcmpl-123"),
  (api) => api.calculateTokenCost(new Float64Array([3, 15, Number.NaN, 0.5]), new Float64Array([500, 200, 100, 300])),
  (api) => Array.from(api.priceLegacyKimiWireEvent(1000, 300, 200, 100)),
];
for (const call of calls) assert.deepEqual(call(committed), call(generated));

console.log("domain-core Node Wasm packages are API- and behavior-equivalent");
