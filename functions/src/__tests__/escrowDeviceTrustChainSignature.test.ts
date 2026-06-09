import { createHash } from "node:crypto";

import { describe, expect, it } from "vitest";

import { __testing__ } from "../callables/computerUseSecurity.js";

const {
  buildCloudVaultDeviceTrustChainCanonicalBytes,
  verifyXEdDSACurve25519Signature,
  verifyCloudVaultDeviceTrustChainSignature,
  montgomeryUToCompressedEdwards,
  CLOUD_VAULT_DEVICE_TRUST_CHAIN_DOMAIN,
} = __testing__;

/**
 * B1 — server-side device-trust-chain signature verification.
 *
 * The trust chain is signed with libsignal's XEd25519 (`generateSignature`) over
 * a Curve25519 identity key whose public form is the 33-byte DJB serialization
 * `0x05 || Montgomery-u(32)`. These vectors were emitted by the REAL libsignal
 * library (Vendor/libsignal/rust/core, `KeyPair::calculate_signature` over the
 * exact canonical bytes `CloudVaultDeviceTrustChain.canonicalPayload` produces)
 * and were confirmed to `verify_signature` == true inside libsignal itself —
 * triangulated cross-language proof that our pure `node:crypto` XEdDSA verifier
 * accepts genuine libsignal signatures and rejects forgeries. Two vectors cover
 * BOTH the sign-bit-0 and sign-bit-1 cases (libsignal carries the Edwards x sign
 * bit in the high bit of signature byte 63).
 */

// The 33-byte serialized DJB public key (0x05 || X) — hex.
// The fingerprint embedded in the canonical payload is base64(SHA-256(33-byte key)).
type Vector = { keyHex: string; fingerprintB64: string; signatureHex: string; signBit: 0 | 1 };

const SIGN_BIT_0_VECTOR: Vector = {
  keyHex: "05b78dac0eed34359a3ee17946359fb3a0db099cb2f808c669c56047da7bdf4310",
  fingerprintB64: "IBv9432oDiF3nPWOmYZ8p0SyDjo9Jr/JcV0t8c5ubs4=",
  signatureHex:
    "10e0bbcdc204d8a94e74bb8cdc628c1ed34c480dbd4c0b3aa074b5f02afbad133be8c595f28935c51c636bfa76e6236d00fee05e52a8af5cab09dcdfdbed6b0c",
  signBit: 0,
};

const SIGN_BIT_1_VECTOR: Vector = {
  keyHex: "05e496f6ee85fc5bbdfc6715085e461486045d09ad3de054895e13fd62f5245235",
  fingerprintB64: "//lYiSW5WPgD13m2Q19M8O9alQVZpQ8WM3RgKFtaUvI=",
  signatureHex:
    "eb1e1101d3c7f8d3657a85adf482afff2af488fdc1fcd40cd7ca7b6bff43b2e54a9ee4c2138e832f1d00e86305a60f020fcc9492fd1c1121035750dda6260787",
  signBit: 1,
};

const VECTORS: Array<{ name: string; vector: Vector }> = [
  { name: "sign-bit 0", vector: SIGN_BIT_0_VECTOR },
  { name: "sign-bit 1", vector: SIGN_BIT_1_VECTOR },
];

/**
 * The canonical fields the KAT vectors were signed over. Five are server-sourced
 * (uid, targetDeviceId, targetEscrow*, targetKeyVersion, approverDeviceId), four
 * come from the proof — matching the production reconstruction. The approver
 * fingerprint is the only field that varies per vector (it is SHA-256 of the key).
 */
function canonicalFields(fingerprintB64: string) {
  return {
    uid: "user-1",
    targetDeviceId: "mac-1",
    targetEscrowPublicKeyFingerprint: "escrow-fingerprint",
    targetKeyVersion: 1,
    targetSignalIdentityKeyId: "mac-1_1",
    targetSignalIdentityPublicKeyFingerprint: "signal-fingerprint",
    approverDeviceId: "phone-a",
    approverSignalIdentityKeyId: "phone-a_1",
    approverSignalIdentityPublicKeyFingerprint: fingerprintB64,
  };
}

