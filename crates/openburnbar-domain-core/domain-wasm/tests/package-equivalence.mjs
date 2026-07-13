import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [committedDir, generatedDir] = process.argv.slice(2);
if (!committedDir || !generatedDir) {
  throw new Error("usage: package-equivalence.mjs <committed> <generated>");
}

async function load(directory) {
  const module = await import(
    `${pathToFileURL(path.join(directory, "openburnbar_domain_core.js")).href}?check=${Date.now()}`
  );
  const wasm = module.initSync({
    module: await readFile(path.join(directory, "openburnbar_domain_core_bg.wasm")),
  });
  return { module, wasm };
}

const committed = await load(committedDir);
const generated = await load(generatedDir);
assert.deepEqual(
  Object.keys(committed.module).sort(),
  Object.keys(generated.module).sort(),
  "generated JavaScript exports drifted"
);
assert.deepEqual(
  Object.keys(committed.wasm).sort(),
  Object.keys(generated.wasm).sort(),
  "generated Wasm exports drifted"
);

const key = Uint8Array.from({ length: 32 }, (_, index) => index);
const data = new TextEncoder().encode("OpenBurnBar domain-core equivalence");
const calls = [
  (api) => api.cloudVaultSha256Hex(data),
  (api) => api.cloudVaultKeyId(key),
  (api) => api.cloudVaultKeyedHashHex(data, key, api.CloudVaultHashPurpose.BlobIntegrity),
  (api) => api.cloudVaultExpectedSessionBodyHash(data, key, 2),
  (api) => api.cloudVaultAadV1("uid", "sessions", "doc", "body", 2),
  (api) => api.cloudVaultAadV2("uid", "sessions", "doc", "body", 2, "sync"),
  (api) => api.cloudVaultBase64Encode(data),
  (api) => api.cloudVaultAesGcmSealCombined(data, key, new Uint8Array(12), data),
];
for (const call of calls) {
  assert.deepEqual(call(committed.module), call(generated.module));
}

console.log("domain-core Wasm packages are API- and behavior-equivalent");
