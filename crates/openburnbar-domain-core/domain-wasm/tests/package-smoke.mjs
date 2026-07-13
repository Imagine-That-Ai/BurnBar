import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { fileURLToPath } from "node:url";
import path from "node:path";

const packageDirectory = process.argv[2];
if (!packageDirectory) {
  throw new Error("generated Wasm package directory argument is required");
}

const modulePath = path.join(packageDirectory, "openburnbar_domain_core.js");
const wasmPath = path.join(packageDirectory, "openburnbar_domain_core_bg.wasm");
const domainCore = await import(pathToFileURL(modulePath).href);
const wasmBytes = await readFile(wasmPath);
domainCore.initSync({ module: wasmBytes });

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const fixturePath = path.resolve(
  testDirectory,
  "../../../../tests/fixtures/domain-core/cloudvault/v1/cloudvault-deterministic-kat.json",
);
const fixture = JSON.parse(await readFile(fixturePath, "utf8"));
assert.equal(fixture.schema, "openburnbar.domain-core.cloudvault.deterministic.v1");

for (const vector of fixture.aad) {
  assert.equal(
    domainCore.cloudVaultAadV2(
      vector.uid,
      vector.collection,
      vector.docID,
      vector.field,
      vector.schemaVersion,
      vector.purpose,
    ),
    vector.v2,
  );
  assert.equal(
    domainCore.cloudVaultAadV1(
      vector.uid,
      vector.collection,
      vector.docID,
      vector.field,
      vector.schemaVersion,
      vector.purpose,
    ),
    vector.v1,
  );
}

for (const vector of fixture.sha256) {
  assert.equal(domainCore.cloudVaultSha256Hex(Buffer.from(vector.dataHex, "hex")), vector.hex);
}

for (const vector of fixture.vaultKeyID) {
  assert.equal(domainCore.cloudVaultKeyId(Buffer.from(vector.keyHex, "hex")), vector.value);
}

const purposeByLabel = {
  "blob-integrity": domainCore.CloudVaultHashPurpose.BlobIntegrity,
  "session-body": domainCore.CloudVaultHashPurpose.SessionBody,
  "session-chunk": domainCore.CloudVaultHashPurpose.SessionChunk,
  "project-memory-content": domainCore.CloudVaultHashPurpose.ProjectMemoryContent,
};
for (const vector of fixture.keyedHashes) {
  assert.equal(
    domainCore.cloudVaultKeyedHashHex(
      Buffer.from(vector.dataHex, "hex"),
      Buffer.from(vector.keyHex, "hex"),
      purposeByLabel[vector.purpose],
    ),
    vector.hex,
  );
}

const sessionVector = fixture.keyedHashes[0];
for (const vector of fixture.expectedSessionBodyHash) {
  assert.equal(
    domainCore.cloudVaultExpectedSessionBodyHash(
      Buffer.from(sessionVector.dataHex, "hex"),
      Buffer.from(sessionVector.keyHex, "hex"),
      vector.bodyHashVersion,
    ),
    vector.hex,
  );
}

assert.throws(
  () => domainCore.cloudVaultKeyId(new Uint8Array(31)),
  /invalid_key_length/,
);
assert.throws(
  () => domainCore.cloudVaultAadV2("user|alice", "cloudSessions", "doc_123", "title", 2),
  /invalid_aad_part/,
);
assert.throws(
  () =>
    domainCore.cloudVaultExpectedSessionBodyHash(
      Buffer.from(sessionVector.dataHex, "hex"),
      Buffer.from(sessionVector.keyHex, "hex"),
      3,
    ),
  /unsupported_hash_version/,
);

const pricingFixturePath = path.resolve(
  testDirectory,
  "../../../../tests/fixtures/domain-core/pricing/v1/pricing-kat.json",
);
const pricingFixture = JSON.parse(await readFile(pricingFixturePath, "utf8"));
assert.equal(pricingFixture.schema, "openburnbar.domain-core.pricing.v1");
for (const vector of pricingFixture.costVectors) {
  const rates = vector.rates;
  const buckets = vector.buckets;
  assert.equal(
    domainCore.calculateTokenCost(
      new Float64Array([
        rates.inputPerMToken,
        rates.outputPerMToken,
        rates.cacheCreationPerMToken ?? Number.NaN,
        rates.cacheReadPerMToken,
      ]),
      new Float64Array([
        buckets.inputTokens,
        buckets.outputTokens,
        buckets.cacheCreationTokens,
        buckets.cacheReadTokens,
      ]),
    ),
    vector.expectedCostUsd,
  );
}
for (const vector of pricingFixture.legacyKimiVectors) {
  assert.equal(domainCore.isLegacyKimiWireEvent(vector.provider, vector.model), vector.isLegacy);
  if (vector.expected) {
    const result = domainCore.priceLegacyKimiWireEvent(
      vector.buckets.inputTokens,
      vector.buckets.outputTokens,
      vector.buckets.cacheCreationTokens,
      vector.buckets.cacheReadTokens,
    );
    assert.equal(domainCore.legacyKimiWireModel(), vector.expected.model);
    assert.deepEqual(Array.from(result), [vector.expected.totalTokens, vector.expected.costUsd]);
  }
}

console.log("domain-core Wasm generated-package smoke test passed");
