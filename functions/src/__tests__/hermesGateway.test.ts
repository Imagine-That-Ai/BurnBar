import { describe, expect, it } from "vitest";

import {
  clientAdvertisesModel,
  effectiveOversightMode,
  gatewayPlaintextWriteAllowed,
  isGatewayRelayPublicKeyB64,
  isHermesGatewayApprovalExpired,
  isHermesGatewayClientOnline,
  isWithinGatewayGraceWindow,
  pendingModelSwitchInFlight,
  publicApprovalView,
  publicClientView,
  requireGatewayRelayEnvelope,
  requireGatewayRatchetEnvelope,
  requireProductionGatewayRelayEnvelope,
  sanitizeGatewayRelayEnvelope,
  sanitizeGatewayRatchetEnvelope,
  sanitizeGatewayRelayEnvelopeCapabilities,
  sanitizeHermesGatewayApprovalTTL,
  sanitizeHermesGatewayScopes,
  negotiateGatewayRelayEnvelopeCapabilities,
  serializeHermesGatewayTypingDoc,
  serializeHermesGatewayEvent,
  HERMES_GATEWAY_APPROVAL_TTL_MS,
  HERMES_GATEWAY_MAX_APPROVAL_TTL_MS,
  HERMES_GATEWAY_MIN_APPROVAL_TTL_MS,
  HERMES_GATEWAY_PRESENCE_WINDOW_MS,
  HERMES_GATEWAY_PROTOCOL_VERSION,
  HERMES_GATEWAY_RELAY_ENCRYPTION,
  HERMES_GATEWAY_RELAY_ENCRYPTION_V3,
  HERMES_GATEWAY_RELAY_KEY_VERSION,
  HERMES_GATEWAY_RATCHET_ALGORITHM,
  HERMES_GATEWAY_RATCHET_PROTOCOL_VERSION,
  HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS,
  HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS,
  HERMES_GATEWAY_SCHEMA_VERSION,
  type GatewayRelayEnvelopeDoc,
  type GatewayRatchetEnvelopeDoc,
  type HermesGatewayClientDoc,
} from "../hermesGateway.js";

// A base64 X9.63 uncompressed P-256 public key: 65 bytes, first byte 0x04.
const RELAY_PUBKEY_B64 = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 7)]).toString("base64");
// A second, distinct X9.63 uncompressed P-256 public key for the v2 senderPublicKey
// wire hint (so a round-trip asserts the exact value flows through, not just any key).
const SENDER_PUBKEY_B64 = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 9)]).toString("base64");

// The canonical v2 relay envelope: the DEFAULT key version is now 2, which adds
// the optional senderPublicKey wire HINT (a base64 X9.63 P-256 key) that BOTH
// validators must round-trip verbatim.
function relayEnvelope(): GatewayRelayEnvelopeDoc {
  return {
    payloadCiphertext: Buffer.from("ciphertext").toString("base64"),
    wrappedKey: Buffer.from("wrappedkey").toString("base64"),
    relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
    relayKeyVersion: 2,
    senderPublicKey: SENDER_PUBKEY_B64,
  };
}

// A legacy v1 relay envelope: no senderPublicKey hint (the field did not exist
// before v2); both validators must keep accepting it unchanged (no v1 brick).
function relayEnvelopeV1(): GatewayRelayEnvelopeDoc {
  return {
    payloadCiphertext: Buffer.from("ciphertext").toString("base64"),
    wrappedKey: Buffer.from("wrappedkey").toString("base64"),
    relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
    relayKeyVersion: 1,
  };
}

function relayEnvelopeV3(): GatewayRelayEnvelopeDoc {
  return {
    payloadCiphertext: Buffer.from("ciphertext").toString("base64"),
    wrappedKey: Buffer.from("hpke-wrapped-key").toString("base64"),
    enc: Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 3)]).toString("base64"),
    relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION_V3,
    relayKeyVersion: 3,
    senderPublicKey: SENDER_PUBKEY_B64,
  };
}

