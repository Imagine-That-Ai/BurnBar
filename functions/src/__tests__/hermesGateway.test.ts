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
  sanitizeGatewayRelayEnvelope,
  sanitizeHermesGatewayScopes,
  serializeHermesGatewayTypingDoc,
  serializeHermesGatewayEvent,
  HERMES_GATEWAY_PRESENCE_WINDOW_MS,
  HERMES_GATEWAY_PROTOCOL_VERSION,
  HERMES_GATEWAY_RELAY_ENCRYPTION,
  HERMES_GATEWAY_RELAY_KEY_VERSION,
  HERMES_GATEWAY_SCHEMA_VERSION,
  type GatewayRelayEnvelopeDoc,
  type HermesGatewayClientDoc,
} from "../hermesGateway.js";

// A base64 X9.63 uncompressed P-256 public key: 65 bytes, first byte 0x04.
const RELAY_PUBKEY_B64 = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 7)]).toString("base64");

function relayEnvelope(): GatewayRelayEnvelopeDoc {
  return {
    payloadCiphertext: Buffer.from("ciphertext").toString("base64"),
    wrappedKey: Buffer.from("wrappedkey").toString("base64"),
    relayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
    relayKeyVersion: 1,
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
  it("accepts a well-formed envelope and echoes the canonical fields", () => {
    expect(requireGatewayRelayEnvelope(relayEnvelope(), "relayEnvelope")).toEqual(relayEnvelope());
  });
  it("rejects a wrong algorithm constant", () => {
    expect(() =>
      requireGatewayRelayEnvelope({ ...relayEnvelope(), relayEncryption: "AES-256-GCM" }, "relayEnvelope"),
    ).toThrow(/relayEncryption/);
  });
  it("accepts ONLY the supported key version (1) and rejects every other", () => {
    // Codex KEY-VERSION CLAMP: only v1 crypto exists, so a permissive 1..100
    // range is closed to exactly 1 until a v2 wrapper ships.
    expect(HERMES_GATEWAY_RELAY_KEY_VERSION).toBe(1);
    expect(requireGatewayRelayEnvelope({ ...relayEnvelope(), relayKeyVersion: 1 }, "x").relayKeyVersion).toBe(1);
    expect(() => requireGatewayRelayEnvelope({ ...relayEnvelope(), relayKeyVersion: 0 }, "relayEnvelope")).toThrow(
      /relayKeyVersion/,
    );
    // v2 (and any other version) must be rejected — not silently accepted by an
    // upper bound of 100.
    expect(() => requireGatewayRelayEnvelope({ ...relayEnvelope(), relayKeyVersion: 2 }, "relayEnvelope")).toThrow(
      /relayKeyVersion/,
    );
    expect(() => requireGatewayRelayEnvelope({ ...relayEnvelope(), relayKeyVersion: 101 }, "relayEnvelope")).toThrow(
      /relayKeyVersion/,
    );
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
  it("accepts a well-formed stored envelope", () => {
    expect(sanitizeGatewayRelayEnvelope(relayEnvelope())).toEqual(relayEnvelope());
  });
  it("rejects a malformed stored envelope the write side would never have accepted", () => {
    // Wrong algorithm constant.
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), relayEncryption: "AES-256-GCM" })).toBeUndefined();
    // Unsupported key version (only v1 crypto exists).
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), relayKeyVersion: 2 })).toBeUndefined();
    // Non-base64 ciphertext / wrapped key.
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), payloadCiphertext: "not base64 !!" })).toBeUndefined();
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), wrappedKey: "not base64 !!" })).toBeUndefined();
    // Empty strings.
    expect(sanitizeGatewayRelayEnvelope({ ...relayEnvelope(), payloadCiphertext: "" })).toBeUndefined();
    // Non-record.
    expect(sanitizeGatewayRelayEnvelope("nope")).toBeUndefined();
    expect(sanitizeGatewayRelayEnvelope(undefined)).toBeUndefined();
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
      phoneRelayPublicKey: RELAY_PUBKEY_B64,
      phoneRelayKeyVersion: 1,
      phoneRelayEncryption: HERMES_GATEWAY_RELAY_ENCRYPTION,
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
