import { createHash, generateKeyPairSync } from "node:crypto";

import { describe, expect, it } from "vitest";

import { __testing__ } from "../callables/computerUseSecurity.js";

const { ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED, recomputeEscrowFingerprint, evaluateEscrowFingerprintBinding } =
  __testing__;

/**
 * Stream 6 enablement — server-side device-key fingerprint enforcement.
 *
 * Proves the approve path can recompute the canonical fingerprint from the real
 * x9.63 P-256 public-key bytes and reject a stored fingerprint that does not
 * correspond to them — while staying inert (flag OFF) until activation. Mirrors
 * the native `EscrowDeviceSafetyCode` key-bound binding.
 */

/** Generate a real P-256 key and return its uncompressed x9.63 (65-byte) public key as base64. */
function realPublicKeyBase64(): string {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const der = publicKey.export({ type: "spki", format: "der" });
  // SPKI for P-256 ends with the 65-byte 0x04||X||Y point; slice the trailing 65 bytes.
  const point = der.subarray(der.length - 65);
  expect(point.length).toBe(65);
  expect(point[0]).toBe(0x04);
  return point.toString("base64");
}

/** The canonical fingerprint exactly as native + registerBrowserEscrowDevice compute it. */
function canonicalFingerprint(publicKeyBase64: string): string {
  return createHash("sha256").update(Buffer.from(publicKeyBase64, "base64")).digest("base64");
}

