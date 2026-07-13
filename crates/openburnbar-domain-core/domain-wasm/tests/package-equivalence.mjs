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
const recoveryKey = "abc-defg-hjkm-npq-rst-vwxyz-23456789";
const publicKey = Buffer.from(
  "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" +
  "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
  "hex",
);
const sharedSecret = Uint8Array.from({ length: 32 }, (_, index) => 0xa0 + index);
const searchHashes = (api) => {
  const result = api.cloudVaultSearch(
    api.CloudVaultSearchOperation.Semantic,
    "X ads API campaigns credentials",
    key,
    24,
  );
  const hashes = Array.from({ length: result.hashCount }, (_, index) => result.hashAt(index));
  result.free();
  return hashes;
};
const calls = [
  (api) => api.cloudVaultSha256Hex(data),
  (api) => api.cloudVaultKeyId(key),
  (api) => api.cloudVaultKeyedHashHex(data, key, api.CloudVaultHashPurpose.BlobIntegrity),
  (api) => api.cloudVaultExpectedSessionBodyHash(data, key, 2),
  (api) => api.cloudVaultAadV1("uid", "sessions", "doc", "body", 2),
  (api) => api.cloudVaultAadV2("uid", "sessions", "doc", "body", 2, "sync"),
  (api) => api.cloudVaultBase64Encode(data),
  (api) => api.cloudVaultAesGcmSealCombined(data, key, new Uint8Array(12), data),
  (api) => api.cloudVaultNormalizeRecoveryKey(recoveryKey),
  (api) => api.cloudVaultRecoveryWrappingKey(recoveryKey),
  (api) => api.cloudVaultRecoveryVerificationHash(recoveryKey),
  (api) => api.cloudVaultEscrowWrappingKey(sharedSecret),
  (api) => api.cloudVaultEscrowSeal(data, publicKey, sharedSecret, new Uint8Array(12)),
  searchHashes,
];
for (const call of calls) {
  assert.deepEqual(call(committed.module), call(generated.module));
}

console.log("domain-core Wasm packages are API- and behavior-equivalent");
