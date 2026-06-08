import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION,
  HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS,
  HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS,
  HERMES_GATEWAY_RELAY_ENCRYPTION_V3,
  HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL,
  HERMES_GATEWAY_SCHEMA_VERSION,
  HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  HERMES_GATEWAY_SIGNAL_RELAY_KEY_VERSION,
  HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
  HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS,
  negotiateGatewayRelayEnvelopeCapabilities,
  productionSignalEnvelopeVersionsFromEnv,
  requireGatewaySignalEnvelope,
  requireProductionGatewaySignalEnvelope,
  sanitizeGatewayRelayEnvelopeCapabilities,
  sanitizeGatewaySignalEnvelope,
  serializeHermesGatewayEvent,
  signalEnvelopeV4DisabledFromEnv,
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

  it("rejects production Signal writes while the rollback gate has emptied the production set", () => {
    const previous = [...HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS];
    HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.clear();
    try {
      expect(() => requireProductionGatewaySignalEnvelope(signalEnvelope(), "signalEnvelope")).toThrow(
        /rollback gate/,
      );
    } finally {
      for (const version of previous) HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.add(version);
    }
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

describe("Hermes Gateway Signal envelope version ladder (activated)", () => {
  it("rides relay key VERSION 4 — read-SUPPORTED and explicitly production-enabled", () => {
    // The Signal transport envelope is the next rung (v4) above the bespoke
    // HPKE-Auth v3 relay envelope. Reads tolerate it; production may emit it
    // only through the separate signalEnvelope family.
    expect(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL).toBe(4);
    expect(HERMES_GATEWAY_SIGNAL_RELAY_KEY_VERSION).toBe(4);
    expect(HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS.has(4)).toBe(true);
    expect([...HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS]).toEqual([4]);
    expect(HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.has(4)).toBe(true);
    // v4 is a SEPARATE wire family — never folded into the relay-envelope ladder,
    // which stays {2,3} for production. preferred relay version can never be 4.
    expect(HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS.has(4)).toBe(false);
    expect(HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION).toBe(3);
  });

  it("read-tolerates a v4 signalEnvelope as sealed + opaque (no decrypt)", () => {
    const sealed = sanitizeGatewaySignalEnvelope(signalEnvelope(), "transport");
    expect(sealed).toEqual(signalEnvelope());
    // The server only round-trips the opaque base64 ciphertext; it never holds a
    // Signal session key, so the payload is passed through verbatim.
    expect(sealed?.ciphertextLayer.payloadCiphertextB64).toBe(signalEnvelope().ciphertextLayer.payloadCiphertextB64);
    expect(sealed?.relayKeyVersion).toBe(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL);
  });

  it("rejects a forged/future signal version fail-closed (strict equality, not a range)", () => {
    // A v5 (or any non-SUPPORTED) signal envelope is unreadable — never coerced.
    expect(sanitizeGatewaySignalEnvelope({ ...signalEnvelope(), relayKeyVersion: 5 })).toBeUndefined();
    expect(sanitizeGatewaySignalEnvelope({ ...signalEnvelope(), relayKeyVersion: 3 })).toBeUndefined();
    expect(() => requireGatewaySignalEnvelope({ ...signalEnvelope(), relayKeyVersion: 5 }, "signalEnvelope")).toThrow(
      /Signal envelope v1/,
    );
  });

  it("accepts a v4 signalEnvelope for production writes once activation is explicit", () => {
    expect(requireProductionGatewaySignalEnvelope(signalEnvelope(), "signalEnvelope")).toEqual(signalEnvelope());
    // A malformed v4 is rejected as invalid-argument BEFORE the production gate.
    expect(() =>
      requireProductionGatewaySignalEnvelope(
        { ...signalEnvelope(), ciphertextLayer: { ...signalEnvelope().ciphertextLayer, payloadCiphertextB64: "!!!" } },
        "signalEnvelope",
      ),
    ).toThrow(/Signal envelope v1/);
  });

  it("supports an environment kill switch for rollback without weakening read tolerance", () => {
    expect(signalEnvelopeV4DisabledFromEnv("1")).toBe(true);
    expect(signalEnvelopeV4DisabledFromEnv("true")).toBe(true);
    expect(signalEnvelopeV4DisabledFromEnv("yes")).toBe(true);
    expect(signalEnvelopeV4DisabledFromEnv("on")).toBe(true);
    expect(signalEnvelopeV4DisabledFromEnv("0")).toBe(false);
    expect(signalEnvelopeV4DisabledFromEnv(undefined)).toBe(false);
    expect([...productionSignalEnvelopeVersionsFromEnv("1")]).toEqual([]);
    expect([...productionSignalEnvelopeVersionsFromEnv(undefined)]).toEqual([HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL]);
    expect(HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS.has(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL)).toBe(true);
  });

  it("plaintext-on-v4 is dropped: a Signal-sealed doc never surfaces a plaintext sibling", () => {
    // Already covered for events; re-assert the sealed-doc invariant explicitly so
    // a backfilled/admin-written v4 doc with stray plaintext fails closed on read.
    const out = serializeHermesGatewayEvent({
      id: "evt_v4",
      sequence: 9,
      kind: "message",
      destinationId: "burnbar:home",
      senderId: "burnbar-user",
      attachmentIds: [],
      createdAt: "2026-06-01T00:00:00.000Z",
      schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
      signalEnvelope: signalEnvelope(),
      text: "should never leak",
    });
    expect(out?.signalEnvelope?.relayKeyVersion).toBe(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL);
    expect(out?.text).toBeUndefined();
  });
});

describe("supportsSignalEnvelope capability defaults false and never folds v4 into the relay ladder", () => {
  function baseCaps(): Record<string, unknown> {
    return { supportsRelayEnvelopeVersions: [2, 3], preferredRelayEnvelopeVersion: 3, supportsHpkeV3: true };
  }

  it("defaults supportsSignalEnvelope to FALSE when the field is absent", () => {
    expect(sanitizeGatewayRelayEnvelopeCapabilities(baseCaps()).supportsSignalEnvelope).toBe(false);
    expect(
      sanitizeGatewayRelayEnvelopeCapabilities({ ...baseCaps(), supportsSignalEnvelope: false }).supportsSignalEnvelope,
    ).toBe(false);
  });

  it("accepts supportsSignalEnvelope=true only as the separate Signal-family capability", () => {
    const caps = sanitizeGatewayRelayEnvelopeCapabilities({ ...baseCaps(), supportsSignalEnvelope: true });
    expect(caps.supportsSignalEnvelope).toBe(true);
    expect(caps.supportsRelayEnvelopeVersions).toEqual([2, 3]);
    expect(caps.preferredRelayEnvelopeVersion).toBe(3);
    expect(() => sanitizeGatewayRelayEnvelopeCapabilities({ ...baseCaps(), supportsSignalEnvelope: "yes" })).toThrow(
      /must be a boolean/,
    );
  });

  it("negotiates supportsSignalEnvelope as the AND of both endpoints (both default false)", () => {
    const agent = sanitizeGatewayRelayEnvelopeCapabilities(baseCaps());
    const phone = sanitizeGatewayRelayEnvelopeCapabilities(baseCaps());
    const negotiated = negotiateGatewayRelayEnvelopeCapabilities(agent, phone);
    expect(negotiated.supportsSignalEnvelope).toBe(false);
    // The negotiated RELAY ladder can never include or prefer the Signal version.
    expect(negotiated.supportsRelayEnvelopeVersions).not.toContain(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL);
    expect(negotiated.preferredRelayEnvelopeVersion).toBe(3);
    expect(negotiated.preferredRelayEnvelopeVersion).not.toBe(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL);
  });

  it("never folds v4 into the relay-envelope version list (production ladder unchanged)", () => {
    // Supplying 4 in the relay ladder is rejected — v4 is the signal family, not a
    // relay-envelope version, so it can never be negotiated/emitted as relay v4.
    expect(() =>
      sanitizeGatewayRelayEnvelopeCapabilities({
        supportsRelayEnvelopeVersions: [2, 3, 4],
        preferredRelayEnvelopeVersion: 3,
      }),
    ).toThrow(/supportsRelayEnvelopeVersions must contain only/);
    expect(() =>
      sanitizeGatewayRelayEnvelopeCapabilities({
        supportsRelayEnvelopeVersions: [4],
        preferredRelayEnvelopeVersion: 4,
      }),
    ).toThrow(/supportsRelayEnvelopeVersions must contain only/);
  });
});

describe("Hermes Gateway Signal envelope activation candidate", () => {
  let previousProductionSignalVersions: number[];

  function baseCaps(overrides: Record<string, unknown> = {}): Record<string, unknown> {
    return {
      supportsRelayEnvelopeVersions: [2, 3],
      preferredRelayEnvelopeVersion: 3,
      supportsHpkeV3: true,
      ...overrides,
    };
  }

  beforeEach(() => {
    previousProductionSignalVersions = [...HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS];
    HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.clear();
    HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.add(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL);
  });

  afterEach(() => {
    HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.clear();
    for (const version of previousProductionSignalVersions) {
      HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.add(version);
    }
  });

  it("accepts production Signal envelopes once v4 is explicitly activated", () => {
    expect(HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.has(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL)).toBe(true);
    expect(requireProductionGatewaySignalEnvelope(signalEnvelope(), "signalEnvelope")).toEqual(signalEnvelope());
  });

  it("still rejects malformed Signal envelopes before the production activation check", () => {
    expect(() =>
      requireProductionGatewaySignalEnvelope(
        { ...signalEnvelope(), ciphertextLayer: { ...signalEnvelope().ciphertextLayer, payloadCiphertextB64: "!!!" } },
        "signalEnvelope",
      ),
    ).toThrow(/Signal envelope v1/);
  });

  it("allows supportsSignalEnvelope=true without folding v4 into the relay-envelope ladder", () => {
    const caps = sanitizeGatewayRelayEnvelopeCapabilities(baseCaps({ supportsSignalEnvelope: true }));

    expect(caps.supportsSignalEnvelope).toBe(true);
    expect(caps.supportsRelayEnvelopeVersions).toEqual([2, 3]);
    expect(caps.preferredRelayEnvelopeVersion).toBe(3);
    expect(caps.preferredRelayEnvelopeVersion).not.toBe(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL);
  });

  it("negotiates Signal support only when both endpoints advertise it", () => {
    const agent = sanitizeGatewayRelayEnvelopeCapabilities(baseCaps({ supportsSignalEnvelope: true }));
    const phone = sanitizeGatewayRelayEnvelopeCapabilities(baseCaps({ supportsSignalEnvelope: true }));
    expect(negotiateGatewayRelayEnvelopeCapabilities(agent, phone)).toMatchObject({
      supportsRelayEnvelopeVersions: [2, 3],
      preferredRelayEnvelopeVersion: 3,
      supportsHpkeV3: true,
      supportsSignalEnvelope: true,
    });

    const legacyPhone = sanitizeGatewayRelayEnvelopeCapabilities(baseCaps({ supportsSignalEnvelope: false }));
    expect(negotiateGatewayRelayEnvelopeCapabilities(agent, legacyPhone)).toMatchObject({
      supportsSignalEnvelope: false,
      preferredRelayEnvelopeVersion: 3,
    });
  });

  it("keeps preferredRelayEnvelopeVersion=4 invalid even after Signal activation", () => {
    expect(() =>
      sanitizeGatewayRelayEnvelopeCapabilities(
        baseCaps({ supportsSignalEnvelope: true, supportsRelayEnvelopeVersions: [2, 3, 4] }),
      ),
    ).toThrow(/supportsRelayEnvelopeVersions must contain only/);
    expect(() =>
      sanitizeGatewayRelayEnvelopeCapabilities(
        baseCaps({ supportsSignalEnvelope: true, preferredRelayEnvelopeVersion: HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL }),
      ),
    ).toThrow(/preferredRelayEnvelopeVersion/);
  });
});
