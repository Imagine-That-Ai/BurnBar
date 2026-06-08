import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import {
  assertSignalAtRestEnvelopeForWrite,
  isSignalAtRestRequiredForCollection,
  SIGNAL_AT_REST_REQUIRED_COLLECTIONS,
  SIGNAL_AT_REST_SCHEME,
  SignalAtRestWriteError,
  validateSignalAtRestEnvelopeForWrite,
  type SignalAtRestExpectedBinding,
} from "../signalAtRestWrite.js";

const b64 = (s: string): string => Buffer.from(s, "utf8").toString("base64");

const EXPECTED: SignalAtRestExpectedBinding = {
  uid: "uid-1",
  collection: "mobile_assistant_chats",
  docId: "thread-1",
  field: "signalEnvelope",
};

interface Overrides {
  binding?: Record<string, unknown>;
  envelope?: Record<string, unknown>;
  keyDelivery?: Record<string, unknown>;
  ciphertextLayer?: Record<string, unknown>;
  wrap?: Record<string, unknown>;
}

// Build a strict at-rest CloudVault envelope whose base64 fields ROUND-TRIP (the
// contract's base64 validator re-encodes and compares), bound to EXPECTED by default.
function atRestEnvelope(overrides: Overrides = {}): Record<string, unknown> {
  return {
    signalEnvelopeFormatVersion: 1,
    mode: "at-rest",
    relayEncryption: "signal-hpke-identity-seal-v1",
    ciphertextLayer: {
      payloadCiphertextB64: b64("sealed-payload-bytes"),
      payloadAADLabel: "bindingToAAD-sha256:0123456789abcdef0123456789abcdef",
      schemaVersion: 1,
      ...overrides.ciphertextLayer,
    },
    keyDelivery: {
      scheme: "signal-hpke-identity-seal-v1",
      contentKeyLength: 32,
      wraps: [
        {
          recipientKind: "device",
          recipientIdentityKeyId: "device-key-1",
          recipientIdentityKeyB64: b64("public-key-bytes-x"),
          sealedContentKeyB64: b64("sealed-content-key"),
          ...overrides.wrap,
        },
      ],
      ...overrides.keyDelivery,
    },
    binding: {
      uid: "uid-1",
      scope: "cloudvault",
      collection: "mobile_assistant_chats",
      docId: "thread-1",
      field: "signalEnvelope",
      mode: "at-rest",
      formatVersion: 1,
      ...overrides.binding,
    },
    ...overrides.envelope,
  };
}