function ratchetEnvelope(): GatewayRatchetEnvelopeDoc {
  return {
    header: {
      version: HERMES_GATEWAY_RATCHET_PROTOCOL_VERSION,
      algorithm: HERMES_GATEWAY_RATCHET_ALGORITHM,
      sessionID: "hgr_session-1",
      senderDeviceID: "agent-device",
      receiverDeviceID: "phone-device",
      ratchetPublicKeyBase64: RELAY_PUBKEY_B64,
      previousChainLength: 0,
      messageNumber: 0,
      epoch: 1,
    },
    ciphertextBase64: Buffer.from("ratchet-ciphertext").toString("base64"),
  };
}

describe("Hermes Gateway helper contracts", () => {
  it("defaults to read/write without manage scope", () => {
    expect(sanitizeHermesGatewayScopes(undefined)).toEqual(["hermes.gateway.read", "hermes.gateway.write"]);
  });

  it("preserves explicit manage scope when the approval flow requests it", () => {
    expect(sanitizeHermesGatewayScopes(["hermes.gateway.read", "hermes.gateway.manage", "not-a-real-scope"])).toEqual([
      "hermes.gateway.read",
      "hermes.gateway.manage",
    ]);
  });
});

describe("Hermes Gateway runtime-state presence (feature 1)", () => {
  const now = Date.parse("2026-06-01T00:01:30.000Z");
  it("is online within the presence window and offline past it", () => {
    expect(isHermesGatewayClientOnline("2026-06-01T00:01:00.000Z", now)).toBe(true);
    expect(isHermesGatewayClientOnline("2026-06-01T00:00:00.000Z", now)).toBe(true);
    expect(isHermesGatewayClientOnline("2026-06-01T00:00:00.000Z", now + 1)).toBe(false);
  });
  it("fails closed to OFFLINE for a stopped/garbage gateway (never fakes online)", () => {
    expect(isHermesGatewayClientOnline(undefined, now)).toBe(false);
    expect(isHermesGatewayClientOnline("", now)).toBe(false);
    expect(isHermesGatewayClientOnline("nope", now)).toBe(false);
    expect(HERMES_GATEWAY_PRESENCE_WINDOW_MS).toBe(90_000);
  });
});

describe("Hermes Gateway model switching (feature 2)", () => {
  const client = {
    runtimeModelOptions: [
      { providerId: "hermes", providerName: "Hermes", modelId: "minimax-m2.7-highspeed", displayName: "MiniMax" },
    ],
  };
  it("validates a requested model against the advertised catalog (case-insensitive)", () => {
    expect(clientAdvertisesModel(client, "MiniMax-M2.7-Highspeed")).toBe(true);
    expect(clientAdvertisesModel(client, "gpt-5")).toBe(false);
    expect(clientAdvertisesModel({ runtimeModelOptions: [] }, "x")).toBe(false);
  });
  it("settles the pending marker once the runtime reports the applied model", () => {
    const at = "2026-06-01T00:00:00.000Z";
    const t = Date.parse("2026-06-01T00:00:30.000Z");
    expect(
      pendingModelSwitchInFlight({ pendingModelId: "m", pendingModelRequestedAt: at, runtimeModelId: "old" }, t),
    ).toBe(true);
    expect(
      pendingModelSwitchInFlight({ pendingModelId: "m", pendingModelRequestedAt: at, runtimeModelId: "M" }, t),
    ).toBe(false);
  });
});