describe("escrow device fingerprint enforcement (Stream 6)", () => {
  it("ships enforcing (F2): device-key fingerprint binding is ON", () => {
    expect(ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED).toBe(true);
  });

  describe("recomputeEscrowFingerprint", () => {
    it("matches the canonical SHA-256 of the key bytes (native parity)", () => {
      const key = realPublicKeyBase64();
      expect(recomputeEscrowFingerprint(key)).toBe(canonicalFingerprint(key));
    });

    it("matches the Swift golden vector (cross-language parity)", () => {
      // Same (key, fingerprint) pair asserted by
      // EscrowDeviceSafetyCodeTests.testRecomputeFingerprintMatchesServerGoldenVector.
      const key = "BF8kD8cxysQZYfK+E5P47VMA2Kyf7qQ8SSJh0QB3RkparBtbyeL7XrAue1wanXNo0KUc5OzpAtUWp6oWSYrKzfM=";
      expect(recomputeEscrowFingerprint(key)).toBe("gpX18YwBJijSAfecJvCp7Fmc5wM+uzmwJxbbGcoGoAw=");
    });

    it("fails closed on absent / non-string / malformed keys", () => {
      expect(recomputeEscrowFingerprint(undefined)).toBeNull();
      expect(recomputeEscrowFingerprint(null)).toBeNull();
      expect(recomputeEscrowFingerprint("")).toBeNull();
      expect(recomputeEscrowFingerprint("   ")).toBeNull();
      expect(recomputeEscrowFingerprint(123)).toBeNull();
      // Valid base64 but wrong length / wrong prefix.
      expect(recomputeEscrowFingerprint(Buffer.from([0x04, 0x01, 0x02]).toString("base64"))).toBeNull();
      const wrongPrefix = Buffer.concat([Buffer.from([0x05]), Buffer.alloc(64, 0xab)]);
      expect(recomputeEscrowFingerprint(wrongPrefix.toString("base64"))).toBeNull();
      // Non-base64 garbage.
      expect(recomputeEscrowFingerprint("!!! not base64 !!!")).toBeNull();
    });

    it("rejects a well-formed-but-OFF-CURVE P-256 point (native CryptoKit parity)", () => {
      // 0x04 || X(32) || Y(32) with X = Y = 0xAB repeated: correct 65-byte x9.63
      // shape and 0x04 prefix, valid canonical base64 — but (X, Y) is NOT a point
      // on the P-256 curve. Native CryptoKit rejects off-curve points on import;
      // the server must too, or a chosen off-curve key whose SHA-256 matches a
      // stored fingerprint could be admitted. Fail closed → null.
      const offCurve = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 0xab)]);
      expect(offCurve.length).toBe(65);
      expect(offCurve[0]).toBe(0x04);
      expect(recomputeEscrowFingerprint(offCurve.toString("base64"))).toBeNull();

      // A real on-curve key with the SAME length/prefix still fingerprints fine,
      // proving the rejection is the curve check and not a length/prefix regression.
      const onCurve = realPublicKeyBase64();
      expect(recomputeEscrowFingerprint(onCurve)).toBe(canonicalFingerprint(onCurve));
    });
  });

  describe("evaluateEscrowFingerprintBinding", () => {
    it("accepts a stored fingerprint that is the honest SHA-256 of the key", () => {
      const key = realPublicKeyBase64();
      const stored = canonicalFingerprint(key);
      const result = evaluateEscrowFingerprintBinding(stored, key);
      expect(result).toEqual({ ok: true, reason: "match" });
    });

    it("tolerates surrounding whitespace on the stored fingerprint", () => {
      const key = realPublicKeyBase64();
      const stored = `  ${canonicalFingerprint(key)}\n`;
      expect(evaluateEscrowFingerprintBinding(stored, key).ok).toBe(true);
    });

    it("REJECTS a server-spoofed fingerprint unrelated to the key bytes", () => {
      const key = realPublicKeyBase64();
      const attacker = createHash("sha256").update(Buffer.from("attacker-supplied-key")).digest("base64");
      const result = evaluateEscrowFingerprintBinding(attacker, key);
      expect(result).toEqual({ ok: false, reason: "fingerprint_mismatch" });
    });

    it("REJECTS the right fingerprint paired with a DIFFERENT key (key substitution)", () => {
      const realKey = realPublicKeyBase64();
      const otherKey = realPublicKeyBase64();
      const storedForReal = canonicalFingerprint(realKey);
      // Approver shows the fingerprint of the real key but the device published other bytes.
      const result = evaluateEscrowFingerprintBinding(storedForReal, otherKey);
      expect(result).toEqual({ ok: false, reason: "fingerprint_mismatch" });
    });

    it("treats a device with no public key on file as nothing-to-enforce (ok)", () => {
      // Backward compatible: pre-Stream-6 devices that never published key bytes
      // must not be bricked when the flag flips — there is nothing to bind to.
      expect(evaluateEscrowFingerprintBinding(canonicalFingerprint(realPublicKeyBase64()), undefined)).toEqual({
        ok: true,
        reason: "missing_public_key",
      });
      expect(evaluateEscrowFingerprintBinding("anything", "")).toEqual({ ok: true, reason: "missing_public_key" });
    });

    it("fails closed when a key is present but the stored fingerprint is missing/blank", () => {
      const key = realPublicKeyBase64();
      expect(evaluateEscrowFingerprintBinding(undefined, key)).toEqual({ ok: false, reason: "missing_fingerprint" });
      expect(evaluateEscrowFingerprintBinding("", key)).toEqual({ ok: false, reason: "missing_fingerprint" });
      expect(evaluateEscrowFingerprintBinding("   ", key)).toEqual({ ok: false, reason: "missing_fingerprint" });
    });

    it("fails closed when the stored public key bytes are malformed", () => {
      const malformed = Buffer.from([0x04, 0x01]).toString("base64");
      expect(evaluateEscrowFingerprintBinding(canonicalFingerprint(realPublicKeyBase64()), malformed)).toEqual({
        ok: false,
        reason: "invalid_public_key",
      });
    });

    it("rejects a truncated stored fingerprint (length mismatch, no early-out)", () => {
      const key = realPublicKeyBase64();
      const full = Buffer.from(canonicalFingerprint(key), "base64");
      const truncated = full.subarray(0, 16).toString("base64");
      expect(evaluateEscrowFingerprintBinding(truncated, key)).toEqual({ ok: false, reason: "fingerprint_mismatch" });
    });
  });
});
