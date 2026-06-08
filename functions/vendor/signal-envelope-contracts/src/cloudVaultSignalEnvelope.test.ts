import assert from "node:assert/strict";
import test from "node:test";

import {
  SIGNAL_AT_REST_ENCRYPTION,
  SIGNAL_ENVELOPE_FORMAT_VERSION,
  SIGNAL_RELAY_KEY_VERSION,
  SIGNAL_TRANSPORT_ENCRYPTION,
} from "./index.js";
import {
  isCloudVaultSignalEnvelope,
  sanitizeCloudVaultSignalEnvelope,
} from "./cloudVaultSignalEnvelope.js";

function cloudVaultAtRestEnvelope() {
  return {
    signalEnvelopeFormatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    mode: "at-rest",
    relayEncryption: SIGNAL_AT_REST_ENCRYPTION,
    ciphertextLayer: {
      payloadCiphertextB64: "ZG9jLWNpcGhlcnRleHQ=",
      payloadAADLabel: "cloudvault:cloud_search_knowledge/sealedCiphertext",
      schemaVersion: 1,
    },
    keyDelivery: {
      scheme: SIGNAL_AT_REST_ENCRYPTION,
      contentKeyLength: 32,
      wraps: [
        {
          recipientKind: "device",
          recipientIdentityKeyId: "device-1",
          recipientIdentityKeyB64: "cHVibGljLWtleQ==",
          sealedContentKeyB64: "c2VhbGVkLWtleQ==",
        },
      ],
    },
    binding: {
      uid: "uid-1",
      scope: "cloudvault",
      collection: "cloud_search_knowledge",
      docId: "doc-1",
      field: "sealedCiphertext",
      mode: "at-rest",
      formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    },
  };
}

function gatewayTransportEnvelope() {
  return {
    signalEnvelopeFormatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    mode: "transport",
    relayKeyVersion: SIGNAL_RELAY_KEY_VERSION,
    relayEncryption: SIGNAL_TRANSPORT_ENCRYPTION,
    ciphertextLayer: {
      payloadCiphertextB64: "Z2F0ZXdheS1jaXBoZXJ0ZXh0",
      payloadAADLabel: "gateway:message",
      schemaVersion: 1,
    },
    keyDelivery: {
      scheme: SIGNAL_TRANSPORT_ENCRYPTION,
      signalMessageType: 3,
      signalMessageB64: "cHJla2V5LW1lc3NhZ2U=",
      senderIdentityKeyId: "agent-1",
    },
    binding: {
      uid: "uid-1",
      scope: "gateway",
      clientId: "client-1",
      slotId: "slot-1",
      mode: "transport",
      formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    },
  };
}

test("recognizes a valid cloudvault at-rest envelope", () => {
  assert.equal(isCloudVaultSignalEnvelope(cloudVaultAtRestEnvelope()), true);
  assert.deepEqual(sanitizeCloudVaultSignalEnvelope(cloudVaultAtRestEnvelope()), cloudVaultAtRestEnvelope());
});

test("rejects a gateway transport envelope as a CloudVault at-rest envelope", () => {
  // Reuses the contract's mode/scope discrimination — a transport envelope is
  // never a CloudVault at-rest one even though both are valid Signal envelopes.
  assert.equal(isCloudVaultSignalEnvelope(gatewayTransportEnvelope()), false);
  assert.equal(sanitizeCloudVaultSignalEnvelope(gatewayTransportEnvelope()), undefined);
});

test("fails closed on a malformed at-rest envelope (empty wraps)", () => {
  const broken = cloudVaultAtRestEnvelope();
  broken.keyDelivery.wraps = [];
  assert.equal(isCloudVaultSignalEnvelope(broken), false);
  assert.equal(sanitizeCloudVaultSignalEnvelope(broken), undefined);
});

test("rejects non-objects and an at-rest envelope carrying a relayKeyVersion", () => {
  assert.equal(isCloudVaultSignalEnvelope(null), false);
  assert.equal(isCloudVaultSignalEnvelope("at-rest"), false);
  // The contract forbids relayKeyVersion on at-rest envelopes — fail closed.
  const withRelayKeyVersion = { ...cloudVaultAtRestEnvelope(), relayKeyVersion: SIGNAL_RELAY_KEY_VERSION };
  assert.equal(isCloudVaultSignalEnvelope(withRelayKeyVersion), false);
});
