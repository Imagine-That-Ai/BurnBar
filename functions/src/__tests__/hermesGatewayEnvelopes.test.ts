import { describe, expect, it } from "vitest";

import {
  requireGatewayRelayEnvelope,
  requireGatewayRatchetEnvelope,
  requireProductionGatewayRelayEnvelope,
  sanitizeGatewayRatchetEnvelope,
  sanitizeGatewayRelayEnvelopeCapabilities,
  negotiateGatewayRelayEnvelopeCapabilities,
  HERMES_GATEWAY_RELAY_ENCRYPTION_V3,
  HERMES_GATEWAY_RELAY_KEY_VERSION,
  HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS,
  HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS,
} from "../hermesGateway.js";

import {
  SENDER_PUBKEY_B64,
  ratchetEnvelope,
  relayEnvelope,
  relayEnvelopeV1,
  relayEnvelopeV3,
} from "./hermesGatewayTestKit.js";

describe("requireGatewayRelayEnvelope", () => {
  it("accepts a well-formed v2 envelope and round-trips senderPublicKey verbatim", () => {
    const out = requireGatewayRelayEnvelope(relayEnvelope(), "relayEnvelope");
    expect(out).toEqual(relayEnvelope());
    // The v2 wire HINT must flow through byte-exact (not dropped, not mutated).
    expect(out.senderPublicKey).toBe(SENDER_PUBKEY_B64);
    expect(out.relayKeyVersion).toBe(2);
  });
  it("accepts a well-formed v3 HPKE envelope and requires the enc field", () => {
    const out = requireGatewayRelayEnvelope(relayEnvelopeV3(), "relayEnvelope");
    expect(out).toEqual(relayEnvelopeV3());
    expect(out.enc).toBe(relayEnvelopeV3().enc);
    expect(out.relayEncryption).toBe(HERMES_GATEWAY_RELAY_ENCRYPTION_V3);

    const { enc: _enc, ...withoutEnc } = relayEnvelopeV3();
    void _enc;
    expect(() => requireGatewayRelayEnvelope(withoutEnc, "relayEnvelope")).toThrow(/enc/);
  });
  it("keeps accepting a legacy v1 envelope (no senderPublicKey) — v1 is not bricked", () => {
    const out = requireGatewayRelayEnvelope(relayEnvelopeV1(), "relayEnvelope");
    expect(out).toEqual(relayEnvelopeV1());
    expect(out.senderPublicKey).toBeUndefined();
  });
  it("rejects a wrong algorithm constant", () => {
    expect(() =>
      requireGatewayRelayEnvelope({ ...relayEnvelope(), relayEncryption: "AES-256-GCM" }, "relayEnvelope"),
    ).toThrow(/relayEncryption/);
  });
  it("accepts the supported key-version set (1, 2, AND 3) and rejects every other (0, 101)", () => {
    // KEY-VERSION ACCEPT-SET: v1, v2, and v3 are all understood wire shapes; the clamp is an
    // accept-set membership test, so a forged/future version (0, 101) is rejected.
    expect(HERMES_GATEWAY_RELAY_KEY_VERSION).toBe(2);
    expect([...HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS].sort()).toEqual([1, 2, 3]);
    expect(requireGatewayRelayEnvelope(relayEnvelopeV1(), "x").relayKeyVersion).toBe(1);
    expect(requireGatewayRelayEnvelope(relayEnvelope(), "x").relayKeyVersion).toBe(2);
    expect(requireGatewayRelayEnvelope(relayEnvelopeV3(), "x").relayKeyVersion).toBe(3);
    expect(() => requireGatewayRelayEnvelope({ ...relayEnvelopeV1(), relayKeyVersion: 0 }, "relayEnvelope")).toThrow(
      /relayKeyVersion/,
    );
    // Any version outside the accept-set is rejected — not silently accepted by an
    // upper bound of 100.
    expect(() => requireGatewayRelayEnvelope({ ...relayEnvelope(), relayKeyVersion: 101 }, "relayEnvelope")).toThrow(
      /relayKeyVersion/,
    );
  });
  it("REQUIRES senderPublicKey for a v2 envelope and rejects when it is absent or malformed", () => {
    // v2 without the hint → rejected by require (the field is mandatory at v2).
    const { senderPublicKey: _omit, ...v2NoSender } = relayEnvelope();
    void _omit;
    expect(() => requireGatewayRelayEnvelope(v2NoSender, "relayEnvelope")).toThrow(/senderPublicKey/);
    // v2 with a malformed hint (wrong point format) → rejected.
    expect(() =>
      requireGatewayRelayEnvelope({ ...relayEnvelope(), senderPublicKey: "not base64 !!" }, "relayEnvelope"),
    ).toThrow(/senderPublicKey/);
  });
  it("rejects a non-base64 / empty payload ciphertext or wrapped key", () => {
    expect(() => requireGatewayRelayEnvelope({ ...relayEnvelope(), payloadCiphertext: "" }, "x")).toThrow(
      /payloadCiphertext/,
    );
    expect(() => requireGatewayRelayEnvelope({ ...relayEnvelope(), wrappedKey: "not base64 !!" }, "x")).toThrow(
      /wrappedKey/,
    );
  });
  it("rejects a non-record", () => {
    expect(() => requireGatewayRelayEnvelope("nope", "relayEnvelope")).toThrow(/relay envelope/);
  });
});

