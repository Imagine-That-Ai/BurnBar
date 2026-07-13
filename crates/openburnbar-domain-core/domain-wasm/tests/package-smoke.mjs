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

for (const vector of fixture.aesGcm) {
  const key = Buffer.from(vector.keyHex, "hex");
  const nonce = Buffer.from(vector.nonceHex, "hex");
  const plaintext = Buffer.from(vector.plaintextHex, "hex");
  const aad = Buffer.from(vector.aadHex, "hex");
  const combined = domainCore.cloudVaultAesGcmSealCombined(plaintext, key, nonce, aad);
  assert.equal(domainCore.cloudVaultBase64Encode(combined), vector.combinedBase64);
  assert.deepEqual(
    Array.from(domainCore.cloudVaultAesGcmOpenCombined(combined, key, aad)),
    Array.from(plaintext),
  );
  assert.deepEqual(
    Array.from(domainCore.cloudVaultBase64DecodeStrict(vector.combinedBase64)),
    Array.from(combined),
  );
}

const recovery = fixture.recovery;
assert.equal(
  domainCore.cloudVaultNormalizeRecoveryKey(recovery.formattedKey),
  recovery.normalizedKey,
);
assert.equal(
  Buffer.from(domainCore.cloudVaultRecoveryWrappingKey(recovery.formattedKey)).toString("hex"),
  recovery.wrappingKeyHex,
);
assert.equal(
  domainCore.cloudVaultRecoveryVerificationHash(recovery.formattedKey),
  recovery.verificationHash,
);
assert.throws(
  () => domainCore.cloudVaultNormalizeRecoveryKey(recovery.unicodeFormattedKey),
);
assert.throws(
  () => domainCore.cloudVaultRecoveryWrappingKey(recovery.unicodeFormattedKey),
);
const recoveryWrapped = domainCore.cloudVaultRecoveryWrapVaultKey(
  Buffer.from(recovery.vaultKeyHex, "hex"),
  recovery.formattedKey,
  Buffer.from(recovery.nonceHex, "hex"),
);
assert.equal(Buffer.from(recoveryWrapped.combined).toString("hex"), recovery.combinedHex);
assert.equal(recoveryWrapped.verificationHash, recovery.verificationHash);
assert.equal(
  Buffer.from(
    domainCore.cloudVaultRecoveryOpenVaultKey(recoveryWrapped.combined, recovery.formattedKey),
  ).toString("hex"),
  recovery.vaultKeyHex,
);
recoveryWrapped.free();

const escrow = fixture.p256Escrow;
const publicKey = Buffer.from(escrow.ephemeralPublicKeyHex, "hex");
const sharedSecret = Buffer.from(escrow.sharedSecretHex, "hex");
const escrowNonce = Buffer.from(escrow.nonceHex, "hex");
domainCore.cloudVaultValidateP256X963PublicKey(publicKey);
assert.equal(
  Buffer.from(domainCore.cloudVaultEscrowWrappingKey(sharedSecret)).toString("hex"),
  escrow.wrappingKeyHex,
);
const escrowWire = domainCore.cloudVaultEscrowSeal(
  Buffer.from(escrow.plaintextHex, "hex"),
  publicKey,
  sharedSecret,
  escrowNonce,
);
assert.equal(Buffer.from(escrowWire).toString("hex"), escrow.wireHex);
assert.equal(
  Buffer.from(domainCore.cloudVaultEscrowOpen(escrowWire, sharedSecret)).toString("hex"),
  escrow.plaintextHex,
);
const escrowParts = domainCore.cloudVaultEscrowSplitWire(escrowWire);
assert.equal(Buffer.from(escrowParts.ephemeralPublicKey).toString("hex"), escrow.ephemeralPublicKeyHex);
assert.deepEqual(
  Array.from(domainCore.cloudVaultEscrowAssembleWire(publicKey, escrowParts.aesGcmCombined)),
  Array.from(escrowWire),
);
escrowParts.free();
const emptyEscrowWire = domainCore.cloudVaultEscrowSeal(
  new Uint8Array(),
  publicKey,
  sharedSecret,
  escrowNonce,
);
assert.equal(Buffer.from(emptyEscrowWire).toString("hex"), escrow.emptyWireHex);
assert.deepEqual(
  Array.from(domainCore.cloudVaultEscrowOpen(emptyEscrowWire, sharedSecret)),
  [],
);

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
assert.throws(
  () => domainCore.cloudVaultRecoveryOpenVaultKey(
    Buffer.from(recovery.combinedHex, "hex"),
    "ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ",
  ),
  /authentication_failed/,
);
assert.throws(
  () => domainCore.cloudVaultValidateP256X963PublicKey(new Uint8Array(65)),
  /invalid_p256_public_key/,
);

console.log("domain-core Wasm generated-package smoke test passed");
