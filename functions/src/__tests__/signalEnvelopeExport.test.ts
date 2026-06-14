import { describe, expect, it } from "vitest";

import {
  isAtRestSignalEnvelope,
  isGatewaySignalEnvelope,
  sanitizeSignalEnvelopeForExport,
} from "../signalEnvelopeExport.js";
import {
  HERMES_GATEWAY_SIGNAL_AT_REST_ENCRYPTION,
  HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  HERMES_GATEWAY_SIGNAL_RELAY_KEY_VERSION,
  HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
} from "../hermesGateway.js";
import type {
  GatewaySignalAtRestKeyDeliveryDoc,
  GatewaySignalEnvelopeDoc,
} from "../types/generated/hermes-gateway.js";

const transportEnvelope: GatewaySignalEnvelopeDoc = {
  signalEnvelopeFormatVersion: HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  mode: "transport",
  relayKeyVersion: HERMES_GATEWAY_SIGNAL_RELAY_KEY_VERSION,
  relayEncryption: HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
  ciphertextLayer: {
    payloadCiphertextB64: "Z2F0ZXdheS1jaXBoZXJ0ZXh0",
    payloadAADLabel: "gateway:message",
    schemaVersion: 1,
  },
  keyDelivery: {
    scheme: HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
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
    formatVersion: HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  },
};

const atRestEnvelope: GatewaySignalEnvelopeDoc = {
  signalEnvelopeFormatVersion: HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  mode: "at-rest",
  relayEncryption: HERMES_GATEWAY_SIGNAL_AT_REST_ENCRYPTION,
  ciphertextLayer: {
    payloadCiphertextB64: "ZG9jLWNpcGhlcnRleHQ=",
    payloadAADLabel: "cloudvault:cloud_search_knowledge/sealedCiphertext",
    schemaVersion: 1,
  },
  keyDelivery: {
    scheme: HERMES_GATEWAY_SIGNAL_AT_REST_ENCRYPTION,
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
    formatVersion: HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  },
};

describe("signalEnvelopeExport recognizers", () => {
  it("isGatewaySignalEnvelope accepts both transport and at-rest envelopes", () => {
    expect(isGatewaySignalEnvelope(transportEnvelope)).toBe(true);
    expect(isGatewaySignalEnvelope(atRestEnvelope)).toBe(true);
  });

  it("isAtRestSignalEnvelope accepts only the cloudvault at-rest envelope", () => {
    expect(isAtRestSignalEnvelope(atRestEnvelope)).toBe(true);
    expect(isAtRestSignalEnvelope(transportEnvelope)).toBe(false);
    expect(isAtRestSignalEnvelope(null)).toBe(false);
    expect(isAtRestSignalEnvelope("at-rest")).toBe(false);
  });

  it("at-rest envelopes export opaquely while nested plaintext-adjacent keys are stripped", () => {
    const atRestKeyDelivery = atRestEnvelope.keyDelivery as GatewaySignalAtRestKeyDeliveryDoc;
    const polluted = {
      ...atRestEnvelope,
      binding: { ...atRestEnvelope.binding, privateDocTitle: "secret" },
      keyDelivery: {
        ...atRestKeyDelivery,
        wraps: [{ ...atRestKeyDelivery.wraps[0], privateDeviceName: "Alice's MacBook" }],
      },
    } as unknown as Record<string, unknown>;
    const { out, dropped } = sanitizeSignalEnvelopeForExport("signalEnvelope", polluted);
    expect(out).toEqual(atRestEnvelope);
    expect(dropped).toContain("signalEnvelope.binding.privateDocTitle");
    expect(dropped).toContain("signalEnvelope.keyDelivery.wraps.0.privateDeviceName");
  });
});