describe("requireProductionGatewayRelayEnvelope (new writes must be authenticated v2/v3)", () => {
  it("accepts v2 and v3 production envelopes and round-trips them verbatim", () => {
    expect([...HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS].sort()).toEqual([2, 3]);
    expect(requireProductionGatewayRelayEnvelope(relayEnvelope(), "relayEnvelope")).toEqual(relayEnvelope());
    expect(requireProductionGatewayRelayEnvelope(relayEnvelopeV3(), "relayEnvelope")).toEqual(relayEnvelopeV3());
  });
  it("REJECTS a legacy v1 envelope on a new write (downgrade surface) while the v1-tolerant read path still accepts it", () => {
    // The write guard fails closed on v1...
    expect(() => requireProductionGatewayRelayEnvelope(relayEnvelopeV1(), "relayEnvelope")).toThrow(/relayKeyVersion/);
    // ...but the read/legacy sanitizer keeps v1 readable so stored docs are not bricked.
    expect(requireGatewayRelayEnvelope(relayEnvelopeV1(), "relayEnvelope").relayKeyVersion).toBe(1);
  });
  it("still enforces the authenticated senderPublicKey requirement (delegates to requireGatewayRelayEnvelope)", () => {
    const { senderPublicKey: _omit, ...v2NoSender } = relayEnvelope();
    expect(() => requireProductionGatewayRelayEnvelope(v2NoSender, "relayEnvelope")).toThrow(/senderPublicKey/);
    const { senderPublicKey: _omitV3, ...v3NoSender } = relayEnvelopeV3();
    void _omitV3;
    expect(() => requireProductionGatewayRelayEnvelope(v3NoSender, "relayEnvelope")).toThrow(/senderPublicKey/);
  });
});

