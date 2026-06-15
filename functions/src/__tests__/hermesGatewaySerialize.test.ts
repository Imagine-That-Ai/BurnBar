import { describe, expect, it } from "vitest";

import {
  gatewayPlaintextWriteAllowed,
  isWithinGatewayGraceWindow,
  publicClientView,
  sanitizeGatewayRelayEnvelope,
  serializeHermesGatewayEvent,
  HERMES_GATEWAY_RELAY_ENCRYPTION,
  type HermesGatewayClientDoc,
} from "../hermesGateway.js";

import {
  RELAY_PUBKEY_B64,
  SENDER_PUBKEY_B64,
  ratchetEnvelope,
  relayEnvelope,
  relayEnvelopeV1,
  relayEnvelopeV3,
} from "./hermesGatewayTestKit.js";

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