describe("Hermes Gateway oversight (feature 3)", () => {
  it("defaults to the safe option (supervised) when unset/invalid", () => {
    expect(effectiveOversightMode(undefined)).toBe("supervised");
    expect(effectiveOversightMode("bogus")).toBe("supervised");
    expect(effectiveOversightMode("autonomous")).toBe("autonomous");
  });
  it("fails closed on expiry so an unanswered gate never blocks forever", () => {
    expect(isHermesGatewayApprovalExpired(undefined)).toBe(true);
    expect(isHermesGatewayApprovalExpired("2000-01-01T00:00:00.000Z")).toBe(true);
    expect(isHermesGatewayApprovalExpired(new Date(Date.now() + 60_000).toISOString())).toBe(false);
  });
  it("derives an expired status in the public view for a stale waiting gate", () => {
    const gate = {
      id: "g",
      clientId: "c",
      destinationId: "d",
      actionId: "a",
      summary: "s",
      status: "waiting_for_approval" as const,
      requestedAt: "2026-06-01T00:00:00.000Z",
      expiresAt: "2000-01-01T00:00:00.000Z",
      schemaVersion: 1,
    };
    expect(publicApprovalView(gate).status).toBe("expired");
  });
  it("bounds optional short live-proof TTLs without changing the production default", () => {
    expect(sanitizeHermesGatewayApprovalTTL(undefined)).toBe(HERMES_GATEWAY_APPROVAL_TTL_MS);
    expect(sanitizeHermesGatewayApprovalTTL("bad")).toBe(HERMES_GATEWAY_APPROVAL_TTL_MS);
    expect(sanitizeHermesGatewayApprovalTTL(1)).toBe(HERMES_GATEWAY_MIN_APPROVAL_TTL_MS);
    expect(sanitizeHermesGatewayApprovalTTL(30)).toBe(30_000);
    expect(sanitizeHermesGatewayApprovalTTL(60 * 60)).toBe(HERMES_GATEWAY_MAX_APPROVAL_TTL_MS);
  });
});

describe("Hermes Gateway E2EE — schema/protocol bump (gateway-wire)", () => {
  it("bumps both versions to 2 so /state advertises the sealed contract", () => {
    expect(HERMES_GATEWAY_SCHEMA_VERSION).toBe(2);
    expect(HERMES_GATEWAY_PROTOCOL_VERSION).toBe(2);
    expect(HERMES_GATEWAY_RELAY_ENCRYPTION).toBe("p256-hkdf-sha256-aesgcm");
  });
});

describe("serializeHermesGatewayTypingDoc", () => {
  it("stores typing presence without private thread routing metadata", () => {
    const doc = serializeHermesGatewayTypingDoc({
      clientId: "hgw_abc",
      destinationId: "burnbar:home",
      createdAt: "2026-06-01T00:00:00.000Z",
      expiresAt: "2026-06-01T00:00:15.000Z",
    });

    expect(doc).toMatchObject({
      id: "hgw_abc",
      clientId: "hgw_abc",
      kind: "typing",
      destinationId: "burnbar:home",
      schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
    });
    expect(doc).not.toHaveProperty("threadId");
  });
});

