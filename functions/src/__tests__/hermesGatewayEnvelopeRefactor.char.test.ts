/**
 * @fileoverview Characterization test pinning the CURRENT observable behavior of
 * the six hermesGateway functions flagged for complexity/max-lines refactor:
 * requireGatewayRelayEnvelope, sanitizeGatewayRelayEnvelope,
 * sanitizeGatewayRelayEnvelopeCapabilities, serializeHermesGatewayEvent,
 * isHermesGatewayClientDoc (exercises module-private hasValidOptionalRelayFields),
 * and requireGatewayRelayEnvelope's nested sanitizeGatewayRelayEnvelope path.
 *
 * The refactor is a pure relocation: identical inputs must keep producing
 * identical return values AND identical thrown HttpsError code/message.
 */
import { describe, expect, it } from "vitest";
import { HttpsError } from "firebase-functions/v2/https";

import {
  HERMES_GATEWAY_RELAY_ENCRYPTION,
  HERMES_GATEWAY_RELAY_ENCRYPTION_V3,
  isHermesGatewayClientDoc,
  requireGatewayRelayEnvelope,
  sanitizeGatewayRelayEnvelope,
  sanitizeGatewayRelayEnvelopeCapabilities,
  serializeHermesGatewayEvent,
} from "../hermesGateway.js";

const PUBKEY65 = "BAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=";
const PAYLOAD = "aGVsbG8tcGF5bG9hZA==";
const WRAPPED = "d3JhcHBlZC1rZXktYnl0ZXM=";
const ENC = "ZW5jLWJ5dGVz";

const validV2Envelope = {
  payloadCiphertext: PAYLOAD,
  wrappedKey: WRAPPED,
  relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
  relayKeyVersion: 2,
  senderPublicKey: PUBKEY65,
};

const validV3Envelope = {
  payloadCiphertext: PAYLOAD,
  wrappedKey: WRAPPED,
  relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION_V3,
  relayKeyVersion: 3,
  enc: ENC,
  senderPublicKey: PUBKEY65,
};

function expectHttpsError(error: unknown, code: HttpsError["code"], message: string): void {
  expect(error).toBeInstanceOf(HttpsError);
  if (!(error instanceof HttpsError)) throw new Error("expected HttpsError");
  expect(error.code).toBe(code);
  expect(error.message).toBe(message);
}

describe("requireGatewayRelayEnvelope (characterization)", () => {
  it("returns the canonical v2 envelope for a valid v2 input", () => {
    expect(requireGatewayRelayEnvelope(validV2Envelope, "relayEnvelope")).toEqual({
      payloadCiphertext: PAYLOAD,
      wrappedKey: WRAPPED,
      relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
      relayKeyVersion: 2,
      senderPublicKey: PUBKEY65,
    });
  });

  it("returns the canonical v3 envelope including enc", () => {
    expect(requireGatewayRelayEnvelope(validV3Envelope, "relayEnvelope")).toEqual({
      payloadCiphertext: PAYLOAD,
      wrappedKey: WRAPPED,
      relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION_V3,
      relayKeyVersion: 3,
      enc: ENC,
      senderPublicKey: PUBKEY65,
    });
  });

  it("throws invalid-argument when the value is not a record", () => {
    let captured: unknown;
    try {
      requireGatewayRelayEnvelope("nope", "relayEnvelope");
    } catch (error) {
      captured = error;
    }
    expectHttpsError(captured, "invalid-argument", "relayEnvelope must be a relay envelope.");
  });

  it("throws invalid-argument for an unsupported relayKeyVersion", () => {
    let captured: unknown;
    try {
      requireGatewayRelayEnvelope({ ...validV2Envelope, relayKeyVersion: 99 }, "relayEnvelope");
    } catch (error) {
      captured = error;
    }
    expectHttpsError(captured, "invalid-argument", "relayEnvelope.relayKeyVersion must be one of 1, 2, 3.");
  });

  it("throws invalid-argument when a v2 envelope omits senderPublicKey", () => {
    let captured: unknown;
    try {
      const { senderPublicKey: _drop, ...rest } = validV2Envelope;
      requireGatewayRelayEnvelope(rest, "relayEnvelope");
    } catch (error) {
      captured = error;
    }
    expectHttpsError(
      captured,
      "invalid-argument",
      "relayEnvelope.senderPublicKey must be a base64 X9.63 P-256 public key (65 bytes, 0x04-prefixed) for relayKeyVersion 2.",
    );
  });

  it("throws invalid-argument when enc is present on a v2 envelope", () => {
    let captured: unknown;
    try {
      requireGatewayRelayEnvelope({ ...validV2Envelope, enc: ENC }, "relayEnvelope");
    } catch (error) {
      captured = error;
    }
    expectHttpsError(captured, "invalid-argument", "relayEnvelope.enc is only valid for relayKeyVersion 3.");
  });
});