describe("validateSignalAtRestEnvelopeForWrite (L23 + L37 admin)", () => {
  it("mirrors the canonical registry's Signal-at-rest collection enablement", () => {
    const registry = JSON.parse(
      readFileSync(join(process.cwd(), "..", "packages", "data-domains", "registry.json"), "utf8"),
    ) as {
      domains: Array<{
        sealingScheme?: string;
        signalSealedCollections?: string[];
      }>;
    };
    const registryRequiredCollections = registry.domains
      .filter((domain) => domain.sealingScheme === SIGNAL_AT_REST_SCHEME)
      .flatMap((domain) => domain.signalSealedCollections ?? [])
      .sort();

    expect([...SIGNAL_AT_REST_REQUIRED_COLLECTIONS].sort()).toEqual(registryRequiredCollections);
  });

  it("can evaluate a future Signal-at-rest collection policy without changing current registry state", () => {
    expect(isSignalAtRestRequiredForCollection("cloud_search_knowledge")).toBe(false);
    expect(isSignalAtRestRequiredForCollection("cloud_search_knowledge", ["cloud_search_knowledge"])).toBe(true);
    expect(isSignalAtRestRequiredForCollection("knowledge_sync_manifests", ["cloud_search_knowledge"])).toBe(false);
  });

  it("accepts a strict at-rest envelope bound to the expected path and derives the canonical AAD", () => {
    const result = validateSignalAtRestEnvelopeForWrite(atRestEnvelope(), EXPECTED);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.envelope.binding.docId).toBe("thread-1");
      // Byte-for-byte the cross-language bindingToAAD grammar (empty clientId/slotId).
      expect(result.aad).toBe(
        "OpenBurnBar-Signal-AAD-v1|at-rest|cloudvault|uid-1||mobile_assistant_chats|thread-1|signalEnvelope||1",
      );
    }
  });

  it("rejects non-objects, arrays, and plaintext", () => {
    for (const bad of [null, undefined, 42, "x", [], { plaintext: "secret" }]) {
      expect(validateSignalAtRestEnvelopeForWrite(bad, EXPECTED).ok).toBe(false);
    }
  });

  it("rejects binding relocation per coordinate (uid/collection/docId/field)", () => {
    const cases: Array<[Record<string, unknown>, string]> = [
      [{ uid: "attacker" }, "binding-uid-mismatch"],
      [{ collection: "cli_agent_mission_requests" }, "binding-collection-mismatch"],
      [{ docId: "thread-999" }, "binding-docid-mismatch"],
      [{ field: "sealedPayload" }, "binding-field-mismatch"],
    ];
    for (const [binding, reason] of cases) {
      const result = validateSignalAtRestEnvelopeForWrite(atRestEnvelope({ binding }), EXPECTED);
      expect(result.ok).toBe(false);
      if (!result.ok) expect(result.reason).toBe(reason);
    }
  });

  it("rejects mode/scope confusion (the binding can never claim transport/gateway)", () => {
    expect(validateSignalAtRestEnvelopeForWrite(atRestEnvelope({ binding: { scope: "gateway" } }), EXPECTED).ok).toBe(
      false,
    );
    expect(validateSignalAtRestEnvelopeForWrite(atRestEnvelope({ binding: { mode: "transport" } }), EXPECTED).ok).toBe(
      false,
    );
    expect(validateSignalAtRestEnvelopeForWrite(atRestEnvelope({ envelope: { mode: "transport" } }), EXPECTED).ok).toBe(
      false,
    );
    expect(
      validateSignalAtRestEnvelopeForWrite(
        atRestEnvelope({ envelope: { relayEncryption: "signal-doubleratchet-pqxdh-v1" } }),
        EXPECTED,
      ).ok,
    ).toBe(false);
  });

  it("rejects forbidden-field pollution (gateway-only fields on a cloudvault binding, transport relayKeyVersion)", () => {
    expect(validateSignalAtRestEnvelopeForWrite(atRestEnvelope({ binding: { clientId: "c1" } }), EXPECTED).ok).toBe(
      false,
    );
    expect(validateSignalAtRestEnvelopeForWrite(atRestEnvelope({ binding: { slotId: "s1" } }), EXPECTED).ok).toBe(
      false,
    );
    expect(
      validateSignalAtRestEnvelopeForWrite(atRestEnvelope({ envelope: { relayKeyVersion: 4 } }), EXPECTED).ok,
    ).toBe(false);
  });

  it("rejects deep per-wrap corruption the Firestore rules cannot iterate to see", () => {
    expect(
      validateSignalAtRestEnvelopeForWrite(atRestEnvelope({ wrap: { sealedContentKeyB64: "not base64 !!" } }), EXPECTED)
        .ok,
    ).toBe(false);
    expect(
      validateSignalAtRestEnvelopeForWrite(atRestEnvelope({ wrap: { recipientKind: "server" } }), EXPECTED).ok,
    ).toBe(false);
    expect(validateSignalAtRestEnvelopeForWrite(atRestEnvelope({ keyDelivery: { wraps: [] } }), EXPECTED).ok).toBe(
      false,
    );
    expect(
      validateSignalAtRestEnvelopeForWrite(atRestEnvelope({ keyDelivery: { contentKeyLength: 16 } }), EXPECTED).ok,
    ).toBe(false);
  });

  it("STRIPS additive pollution from the persisted envelope — callers write result.envelope, never the raw input", () => {
    const result = validateSignalAtRestEnvelopeForWrite(
      atRestEnvelope({ envelope: { smuggled: "x" }, ciphertextLayer: { smuggled: "y" } }),
      EXPECTED,
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect("smuggled" in result.envelope).toBe(false);
      expect("smuggled" in result.envelope.ciphertextLayer).toBe(false);
    }
  });

  it("assert* throws SignalAtRestWriteError carrying the reason, and returns the envelope on success", () => {
    try {
      assertSignalAtRestEnvelopeForWrite(atRestEnvelope({ binding: { docId: "wrong" } }), EXPECTED);
      throw new Error("expected SignalAtRestWriteError");
    } catch (error) {
      expect(error).toBeInstanceOf(SignalAtRestWriteError);
      expect((error as SignalAtRestWriteError).reason).toBe("binding-docid-mismatch");
    }
    const ok = assertSignalAtRestEnvelopeForWrite(atRestEnvelope(), EXPECTED);
    expect(ok.envelope.binding.uid).toBe("uid-1");
  });
});
