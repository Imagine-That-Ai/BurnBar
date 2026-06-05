import assert from "node:assert/strict";
import test from "node:test";

import {
  SIGNAL_AT_REST_ENCRYPTION,
  SIGNAL_ENVELOPE_FORMAT_VERSION,
  SIGNAL_RELAY_KEY_VERSION,
  SIGNAL_TRANSPORT_ENCRYPTION,
  isSignalEnvelope,
  sanitizeSignalEnvelopeForExport,
} from "@openburnbar/signal-envelope-contracts";

test("hosted MCP uses the shared Signal envelope contract for opaque at-rest rows", () => {
  const envelope = {
    signalEnvelopeFormatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    mode: "at-rest",
    relayEncryption: SIGNAL_AT_REST_ENCRYPTION,
    ciphertextLayer: {
      payloadCiphertextB64: "c2VhbGVkLWRvYw==",
      payloadAADLabel: "cloudvault:pensieve/body",
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
      collection: "knowledge",
      docId: "doc-1",
      field: "body",
      mode: "at-rest",
      formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    },
    plaintext: "must be stripped before export",
  };

  assert.equal(isSignalEnvelope(envelope, "at-rest"), true);
  const { out, dropped } = sanitizeSignalEnvelopeForExport("sealedCiphertext", envelope);
  assert.deepEqual(dropped, ["sealedCiphertext.plaintext"]);
  assert.equal((out as Record<string, unknown>).mode, "at-rest");
  assert.equal((out as Record<string, unknown>).relayKeyVersion, undefined);
});

test("hosted MCP rejects transport envelopes in at-rest-only storage paths", () => {
  const transportEnvelope = {
    signalEnvelopeFormatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    mode: "transport",
    relayKeyVersion: SIGNAL_RELAY_KEY_VERSION,
    relayEncryption: SIGNAL_TRANSPORT_ENCRYPTION,
    ciphertextLayer: {
      payloadCiphertextB64: "Y2lwaGVydGV4dA==",
      payloadAADLabel: "hermes-gateway:event",
      schemaVersion: 1,
    },
    keyDelivery: {
      scheme: SIGNAL_TRANSPORT_ENCRYPTION,
      signalMessageType: 3,
      signalMessageB64: "c2lnbmFsLW1lc3NhZ2U=",
      senderIdentityKeyId: "agent-device",
    },
    binding: {
      uid: "uid-1",
      scope: "gateway",
      clientId: "client-1",
      slotId: "event-1",
      mode: "transport",
      formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    },
  };

  assert.equal(isSignalEnvelope(transportEnvelope, "at-rest"), false);
});