describe("sanitizeGatewayRelayEnvelope (characterization)", () => {
  it("returns the canonical envelope for a valid v2 input", () => {
    expect(sanitizeGatewayRelayEnvelope(validV2Envelope)).toEqual({
      payloadCiphertext: PAYLOAD,
      wrappedKey: WRAPPED,
      relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
      relayKeyVersion: 2,
      senderPublicKey: PUBKEY65,
    });
  });

  it("returns undefined for a v2 envelope missing senderPublicKey", () => {
    const { senderPublicKey: _drop, ...rest } = validV2Envelope;
    expect(sanitizeGatewayRelayEnvelope(rest)).toBeUndefined();
  });

  it("returns undefined for a non-record input", () => {
    expect(sanitizeGatewayRelayEnvelope(42)).toBeUndefined();
  });

  it("returns undefined for an unsupported relayKeyVersion", () => {
    expect(sanitizeGatewayRelayEnvelope({ ...validV2Envelope, relayKeyVersion: 7 })).toBeUndefined();
  });
});

describe("sanitizeGatewayRelayEnvelopeCapabilities (characterization)", () => {
  it("defaults supportsRelayEnvelopeVersions and derives preferred/hpke when absent", () => {
    expect(sanitizeGatewayRelayEnvelopeCapabilities({})).toEqual({
      supportsRelayEnvelopeVersions: [2],
      preferredRelayEnvelopeVersion: 2,
      supportsHpkeV3: false,
      supportsSignalEnvelope: false,
    });
  });

  it("honors an explicit version list including v3 and surfaces platform/appBuild", () => {
    expect(
      sanitizeGatewayRelayEnvelopeCapabilities({
        supportsRelayEnvelopeVersions: [3, 2],
        clientPlatform: "ios",
        clientAppBuild: "1234",
      }),
    ).toEqual({
      supportsRelayEnvelopeVersions: [2, 3],
      preferredRelayEnvelopeVersion: 3,
      supportsHpkeV3: true,
      supportsSignalEnvelope: false,
      platform: "ios",
      appBuild: "1234",
    });
  });

  it("invokes the throwError callback for an out-of-range version", () => {
    const messages: string[] = [];
    const sink = (message: string): never => {
      messages.push(message);
      throw new Error(message);
    };
    expect(() => sanitizeGatewayRelayEnvelopeCapabilities({ supportsRelayEnvelopeVersions: [99] }, sink)).toThrow(
      "supportsRelayEnvelopeVersions must contain only 2, 3.",
    );
    expect(messages[0]).toBe("supportsRelayEnvelopeVersions must contain only 2, 3.");
  });

  it("throws the default HttpsError when supportsHpkeV3 is not a boolean", () => {
    let captured: unknown;
    try {
      sanitizeGatewayRelayEnvelopeCapabilities({ supportsRelayEnvelopeVersions: [2], supportsHpkeV3: "yes" });
    } catch (error) {
      captured = error;
    }
    expectHttpsError(captured, "invalid-argument", "supportsHpkeV3 must be a boolean.");
  });
});