describe("Hermes Gateway ratchet envelope contract", () => {
  it("accepts and sanitizes a well-formed v1 ratchet envelope", () => {
    expect(requireGatewayRatchetEnvelope(ratchetEnvelope(), "ratchetEnvelope")).toEqual(ratchetEnvelope());
    expect(sanitizeGatewayRatchetEnvelope(ratchetEnvelope())).toEqual(ratchetEnvelope());
  });

  it("rejects malformed ratchet protocol headers", () => {
    expect(() =>
      requireGatewayRatchetEnvelope(
        { ...ratchetEnvelope(), header: { ...ratchetEnvelope().header, algorithm: "wrong" } },
        "ratchetEnvelope",
      ),
    ).toThrow(/ratchet/);
    expect(
      sanitizeGatewayRatchetEnvelope({ ...ratchetEnvelope(), header: { ...ratchetEnvelope().header, version: 2 } }),
    ).toBeUndefined();
    expect(
      sanitizeGatewayRatchetEnvelope({
        ...ratchetEnvelope(),
        header: { ...ratchetEnvelope().header, sessionID: "bad/session" },
      }),
    ).toBeUndefined();
    expect(
      sanitizeGatewayRatchetEnvelope({
        ...ratchetEnvelope(),
        header: { ...ratchetEnvelope().header, ratchetPublicKeyBase64: "not base64 !!" },
      }),
    ).toBeUndefined();
  });

  it("rejects malformed ratchet ciphertext and counters", () => {
    expect(sanitizeGatewayRatchetEnvelope({ ...ratchetEnvelope(), ciphertextBase64: "not base64 !!" })).toBeUndefined();
    expect(
      sanitizeGatewayRatchetEnvelope({
        ...ratchetEnvelope(),
        header: { ...ratchetEnvelope().header, messageNumber: -1 },
      }),
    ).toBeUndefined();
    expect(
      sanitizeGatewayRatchetEnvelope({
        ...ratchetEnvelope(),
        header: { ...ratchetEnvelope().header, epoch: 1_000_000_001 },
      }),
    ).toBeUndefined();
  });
});

describe("Hermes Gateway relay envelope capability matrix", () => {
  it("accepts explicit v2/v3 support and negotiates the highest shared production version", () => {
    const agent = sanitizeGatewayRelayEnvelopeCapabilities({
      supportsRelayEnvelopeVersions: [2, 3],
      preferredRelayEnvelopeVersion: 3,
      supportsHpkeV3: true,
      clientPlatform: "python",
      clientAppBuild: "hermes-agent",
    });
    const phone = sanitizeGatewayRelayEnvelopeCapabilities({
      supportsRelayEnvelopeVersions: [2, 3],
      preferredRelayEnvelopeVersion: 3,
      supportsHpkeV3: true,
      clientPlatform: "ios",
      clientAppBuild: "openburnbar",
    });
    expect(agent.platform).toBe("python");
    expect(phone.platform).toBe("ios");
    // supportsSignalEnvelope defaults FALSE on both endpoints and negotiates as the
    // AND of the two (false) — v4 is never folded into the relay-envelope ladder.
    expect(agent.supportsSignalEnvelope).toBe(false);
    expect(phone.supportsSignalEnvelope).toBe(false);
    expect(negotiateGatewayRelayEnvelopeCapabilities(agent, phone)).toEqual({
      supportsRelayEnvelopeVersions: [2, 3],
      preferredRelayEnvelopeVersion: 3,
      supportsHpkeV3: true,
      supportsSignalEnvelope: false,
    });
  });

  it("rejects inconsistent v3 capability claims", () => {
    expect(() =>
      sanitizeGatewayRelayEnvelopeCapabilities({
        supportsRelayEnvelopeVersions: [2],
        preferredRelayEnvelopeVersion: 2,
        supportsHpkeV3: true,
      }),
    ).toThrow(/supportsHpkeV3/);
    expect(() =>
      sanitizeGatewayRelayEnvelopeCapabilities({
        supportsRelayEnvelopeVersions: [2, 3],
        preferredRelayEnvelopeVersion: 2,
        supportsHpkeV3: false,
      }),
    ).toThrow(/supportsHpkeV3/);
    expect(() =>
      sanitizeGatewayRelayEnvelopeCapabilities({
        supportsRelayEnvelopeVersions: [2],
        preferredRelayEnvelopeVersion: 3,
      }),
    ).toThrow(/preferredRelayEnvelopeVersion/);
  });
});