describe("isGatewayRelayPublicKeyB64", () => {
  it("accepts a base64 X9.63 uncompressed P-256 key (65 bytes, 0x04)", () => {
    expect(isGatewayRelayPublicKeyB64(RELAY_PUBKEY_B64)).toBe(RELAY_PUBKEY_B64);
  });
  it("rejects the wrong length, the wrong point format, and non-base64", () => {
    // 64 bytes (too short).
    expect(isGatewayRelayPublicKeyB64(Buffer.alloc(64, 4).toString("base64"))).toBeUndefined();
    // 65 bytes but first byte is not 0x04 (not uncompressed).
    expect(
      isGatewayRelayPublicKeyB64(Buffer.concat([Buffer.from([0x02]), Buffer.alloc(64, 1)]).toString("base64")),
    ).toBeUndefined();
    expect(isGatewayRelayPublicKeyB64("not base64 !!")).toBeUndefined();
    expect(isGatewayRelayPublicKeyB64(undefined)).toBeUndefined();
    expect(isGatewayRelayPublicKeyB64("")).toBeUndefined();
  });
});

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
    expect(negotiateGatewayRelayEnvelopeCapabilities(agent, phone)).toEqual({
      supportsRelayEnvelopeVersions: [2, 3],
      preferredRelayEnvelopeVersion: 3,
      supportsHpkeV3: true,
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

describe("serializeHermesGatewayEvent — sealed pass-through + legacy fallback", () => {
  const base = {
    id: "evt_1",
    sequence: 4,
    kind: "message" as const,
    destinationId: "burnbar:home",
    senderId: "burnbar-user",
    attachmentIds: [],
    createdAt: "2026-06-01T00:00:00.000Z",
    schemaVersion: 2,
  };
  it("passes a sealed schema-2 event through with NO plaintext text", () => {
    const out = serializeHermesGatewayEvent({ ...base, relayEnvelope: relayEnvelope() });
    expect(out?.relayEnvelope).toEqual(relayEnvelope());
    expect(out?.text).toBeUndefined();
    expect(out?.senderDisplayName).toBeUndefined();
  });
  it("keeps the legacy plaintext read fallback for a schema-1 doc with no envelope", () => {
    const out = serializeHermesGatewayEvent({ ...base, schemaVersion: 1, text: "legacy body" });
    expect(out?.text).toBe("legacy body");
    expect(out?.relayEnvelope).toBeUndefined();
  });
  it("rejects a doc that has neither a sealed envelope nor plaintext text", () => {
    expect(serializeHermesGatewayEvent(base)).toBeUndefined();
  });
  it("passes a model switch through by modelId without requiring plaintext text", () => {
    const out = serializeHermesGatewayEvent({
      ...base,
      kind: "model_switch" as const,
      modelId: "minimax-m2.7",
    });
    expect(out?.kind).toBe("model_switch");
    expect(out?.modelId).toBe("minimax-m2.7");
    expect(out?.text).toBeUndefined();
  });
  it("UNCONDITIONALLY drops plaintext siblings when a relayEnvelope is present", () => {
    // Codex SERIALIZE STRIP-SIBLINGS: a backfilled/admin/corrupt doc that carries
    // BOTH a sealed envelope and stray plaintext text/senderDisplayName/threadId
    // must surface NONE of the plaintext — the envelope wins, sealed-doc invariant
    // holds regardless of how the doc was written.
    const out = serializeHermesGatewayEvent({
      ...base,
      relayEnvelope: relayEnvelope(),
      text: "leaked body",
      senderDisplayName: "Alberto",
      threadId: "thread-secret",
    });
    expect(out?.relayEnvelope).toEqual(relayEnvelope());
    expect(out?.text).toBeUndefined();
    expect(out?.senderDisplayName).toBeUndefined();
    expect(out?.threadId).toBeUndefined();
  });
  it("passes a ratchet-sealed schema-2 event through with NO plaintext siblings", () => {
    const out = serializeHermesGatewayEvent({
      ...base,
      ratchetEnvelope: ratchetEnvelope(),
      text: "leaked ratchet body",
      senderDisplayName: "Alberto",
      threadId: "thread-secret",
    });
    expect(out?.ratchetEnvelope).toEqual(ratchetEnvelope());
    expect(out?.relayEnvelope).toBeUndefined();
    expect(out?.text).toBeUndefined();
    expect(out?.senderDisplayName).toBeUndefined();
    expect(out?.threadId).toBeUndefined();
  });
  it("drops plaintext siblings on a schema-2 doc even without an envelope (no legacy leak)", () => {
    // schemaVersion>=2 marks a sealed-doc generation: never echo plaintext.
    const out = serializeHermesGatewayEvent({
      ...base,
      schemaVersion: 2,
      relayEnvelope: relayEnvelope(),
      text: "leaked body",
    });
    expect(out?.text).toBeUndefined();
  });
});

describe("sanitizeGatewayRelayEnvelope — strict read-side validation (Codex SANITIZE STRICT)", () => {
  it("accepts a well-formed stored v2 envelope and round-trips senderPublicKey verbatim", () => {
    const out = sanitizeGatewayRelayEnvelope(relayEnvelope());
    expect(out).toEqual(relayEnvelope());
    expect(out?.senderPublicKey).toBe(SENDER_PUBKEY_B64);
  });
  it("accepts a well-formed stored v1 envelope (no senderPublicKey) — symmetric with require", () => {
    expect(sanitizeGatewayRelayEnvelope(relayEnvelopeV1())).toEqual(relayEnvelopeV1());
  });
  it("accepts a well-formed stored v3 HPKE envelope and rejects stripped/tampered v3 fields", () => {
    expect(sanitizeGatewayRelayEnvelope(relayEnvelopeV3())).toEqual(relayEnvelopeV3());
    const { enc: _enc, ...withoutEnc } = relayEnvelopeV3();
    void _enc;
    expect(sanitizeGatewayRelayEnvelope(withoutEnc)).toBeUndefined();
    expect(
      sanitizeGatewayRelayEnvelope({ ...relayEnvelopeV3(), relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION }),
    ).toBeUndefined();
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelopeV3(), enc: "not base64 !!" })).toBeUndefined();
  });
  it("rejects a malformed stored envelope the write side would never have accepted", () => {
    // Wrong algorithm constant.
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), relayEncryption: "AES-256-GCM" })).toBeUndefined();
    // Unsupported key version (outside the v1/v2/v3 accept-set).
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), relayKeyVersion: 0 })).toBeUndefined();
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), relayKeyVersion: 101 })).toBeUndefined();
    // Non-base64 ciphertext / wrapped key.
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), payloadCiphertext: "not base64 !!" })).toBeUndefined();
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), wrappedKey: "not base64 !!" })).toBeUndefined();
    // Empty strings.
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), payloadCiphertext: "" })).toBeUndefined();
    // Non-record.
    expect(sanitizeGatewayRelayEnvelope("nope")).toBeUndefined();
    expect(sanitizeGatewayRelayEnvelope(undefined)).toBeUndefined();
  });
  it("fails closed (returns undefined) when senderPublicKey is malformed or absent at v2", () => {
    // A v2 envelope whose senderPublicKey is present-but-malformed → unreadable.
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), senderPublicKey: "not base64 !!" })).toBeUndefined();
    // A v2 envelope missing the now-required hint → unreadable (mirrors require).
    const { senderPublicKey: _omit, ...v2NoSender } = relayEnvelope();
    void _omit;
    expect(sanitizeGatewayRelayEnvelope(v2NoSender)).toBeUndefined();
    // A v1 envelope carrying a present-but-malformed hint also fails closed.
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelopeV1(), senderPublicKey: "not base64 !!" })).toBeUndefined();
  });
  it("treats a doc with a malformed stored envelope as having no readable envelope", () => {
    // A schema-2 event whose envelope is corrupt must NOT pass the corrupt
    // envelope through, and (since it is a sealed doc) must NOT leak plaintext —
    // so it serializes to undefined rather than exposing a malformed/forged body.
    const out = serializeHermesGatewayEvent({
      id: "evt_x",
      sequence: 9,
      kind: "message" as const,
      destinationId: "burnbar:home",
      senderId: "burnbar-user",
      attachmentIds: [],
      createdAt: "2026-06-01T00:00:00.000Z",
      schemaVersion: 2,
      relayEnvelope: { ...relayEnvelope(), relayKeyVersion: 99 },
      text: "should not leak",
    });
    expect(out).toBeUndefined();
  });
});

