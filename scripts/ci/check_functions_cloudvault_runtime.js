#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const { existsSync } = require("node:fs");
const { join, resolve } = require("node:path");

const ROOT = resolve(__dirname, "..", "..");
const EXPECTED_AAD =
  "OpenBurnBar-Signal-AAD-v1|at-rest|cloudvault|uid-1||mobile_assistant_chats|thread-1|signalEnvelope||1";

function requireBuiltFunctionsModule(relativePath) {
  const absolute = join(ROOT, relativePath);
  assert.ok(
    existsSync(absolute),
    `${relativePath} is missing; run npm run build --prefix functions before this runtime check`
  );
  return require(absolute);
}

function b64(value) {
  return Buffer.from(value, "utf8").toString("base64");
}

function strictCloudVaultEnvelope(overrides = {}) {
  const binding = {
    uid: "uid-1",
    scope: "cloudvault",
    collection: "mobile_assistant_chats",
    docId: "thread-1",
    field: "signalEnvelope",
    mode: "at-rest",
    formatVersion: 1,
    ...(overrides.binding || {}),
  };
  return {
    signalEnvelopeFormatVersion: 1,
    mode: "at-rest",
    relayEncryption: "signal-hpke-identity-seal-v1",
    ciphertextLayer: {
      payloadCiphertextB64: b64("sealed-payload-bytes"),
      payloadAADLabel: "bindingToAAD-sha256:0123456789abcdef0123456789abcdef",
      schemaVersion: 1,
      ...(overrides.ciphertextLayer || {}),
    },
    keyDelivery: {
      scheme: "signal-hpke-identity-seal-v1",
      contentKeyLength: 32,
      wraps: [
        {
          recipientKind: "device",
          recipientIdentityKeyId: "device-key-1",
          recipientIdentityKeyB64: b64("public-key-bytes-x"),
          sealedContentKeyB64: b64("sealed-content-key"),
          ...(overrides.wrap || {}),
        },
      ],
      ...(overrides.keyDelivery || {}),
    },
    binding,
    ...(overrides.envelope || {}),
  };
}

function expectedBinding(overrides = {}) {
  return {
    uid: "uid-1",
    collection: "mobile_assistant_chats",
    docId: "thread-1",
    field: "signalEnvelope",
    ...overrides,
  };
}

function loadRuntime() {
  const contracts = requireBuiltFunctionsModule("functions/node_modules/@openburnbar/signal-envelope-contracts");
  const writeGuard = requireBuiltFunctionsModule("functions/lib/signalAtRestWrite.js");
  assert.equal(typeof contracts.sanitizeCloudVaultSignalEnvelope, "function");
  assert.equal(typeof contracts.bindingToAAD, "function");
  assert.equal(typeof writeGuard.validateSignalAtRestEnvelopeForWrite, "function");
  assert.equal(typeof writeGuard.assertSignalAtRestEnvelopeForWrite, "function");
  assert.equal(writeGuard.SIGNAL_AT_REST_SCHEME, "signal-hpke-identity-seal-v1");
  assert.ok(Array.isArray(writeGuard.SIGNAL_AT_REST_REQUIRED_COLLECTIONS));
  assert.equal(typeof writeGuard.isSignalAtRestRequiredForCollection, "function");
  return { contracts, writeGuard };
}

function runSignalAtRestWriteSmoke() {
  const { contracts, writeGuard } = loadRuntime();
  const envelope = strictCloudVaultEnvelope({ envelope: { plaintext: "must be dropped by sanitizer" } });
  const result = writeGuard.validateSignalAtRestEnvelopeForWrite(envelope, expectedBinding());
  assert.equal(result.ok, true);
  assert.equal(result.aad, EXPECTED_AAD);
  assert.equal(Object.prototype.hasOwnProperty.call(result.envelope, "plaintext"), false);
  assert.equal(contracts.sanitizeCloudVaultSignalEnvelope(envelope).binding.scope, "cloudvault");

  for (const [field, expected] of [
    ["uid", expectedBinding({ uid: "other-user" })],
    ["collection", expectedBinding({ collection: "other_collection" })],
    ["docId", expectedBinding({ docId: "other-thread" })],
    ["field", expectedBinding({ field: "otherField" })],
  ]) {
    const mismatch = writeGuard.validateSignalAtRestEnvelopeForWrite(envelope, expected);
    assert.equal(mismatch.ok, false);
    assert.equal(mismatch.reason, `binding-${field.toLowerCase()}-mismatch`.replace("docid", "docid"));
  }

  assert.equal(
    writeGuard.validateSignalAtRestEnvelopeForWrite(strictCloudVaultEnvelope({ binding: { scope: "gateway" } }), expectedBinding()).ok,
    false
  );
  assert.equal(
    writeGuard.validateSignalAtRestEnvelopeForWrite(strictCloudVaultEnvelope({ binding: { mode: "transport" } }), expectedBinding()).ok,
    false
  );
  assert.equal(
    writeGuard.validateSignalAtRestEnvelopeForWrite(strictCloudVaultEnvelope({ wrap: { sealedContentKeyB64: "not base64 !!" } }), expectedBinding()).ok,
    false
  );
  assert.equal(writeGuard.isSignalAtRestRequiredForCollection("cloud_search_knowledge"), false);
  assert.equal(
    writeGuard.isSignalAtRestRequiredForCollection("cloud_search_knowledge", ["cloud_search_knowledge"]),
    true
  );
  return [
    "compiled_functions_imports_signal_at_rest_write",
    "admin_write_validator_accepts_strict_cloudvault_envelope",
    "admin_write_validator_derives_canonical_aad",
    "admin_write_validator_rejects_wrong_binding",
    "contract_sanitizer_rejects_gateway_transport_as_cloudvault",
    "sanitized_envelope_drops_plaintext_siblings",
    "signal_at_rest_policy_mirrors_registry",
    "signal_at_rest_policy_requires_enabled_collection",
  ];
}

function runPrivacyBackfillSmoke() {
  const { writeGuard } = loadRuntime();
  const plaintext = writeGuard.validateSignalAtRestEnvelopeForWrite(
    { plaintext: "secret", signalEnvelopeFormatVersion: 1 },
    expectedBinding()
  );
  assert.equal(plaintext.ok, false);
  assert.equal(plaintext.reason, "invalid-envelope-shape");
  const notObject = writeGuard.validateSignalAtRestEnvelopeForWrite("plaintext", expectedBinding());
  assert.equal(notObject.ok, false);
  assert.equal(notObject.reason, "not-an-object");
  return [
    "admin_write_validator_rejects_plaintext",
    "admin_write_validator_rejects_non_object",
  ];
}

function main() {
  const assertions = [...runSignalAtRestWriteSmoke(), ...runPrivacyBackfillSmoke()];
  assert.equal(new Set(assertions).size, assertions.length);
  console.log("PASS: compiled Functions CloudVault runtime smoke passed");
  for (const assertion of assertions) {
    console.log(`- ${assertion}`);
  }
}

module.exports = { runSignalAtRestWriteSmoke, runPrivacyBackfillSmoke };

if (require.main === module) main();