describe("serializeHermesGatewayEvent (characterization)", () => {
  it("surfaces legacy plaintext text for an unsealed schema-1 message doc", () => {
    const result = serializeHermesGatewayEvent({
      id: "evt-1",
      sequence: 5,
      kind: "message",
      destinationId: "burnbar:home",
      senderId: "sender-1",
      threadId: "thread-1",
      senderDisplayName: "Alice",
      text: "hello world",
      attachmentIds: ["a1", 7, "a2"],
      createdAt: "2026-01-01T00:00:00.000Z",
      schemaVersion: 1,
    });
    expect(result).toEqual({
      id: "evt-1",
      sequence: 5,
      kind: "message",
      destinationId: "burnbar:home",
      targetClientId: undefined,
      threadId: "thread-1",
      senderId: "sender-1",
      senderDisplayName: "Alice",
      text: "hello world",
      modelId: undefined,
      relayEnvelope: undefined,
      ratchetEnvelope: undefined,
      signalEnvelope: undefined,
      attachmentIds: ["a1", "a2"],
      createdAt: "2026-01-01T00:00:00.000Z",
      schemaVersion: 1,
    });
  });

  it("drops plaintext siblings for a sealed schema-2 doc and keeps the envelope", () => {
    const result = serializeHermesGatewayEvent({
      id: "evt-2",
      sequence: 6,
      kind: "message",
      destinationId: "burnbar:home",
      senderId: "sender-2",
      threadId: "thread-2",
      senderDisplayName: "Bob",
      text: "should be dropped",
      relayEnvelope: validV2Envelope,
      attachmentIds: [],
      createdAt: "2026-01-02T00:00:00.000Z",
      schemaVersion: 2,
    });
    expect(result?.threadId).toBeUndefined();
    expect(result?.senderDisplayName).toBeUndefined();
    expect(result?.text).toBeUndefined();
    expect(result?.relayEnvelope).toEqual({
      payloadCiphertext: PAYLOAD,
      wrappedKey: WRAPPED,
      relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
      relayKeyVersion: 2,
      senderPublicKey: PUBKEY65,
    });
  });

  it("returns undefined for a record missing required fields", () => {
    expect(serializeHermesGatewayEvent({ id: "evt-3" })).toBeUndefined();
  });

  it("returns undefined for a non-record", () => {
    expect(serializeHermesGatewayEvent(null)).toBeUndefined();
  });
});

describe("isHermesGatewayClientDoc (exercises hasValidOptionalRelayFields)", () => {
  const baseClient = {
    id: "client-1",
    uid: "uid-1",
    displayName: "Phone",
    status: "active",
    tokenHash: "a".repeat(64),
    tokenPreview: "obb_hgw_...abcd",
    scopes: ["hermes.gateway.read"],
    homeDestinationId: "burnbar:home",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    schemaVersion: 2,
  };

  it("accepts a minimal valid client doc with no optional relay fields", () => {
    expect(isHermesGatewayClientDoc(baseClient)).toBe(true);
  });

  it("accepts a client doc carrying well-typed optional relay fields", () => {
    expect(
      isHermesGatewayClientDoc({
        ...baseClient,
        agentRelayPublicKey: PUBKEY65,
        agentRelayKeyVersion: 2,
        agentSupportsRelayEnvelopeVersions: [2, 3],
        agentSupportsHpkeV3: true,
        relayCapable: true,
      }),
    ).toBe(true);
  });

  it("rejects a client doc whose optional relay field has the wrong type", () => {
    expect(
      isHermesGatewayClientDoc({
        ...baseClient,
        agentRelayKeyVersion: "two",
      }),
    ).toBe(false);
  });

  it("rejects a non-record", () => {
    expect(isHermesGatewayClientDoc(undefined)).toBe(false);
  });
});