describe("publicClientView — surfaces relay public keys", () => {
  it("echoes both relay public keys + relayCapable so the peer can seal", () => {
    const client: HermesGatewayClientDoc = {
      id: "hgw_1",
      uid: "u",
      displayName: "Hermes Agent",
      status: "active",
      tokenHash: "a".repeat(64),
      tokenPreview: "obb_hgw_...abcd",
      scopes: ["hermes.gateway.read", "hermes.gateway.write"],
      homeDestinationId: "burnbar:home",
      agentRelayPublicKey: RELAY_PUBKEY_B64,
      agentRelayKeyVersion: 1,
      agentRelayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
      agentSupportsRelayEnvelopeVersions: [2, 3],
      agentPreferredRelayEnvelopeVersion: 3,
      agentSupportsHpkeV3: true,
      phoneRelayPublicKey: RELAY_PUBKEY_B64,
      phoneRelayKeyVersion: 1,
      phoneRelayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
      phoneSupportsRelayEnvelopeVersions: [2, 3],
      phonePreferredRelayEnvelopeVersion: 3,
      phoneSupportsHpkeV3: true,
      agentRatchetIdentityPublicKey: RELAY_PUBKEY_B64,
      agentRatchetSigningPublicKey: RELAY_PUBKEY_B64,
      agentRatchetSignedPreKeyPublicKey: SENDER_PUBKEY_B64,
      agentRatchetSignedPreKeyId: "spk_agent_1",
      agentRatchetSignedPreKeySignature: Buffer.from("agent-signature").toString("base64"),
      agentSupportsRatchetV1: true,
      phoneRatchetIdentityPublicKey: RELAY_PUBKEY_B64,
      phoneRatchetSigningPublicKey: RELAY_PUBKEY_B64,
      phoneRatchetSignedPreKeyPublicKey: SENDER_PUBKEY_B64,
      phoneRatchetSignedPreKeyId: "spk_phone_1",
      phoneRatchetSignedPreKeySignature: Buffer.from("phone-signature").toString("base64"),
      phoneSupportsRatchetV1: true,
      supportsRatchetV1: true,
      supportsRelayEnvelopeVersions: [2, 3],
      preferredRelayEnvelopeVersion: 3,
      supportsHpkeV3: true,
      relayCapable: true,
      createdAt: "2026-06-01T00:00:00.000Z",
      updatedAt: "2026-06-01T00:00:00.000Z",
      schemaVersion: 2,
    };
    const view = publicClientView(client);
    expect(view.relayPublicKey).toBe(RELAY_PUBKEY_B64);
    expect(view.relayKeyVersion).toBe(1);
    expect(view.relayEncryption).toBe(HERMES_GATEWAY_RELAY_ENCRYPTION);
    expect(view.agentRelayPublicKey).toBe(RELAY_PUBKEY_B64);
    expect(view.phoneRelayPublicKey).toBe(RELAY_PUBKEY_B64);
    expect(view.supportsRelayEnvelopeVersions).toEqual([2, 3]);
    expect(view.preferredRelayEnvelopeVersion).toBe(3);
    expect(view.supportsHpkeV3).toBe(true);
    expect(view.agentSupportsRelayEnvelopeVersions).toEqual([2, 3]);
    expect(view.phoneSupportsRelayEnvelopeVersions).toEqual([2, 3]);
    expect(view.agentRatchetIdentityPublicKey).toBe(RELAY_PUBKEY_B64);
    expect(view.phoneRatchetSignedPreKeyId).toBe("spk_phone_1");
    expect(view.supportsRatchetV1).toBe(true);
    expect(view.relayCapable).toBe(true);
    // Never leak the server-only secret material.
    expect(view).not.toHaveProperty("tokenHash");
  });
  it("reports relayCapable false for a legacy client without keys", () => {
    const legacy = {
      id: "hgw_legacy",
      uid: "u",
      displayName: "Hermes Agent",
      status: "active" as const,
      tokenHash: "b".repeat(64),
      tokenPreview: "obb_hgw_...wxyz",
      scopes: ["hermes.gateway.read" as const],
      homeDestinationId: "burnbar:home",
      createdAt: "2026-06-01T00:00:00.000Z",
      updatedAt: "2026-06-01T00:00:00.000Z",
      schemaVersion: 1,
    };
    expect(publicClientView(legacy).relayCapable).toBe(false);
    expect(publicClientView(legacy).relayPublicKey).toBeUndefined();
    expect(publicClientView(legacy).agentRelayPublicKey).toBeUndefined();
  });
});

describe("Gateway plaintext write gate", () => {
  it("is permanently closed for new writes", () => {
    expect(isWithinGatewayGraceWindow(0)).toBe(false);
    expect(isWithinGatewayGraceWindow(Date.now())).toBe(false);
  });
  it("rejects plaintext for every client capability state", () => {
    expect(gatewayPlaintextWriteAllowed(false, 0)).toBe(false);
    expect(gatewayPlaintextWriteAllowed(true, 0)).toBe(false);
    expect(gatewayPlaintextWriteAllowed(undefined, 0)).toBe(false);
  });
});