describe("CloudVault device-trust-chain canonical payload (B1)", () => {
  it("matches the Swift length-prefixed layout byte-for-byte", () => {
    const bytes = buildCloudVaultDeviceTrustChainCanonicalBytes(canonicalFields("FPR=="));
    // Domain line carries NO length prefix; every key/value line is `{utf8len}:{seg}\n`.
    expect(bytes.toString("utf8")).toBe(
      `${CLOUD_VAULT_DEVICE_TRUST_CHAIN_DOMAIN}\n` +
        "3:uid\n6:user-1\n" +
        "14:targetDeviceId\n5:mac-1\n" +
        "32:targetEscrowPublicKeyFingerprint\n18:escrow-fingerprint\n" +
        "16:targetKeyVersion\n1:1\n" +
        "25:targetSignalIdentityKeyId\n7:mac-1_1\n" +
        "40:targetSignalIdentityPublicKeyFingerprint\n18:signal-fingerprint\n" +
        "16:approverDeviceId\n7:phone-a\n" +
        "27:approverSignalIdentityKeyId\n9:phone-a_1\n" +
        "42:approverSignalIdentityPublicKeyFingerprint\n5:FPR==\n",
    );
  });

  it("uses UTF-8 BYTE length (not char length) for multibyte segments", () => {
    // "café" is 4 chars / 5 UTF-8 bytes; the prefix MUST be the byte count or the
    // server bytes diverge from the Swift `segment.data(using: .utf8)?.count`.
    const bytes = buildCloudVaultDeviceTrustChainCanonicalBytes({
      ...canonicalFields("FPR=="),
      targetDeviceId: "café",
    });
    expect(bytes.toString("utf8")).toContain("14:targetDeviceId\n5:café\n");
  });
});

describe("libsignal XEd25519 signature verification (B1)", () => {
  for (const { name, vector } of VECTORS) {
    describe(name, () => {
      const key = Buffer.from(vector.keyHex, "hex");
      const signature = Buffer.from(vector.signatureHex, "hex");
      const payload = buildCloudVaultDeviceTrustChainCanonicalBytes(canonicalFields(vector.fingerprintB64));

      it("the vector's embedded fingerprint is SHA-256(33-byte key) (self-consistency)", () => {
        expect(createHash("sha256").update(key).digest("base64")).toBe(vector.fingerprintB64);
      });

      it("the signature carries the expected Edwards x sign bit", () => {
        expect((signature[63] & 0x80) >> 7).toBe(vector.signBit);
      });

      it("ACCEPTS a genuine libsignal signature over the canonical bytes", () => {
        expect(verifyXEdDSACurve25519Signature(key, payload, signature)).toBe(true);
      });

      it("REJECTS a forged/garbage signature", () => {
        const garbage = Buffer.alloc(64, 0xab);
        expect(verifyXEdDSACurve25519Signature(key, payload, garbage)).toBe(false);
      });

      it("REJECTS a one-byte-flipped signature", () => {
        const tampered = Buffer.from(signature);
        tampered[5] ^= 0x01;
        expect(verifyXEdDSACurve25519Signature(key, payload, tampered)).toBe(false);
      });

      it("REJECTS the signature over a tampered payload (any field change)", () => {
        const tampered = buildCloudVaultDeviceTrustChainCanonicalBytes({
          ...canonicalFields(vector.fingerprintB64),
          targetDeviceId: "mac-2", // attacker re-targets the approval
        });
        expect(verifyXEdDSACurve25519Signature(key, tampered, signature)).toBe(false);
      });

      it("REJECTS verification under a DIFFERENT approver key (key substitution)", () => {
        const otherKey = Buffer.from(SIGN_BIT_1_VECTOR.keyHex, "hex");
        if (otherKey.equals(key)) return; // only meaningful when keys differ
        expect(verifyXEdDSACurve25519Signature(otherKey, payload, signature)).toBe(false);
      });
    });
  }

  it("REJECTS a wrong-length key / wrong type byte / wrong-length signature (fail closed)", () => {
    const v = SIGN_BIT_0_VECTOR;
    const key = Buffer.from(v.keyHex, "hex");
    const sig = Buffer.from(v.signatureHex, "hex");
    const payload = buildCloudVaultDeviceTrustChainCanonicalBytes(canonicalFields(v.fingerprintB64));
    expect(verifyXEdDSACurve25519Signature(key.subarray(0, 32), payload, sig)).toBe(false); // 32 not 33
    const wrongType = Buffer.from(key);
    wrongType[0] = 0x04; // not the DJB 0x05 type byte
    expect(verifyXEdDSACurve25519Signature(wrongType, payload, sig)).toBe(false);
    expect(verifyXEdDSACurve25519Signature(key, payload, sig.subarray(0, 63))).toBe(false);
  });

  it("montgomeryUToCompressedEdwards returns null when u + 1 ≡ 0 (no Edwards image)", () => {
    // u = p - 1 ⇒ u + 1 ≡ 0 mod p. 32 LE bytes of (p - 1).
    const p = (1n << 255n) - 19n;
    const uMinus = p - 1n;
    const buf = Buffer.alloc(32);
    let x = uMinus;
    for (let i = 0; i < 32; i += 1) {
      buf[i] = Number(x & 0xffn);
      x >>= 8n;
    }
    expect(montgomeryUToCompressedEdwards(buf, 0)).toBeNull();
  });
});

