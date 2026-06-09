#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..", "..");

function requireFromRepo(relativePath) {
  return require(path.join(repoRoot, relativePath));
}

function b64(value) {
  return Buffer.from(value, "utf8").toString("base64");
}

function atRestEnvelope(overrides = {}) {
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
    binding: {
      uid: "uid-1",
      scope: "cloudvault",
      collection: "mobile_assistant_chats",
      docId: "thread-1",
      field: "signalEnvelope",
      mode: "at-rest",
      formatVersion: 1,
      ...(overrides.binding || {}),
    },
    ...(overrides.envelope || {}),
  };
}

function runSignalAtRestWriteSmoke() {
  const contracts = requireFromRepo("functions/node_modules/@openburnbar/signal-envelope-contracts");
  const writeGuard = requireFromRepo("functions/lib/signalAtRestWrite.js");
  const expected = {
    uid: "uid-1",
    collection: "mobile_assistant_chats",
    docId: "thread-1",
    field: "signalEnvelope",
  };

  assert.equal(typeof contracts.sanitizeCloudVaultSignalEnvelope, "function");
  assert.equal(typeof contracts.bindingToAAD, "function");
  assert.equal(typeof writeGuard.validateSignalAtRestEnvelopeForWrite, "function");
  assert.equal(typeof writeGuard.assertSignalAtRestEnvelopeForWrite, "function");

  const accepted = writeGuard.validateSignalAtRestEnvelopeForWrite(atRestEnvelope(), expected);
  assert.equal(accepted.ok, true);
  assert.equal(
    accepted.aad,
    "OpenBurnBar-Signal-AAD-v1|at-rest|cloudvault|uid-1||mobile_assistant_chats|thread-1|signalEnvelope||1",
  );

  const relocated = writeGuard.validateSignalAtRestEnvelopeForWrite(
    atRestEnvelope({ binding: { docId: "wrong-thread" } }),
    expected,
  );
  assert.equal(relocated.ok, false);
  assert.equal(relocated.reason, "binding-docid-mismatch");

  const polluted = writeGuard.validateSignalAtRestEnvelopeForWrite(
    atRestEnvelope({ envelope: { relayKeyVersion: 4 } }),
    expected,
  );
  assert.equal(polluted.ok, false);
  assert.equal(polluted.reason, "invalid-envelope-shape");

  assert.throws(
    () => writeGuard.assertSignalAtRestEnvelopeForWrite(atRestEnvelope({ binding: { uid: "attacker" } }), expected),
    (error) => error instanceof writeGuard.SignalAtRestWriteError && error.reason === "binding-uid-mismatch",
  );
}

function runPrivacyBackfillSmoke() {
  const privacy = requireFromRepo("functions/lib/callables/privacyBackfill.js").__testing__;
  assert.equal(typeof privacy.gatedDeletions, "function");
  assert.equal(typeof privacy.gatewayRelayedPlaintextStrippable, "function");
  assert.ok(Array.isArray(privacy.COLLECTION_PLANS));

  const sealedField = [{ field: "projectName", requires: "sealedProjectName" }];
  assert.deepEqual(
    privacy.gatedDeletions({ projectName: "secret project", sealedProjectName: { ciphertext: "x" } }, sealedField),
    ["projectName"],
  );
  assert.deepEqual(privacy.gatedDeletions({ projectName: "secret project" }, sealedField), []);

  const gatewayField = [{ field: "text", gatewayRelayed: true }];
  assert.deepEqual(privacy.gatedDeletions({ text: "legacy prompt" }, gatewayField), ["text"]);
  assert.deepEqual(
    privacy.gatedDeletions({ text: "sealed prompt", relayEnvelope: { payloadCiphertext: "x" } }, gatewayField),
    ["text"],
  );
  assert.deepEqual(
    privacy.gatedDeletions({ text: "schema prompt", schemaVersion: privacy.HERMES_GATEWAY_SCHEMA_VERSION }, gatewayField),
    ["text"],
  );

  const collections = privacy.COLLECTION_PLANS.map((plan) => plan.collection).sort();
  for (const expected of [
    "hermes_gateway_attachments",
    "hermes_gateway_events",
    "hermes_gateway_messages",
    "mobile_assistant_chats",
    "project_memory_snapshots",
  ]) {
    assert.ok(collections.includes(expected), `missing privacy backfill collection: ${expected}`);
  }

  const ungated = privacy.COLLECTION_PLANS.flatMap((plan) =>
    plan.fields
      .filter((field) => !field.requires && !field.gatewayRelayed)
      .map((field) => `${plan.collection}.${field.field}:${field.ungatedReason || ""}`),
  );
  assert.deepEqual(ungated, [
    "budgetEvents.detailJSON:retired local-only diagnostic detail; current cloud writers omit it and rules reject it",
  ]);
}

function main() {
  const args = new Set(process.argv.slice(2));
  const runAll = args.size === 0 || args.has("--all");
  if (runAll || args.has("--signal-at-rest-write")) {
    runSignalAtRestWriteSmoke();
  }
  if (runAll || args.has("--privacy-backfill")) {
    runPrivacyBackfillSmoke();
  }
  if (!runAll && !args.has("--signal-at-rest-write") && !args.has("--privacy-backfill")) {
    throw new Error("expected --all, --signal-at-rest-write, or --privacy-backfill");
  }
  console.log("PASS: compiled Functions CloudVault runtime smoke passed");
}

main();
