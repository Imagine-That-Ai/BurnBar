import assert from "node:assert/strict";
import test from "node:test";

import {
  SIGNAL_AT_REST_ENCRYPTION,
  SIGNAL_ENVELOPE_FORMAT_VERSION,
  SIGNAL_RELAY_KEY_VERSION,
  SIGNAL_TRANSPORT_ENCRYPTION,
  sanitizeSignalEnvelope,
  sanitizeSignalEnvelopeForExport,
} from "./index.js";

function transportEnvelope() {
  return {
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
      ratchetEpochHint: 7,
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
}

function atRestEnvelope() {
  return {
    signalEnvelopeFormatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    mode: "at-rest",
    relayEncryption: SIGNAL_AT_REST_ENCRYPTION,
    ciphertextLayer: {
      payloadCiphertextB64: "ZG9jLWNpcGhlcnRleHQ=",
      payloadAADLabel: "cloudvault:session_logs/body",
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
      collection: "session_logs",
      docId: "doc-1",
      field: "body",
      mode: "at-rest",
      formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    },
  };
}

test("sanitizes valid transport and at-rest Signal envelopes", () => {
  assert.deepEqual(sanitizeSignalEnvelope(transportEnvelope(), "transport"), transportEnvelope());
  assert.deepEqual(sanitizeSignalEnvelope(atRestEnvelope(), "at-rest"), atRestEnvelope());
});

test("rejects downgrade, mode confusion, malformed base64, and plaintext siblings", () => {
  assert.equal(sanitizeSignalEnvelope({ ...transportEnvelope(), signalEnvelopeFormatVersion: 0 }), undefined);
  assert.equal(sanitizeSignalEnvelope({ ...transportEnvelope(), relayKeyVersion: SIGNAL_RELAY_KEY_VERSION - 1 }), undefined);
  assert.equal(sanitizeSignalEnvelope({ ...transportEnvelope(), mode: "at-rest" }), undefined);
  assert.equal(
    sanitizeSignalEnvelope({
      ...transportEnvelope(),
      ciphertextLayer: { ...transportEnvelope().ciphertextLayer, payloadCiphertextB64: "no spaces allowed" },
    }),
    undefined,
  );
  for (const nonCanonicalBase64 of ["abc", "====", "YQ=", "YQ===", "c2lnbmFsLW1lc3NhZ2U"]) {
    assert.equal(
      sanitizeSignalEnvelope({
        ...transportEnvelope(),
        keyDelivery: { ...transportEnvelope().keyDelivery, signalMessageB64: nonCanonicalBase64 },
      }),
      undefined,
    );
  }

  const envelope = {
    ...transportEnvelope(),
    plaintext: "leak",
    keyDelivery: { ...transportEnvelope().keyDelivery, decryptedContentKey: "nope" },
  };
  const { out, dropped } = sanitizeSignalEnvelopeForExport("signalEnvelope", envelope);
  assert.deepEqual(out, transportEnvelope());
  assert.deepEqual(dropped, ["signalEnvelope.plaintext", "signalEnvelope.keyDelivery.decryptedContentKey"]);
});
