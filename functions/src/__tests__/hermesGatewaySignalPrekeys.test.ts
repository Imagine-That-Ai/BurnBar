import { describe, expect, it } from "vitest";

import {
  parseGatewaySignalPrekeyBundle,
  sameGatewaySignalIdentity,
} from "../hermesGatewaySignalPrekeys.js";
import { parsePhoneSignalPairing } from "../callables/hermesGatewayApproveSignal.js";
import { sanitizeGatewayRelayEnvelopeCapabilities } from "../hermesGatewayEnvelope.js";
import type { HermesGatewaySignalPrekeyBundleDoc } from "../types/generated/hermes-gateway.js";

function validBundle(overrides: Partial<HermesGatewaySignalPrekeyBundleDoc> = {}): HermesGatewaySignalPrekeyBundleDoc {
  return {
    version: 1,
    bundleId: "sig_bundle_00000001",
    identityKeyId: "sig_identity_00000001",
    identityKeyB64: Buffer.alloc(33, 1).toString("base64"),
    registrationId: 12_345,
    deviceId: 1,
    signedPreKeyId: 101,
    signedPreKeyPublicB64: Buffer.alloc(33, 2).toString("base64"),
    signedPreKeySignatureB64: Buffer.alloc(64, 3).toString("base64"),
    oneTimePreKeyId: 201,
    oneTimePreKeyPublicB64: Buffer.alloc(33, 4).toString("base64"),
    kyberPreKeyId: 301,
    kyberPreKeyPublicB64: Buffer.alloc(1_569, 5).toString("base64"),
    kyberPreKeySignatureB64: Buffer.alloc(64, 6).toString("base64"),
    generatedAt: "2026-08-04T00:00:00.000Z",
    ...overrides,
  };
}

function fail(message: string): never {
  throw new Error(message);
}

describe("Hermes Gateway Signal PQXDH prekey bundle parser", () => {
  it("accepts and canonicalizes the exact official-libsignal public wire sizes", () => {
    const bundle = validBundle();
    expect(parseGatewaySignalPrekeyBundle({ agentSignalPrekeyBundle: bundle }, "agent", fail)).toEqual(bundle);
    expect(parseGatewaySignalPrekeyBundle({ phoneSignalPrekeyBundle: bundle }, "phone", fail)).toEqual(bundle);
  });

  it("accepts the generic field alias used by endpoint-local helpers", () => {
    const bundle = validBundle();
    expect(parseGatewaySignalPrekeyBundle({ signalPrekeyBundle: bundle }, "agent", fail)).toEqual(bundle);
  });

  it("returns undefined only when the entire bundle is absent", () => {
    expect(parseGatewaySignalPrekeyBundle({}, "agent", fail)).toBeUndefined();
    expect(() => parseGatewaySignalPrekeyBundle({ agentSignalPrekeyBundle: {} }, "agent", fail)).toThrow(
      /version must be 1/,
    );
  });

  it("rejects non-canonical base64 and every wrong key/signature length", () => {
    const invalid = [
      validBundle({ identityKeyB64: Buffer.alloc(32).toString("base64") }),
      validBundle({ signedPreKeyPublicB64: Buffer.alloc(34).toString("base64") }),
      validBundle({ signedPreKeySignatureB64: Buffer.alloc(63).toString("base64") }),
      validBundle({ oneTimePreKeyPublicB64: Buffer.alloc(32).toString("base64") }),
      validBundle({ kyberPreKeyPublicB64: Buffer.alloc(1_568).toString("base64") }),
      validBundle({ kyberPreKeySignatureB64: Buffer.alloc(65).toString("base64") }),
      validBundle({ identityKeyB64: "not base64" }),
    ];
    for (const bundle of invalid) {
      expect(() => parseGatewaySignalPrekeyBundle({ agentSignalPrekeyBundle: bundle }, "agent", fail)).toThrow();
    }
  });

  it("rejects out-of-range registration, device, and prekey ids", () => {
    const invalid = [
      validBundle({ registrationId: 0 }),
      validBundle({ registrationId: 16_384 }),
      validBundle({ deviceId: 0 }),
      validBundle({ deviceId: 128 }),
      validBundle({ signedPreKeyId: 0 }),
      validBundle({ oneTimePreKeyId: 2_147_483_648 }),
      validBundle({ kyberPreKeyId: -1 }),
    ];
    for (const bundle of invalid) {
      expect(() => parseGatewaySignalPrekeyBundle({ phoneSignalPrekeyBundle: bundle }, "phone", fail)).toThrow();
    }
  });

  it("rejects unsafe ids and non-canonical timestamps", () => {
    expect(() =>
      parseGatewaySignalPrekeyBundle(
        { agentSignalPrekeyBundle: validBundle({ identityKeyId: "../../identity" }) },
        "agent",
        fail,
      ),
    ).toThrow(/identityKeyId/);
    expect(() =>
      parseGatewaySignalPrekeyBundle(
        { agentSignalPrekeyBundle: validBundle({ generatedAt: "2026-08-04T00:00:00Z" }) },
        "agent",
        fail,
      ),
    ).toThrow(/canonical ISO-8601/);
  });

  it("permits prekey rotation only under an unchanged identity/registration/device pin", () => {
    const pinned = validBundle();
    expect(sameGatewaySignalIdentity(pinned, validBundle({ bundleId: "sig_bundle_00000002", oneTimePreKeyId: 202 }))).toBe(
      true,
    );
    expect(sameGatewaySignalIdentity(pinned, validBundle({ identityKeyId: "sig_identity_00000002" }))).toBe(false);
    expect(sameGatewaySignalIdentity(pinned, validBundle({ identityKeyB64: Buffer.alloc(33, 9).toString("base64") }))).toBe(
      false,
    );
    expect(sameGatewaySignalIdentity(pinned, validBundle({ registrationId: 7 }))).toBe(false);
    expect(sameGatewaySignalIdentity(pinned, validBundle({ deviceId: 2 }))).toBe(false);
  });

  it("requires a phone PQXDH bundle whenever the phone advertises Signal capability", () => {
    const capabilities: ReturnType<typeof sanitizeGatewayRelayEnvelopeCapabilities> = {
      supportsRelayEnvelopeVersions: [1, 2, 3],
      preferredRelayEnvelopeVersion: 3,
      supportsHpkeV3: true,
      supportsSignalEnvelope: true,
    };
    expect(() => parsePhoneSignalPairing({}, capabilities)).toThrow(/missing_phone_signal_prekey_bundle/);

    const bundle = validBundle();
    expect(parsePhoneSignalPairing({ phoneSignalPrekeyBundle: bundle }, capabilities)).toEqual(bundle);
  });
});
