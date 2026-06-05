import { describe, expect, it } from "vitest";

import {
  HERMES_GATEWAY_RELAY_ENCRYPTION_V3,
  HERMES_GATEWAY_SCHEMA_VERSION,
  HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  HERMES_GATEWAY_SIGNAL_RELAY_KEY_VERSION,
  HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
  requireGatewaySignalEnvelope,
  requireProductionGatewaySignalEnvelope,
  sanitizeGatewaySignalEnvelope,
  serializeHermesGatewayEvent,
  type GatewaySignalEnvelopeDoc,
} from "../hermesGateway.js";

function signalEnvelope(): GatewaySignalEnvelopeDoc {
  return {
    signalEnvelopeFormatVersion: HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
    mode: "transport",
    relayKeyVersion: HERMES_GATEWAY_SIGNAL_RELAY_KEY_VERSION,
    relayEncryption: HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
    ciphertextLayer: {
      payloadCiphertextB64: Buffer.from("signal-payload-ciphertext").toString("base64"),
      payloadAADLabel: "gatewayEvent",
      schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
    },
    keyDelivery: {
      scheme: HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
      signalMessageType: 3,
      signalMessageB64: Buffer.from("serialized-prekey-signal-message").toString("base64"),
      senderIdentityKeyId: "agent-signal-identity",
      ratchetEpochHint: 1,
    },
    binding: {
      uid: "user_1",
      scope: "gateway",
      clientId: "client-1",
      slotId: "evt_signal_1",
      mode: "transport",
      formatVersion: HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
    },
  };
}

describe("Hermes Gateway Signal envelope contract", () => {
  it("accepts and sanitizes a well-formed transport signalEnvelope", () => {
    expect(requireGatewaySignalEnvelope(signalEnvelope(), "signalEnvelope", "transport")).toEqual(signalEnvelope());
    expect(sanitizeGatewaySignalEnvelope(signalEnvelope(), "transport")).toEqual(signalEnvelope());
  });

  it("rejects malformed Signal envelope downgrade and mode-confusion shapes", () => {
    expect(sanitizeGatewaySignalEnvelope({ ...signalEnvelope(), signalEnvelopeFormatVersion: 0 })).toBeUndefined();
    expect(sanitizeGatewaySignalEnvelope({ ...signalEnvelope(), relayKeyVersion: 3 })).toBeUndefined();
    expect(
      sanitizeGatewaySignalEnvelope({
        ...signalEnvelope(),
        relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION_V3,
      }),
    ).toBeUndefined();
    expect(
      sanitizeGatewaySignalEnvelope({
        ...signalEnvelope(),
        mode: "at-rest",
        binding: { ...signalEnvelope().binding, mode: "at-rest" },
      }),
      "transport key delivery cannot be parsed as at-rest",
    ).toBeUndefined();
    expect(
      sanitizeGatewaySignalEnvelope({
        ...signalEnvelope(),
        keyDelivery: { ...signalEnvelope().keyDelivery, signalMessageB64: "not base64 !!" },
      }),
    ).toBeUndefined();
  });

  it("keeps production Signal writes disabled until the libsignal runtime readiness gate is complete", () => {
    expect(() => requireProductionGatewaySignalEnvelope(signalEnvelope(), "signalEnvelope")).toThrow(
      /runtime readiness gate/,
    );
  });

  it("passes a Signal-sealed schema-2 event through with NO plaintext siblings", () => {
    const out = serializeHermesGatewayEvent({
      id: "evt_1",
      sequence: 4,
      kind: "message",
      destinationId: "burnbar:home",
      senderId: "burnbar-user",
      attachmentIds: [],
      createdAt: "2026-06-01T00:00:00.000Z",
      schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
      signalEnvelope: signalEnvelope(),
      text: "leaked Signal body",
      senderDisplayName: "Alberto",
      threadId: "thread-secret",
    });

    expect(out?.signalEnvelope).toEqual(signalEnvelope());
    expect(out?.relayEnvelope).toBeUndefined();
    expect(out?.ratchetEnvelope).toBeUndefined();
    expect(out?.text).toBeUndefined();
    expect(out?.senderDisplayName).toBeUndefined();
    expect(out?.threadId).toBeUndefined();
  });
});
