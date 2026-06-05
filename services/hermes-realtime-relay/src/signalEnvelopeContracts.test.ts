import assert from "node:assert/strict";
import test from "node:test";

import {
  SIGNAL_ENVELOPE_FORMAT_VERSION,
  SIGNAL_RELAY_KEY_VERSION,
  SIGNAL_TRANSPORT_ENCRYPTION,
  isSignalEnvelope,
  sanitizeSignalEnvelopeForExport,
} from "@openburnbar/signal-envelope-contracts";

test("Hermes realtime relay shares the Signal transport envelope contract", () => {
  const envelope = {
    signalEnvelopeFormatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    mode: "transport",
    relayKeyVersion: SIGNAL_RELAY_KEY_VERSION,
    relayEncryption: SIGNAL_TRANSPORT_ENCRYPTION,
    ciphertextLayer: {
      payloadCiphertextB64: "Y2lwaGVydGV4dA==",
      payloadAADLabel: "hermes-gateway:frame",
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
      slotId: "frame-1",
      mode: "transport",
      formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    },
    plaintext: "must never pass through as part of the envelope",
    keyDeliveryDebug: "must be dropped",
  };

  assert.equal(isSignalEnvelope(envelope, "transport"), true);
  const { out, dropped } = sanitizeSignalEnvelopeForExport("signalEnvelope", envelope);
  assert.deepEqual(dropped, ["signalEnvelope.plaintext", "signalEnvelope.keyDeliveryDebug"]);
  assert.equal((out as Record<string, unknown>).mode, "transport");
  assert.equal((out as Record<string, unknown>).relayKeyVersion, SIGNAL_RELAY_KEY_VERSION);
});

test("Hermes realtime relay rejects malformed Signal transport downgrade shapes", () => {
  assert.equal(
    isSignalEnvelope(
      {
        signalEnvelopeFormatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
        mode: "transport",
        relayKeyVersion: SIGNAL_RELAY_KEY_VERSION - 1,
        relayEncryption: SIGNAL_TRANSPORT_ENCRYPTION,
        ciphertextLayer: {
          payloadCiphertextB64: "Y2lwaGVydGV4dA==",
          payloadAADLabel: "hermes-gateway:frame",
          schemaVersion: 1,
        },
        keyDelivery: {
          scheme: SIGNAL_TRANSPORT_ENCRYPTION,
          signalMessageType: 3,
          signalMessageB64: "not base64 !!",
          senderIdentityKeyId: "agent-device",
        },
        binding: {
          uid: "uid-1",
          scope: "gateway",
          clientId: "client-1",
          slotId: "frame-1",
          mode: "transport",
          formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
        },
      },
      "transport",
    ),
    false,
  );
});