describe("verifyCloudVaultDeviceTrustChainSignature (server entrypoint, B1)", () => {
  const v = SIGN_BIT_0_VECTOR;
  const fields = canonicalFields(v.fingerprintB64);
  const keyB64 = Buffer.from(v.keyHex, "hex").toString("base64");
  const sigB64 = Buffer.from(v.signatureHex, "hex").toString("base64");

  it("ACCEPTS a genuine signature against the published base64 key bytes", () => {
    expect(
      verifyCloudVaultDeviceTrustChainSignature({
        approverPublicKeyDataBase64: keyB64,
        signatureBase64: sigB64,
        canonicalFields: fields,
      }),
    ).toBe(true);
  });

  it("REJECTS when the approver public key is absent / non-string (fail closed)", () => {
    for (const bad of [undefined, null, 123, "", "   "]) {
      expect(
        verifyCloudVaultDeviceTrustChainSignature({
          approverPublicKeyDataBase64: bad,
          signatureBase64: sigB64,
          canonicalFields: fields,
        }),
      ).toBe(false);
    }
  });

  it("REJECTS a garbage base64 signature", () => {
    const garbageSig = Buffer.alloc(64, 0xcd).toString("base64");
    expect(
      verifyCloudVaultDeviceTrustChainSignature({
        approverPublicKeyDataBase64: keyB64,
        signatureBase64: garbageSig,
        canonicalFields: fields,
      }),
    ).toBe(false);
  });

  it("REJECTS when ANY server-sourced canonical field is tampered (binding holds)", () => {
    for (const mutate of [
      { uid: "attacker" },
      { targetDeviceId: "other-device" },
      { targetEscrowPublicKeyFingerprint: "swapped" },
      { targetKeyVersion: 2 },
      { approverDeviceId: "someone-else" },
    ] as const) {
      expect(
        verifyCloudVaultDeviceTrustChainSignature({
          approverPublicKeyDataBase64: keyB64,
          signatureBase64: sigB64,
          canonicalFields: { ...fields, ...mutate },
        }),
      ).toBe(false);
    }
  });

  it("REJECTS a non-base64 / wrong-length published key (fail closed)", () => {
    expect(
      verifyCloudVaultDeviceTrustChainSignature({
        approverPublicKeyDataBase64: "!!! not base64 !!!",
        signatureBase64: sigB64,
        canonicalFields: fields,
      }),
    ).toBe(false);
    expect(
      verifyCloudVaultDeviceTrustChainSignature({
        approverPublicKeyDataBase64: Buffer.from(v.keyHex, "hex").subarray(0, 20).toString("base64"),
        signatureBase64: sigB64,
        canonicalFields: fields,
      }),
    ).toBe(false);
  });
});
