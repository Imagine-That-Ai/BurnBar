/**
 * F2 — key-kind-aware phone-control authority signature verification.
 *
 * `verifyPhoneControlAuthoritySignature` is the single crypto seam every F2
 * lane funnels through (publish, queued grants, local-auth proofs). It must
 * byte-mirror the Swift `PhoneControlVerifyingKey`:
 *  - keyKind "ed25519" (the legacy default): Ed25519 over a raw 32-byte key;
 *  - keyKind "se-p256": ECDSA-P256-over-SHA256 in the fixed-size raw `r||s`
 *    wire form ("ieee-p1363") under a 65-byte x9.63 (0x04-prefixed) key.
 * Anything else — DER signatures, non-canonical base64, malformed or off-curve
 * keys, cross-algorithm confusion — must fail CLOSED (return false, never
 * throw) on the se-p256 lane.
 *
 * Also proves the keyKind threading through `verifyAgentGrantLocalAuthProof`:
 * an absent `authorityKeyKind` stays the legacy Ed25519 default, and an
 * SE-P256-signed proof only verifies when the matching kind is supplied.
 */

import { generateKeyPairSync, sign, type KeyObject } from "node:crypto";

import { describe, expect, it } from "vitest";

import { __testing__ } from "../callables/computerUseSecurity.js";

const {
  verifyPhoneControlAuthoritySignature,
  verifyEd25519RawSignature,
  verifyAgentGrantLocalAuthProof,
  agentGrantLocalAuthProofSignablePayload,
  P256_X963_PUBLIC_KEY_BYTE_LENGTH,
} = __testing__;

const PAYLOAD = Buffer.from("OpenBurnBar.PhoneControl.test-payload.v1", "utf8");

function ed25519Pair(): { rawPublicKey: Buffer; privateKey: KeyObject } {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const publicDer = publicKey.export({ type: "spki", format: "der" });
  return { rawPublicKey: publicDer.subarray(publicDer.length - 32), privateKey };
}

function p256Pair(): { x963: Buffer; privateKey: KeyObject } {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" });
  // EC JWKs always carry x/y; the fallbacks only satisfy the optional typing.
  const x963 = Buffer.concat([Buffer.from([0x04]), Buffer.from(jwk.x ?? "", "base64url"), Buffer.from(jwk.y ?? "", "base64url")]);
  return { x963, privateKey };
}

function signP256Raw(payload: Buffer, privateKey: KeyObject): Buffer {
  return sign("sha256", payload, { key: privateKey, dsaEncoding: "ieee-p1363" });
}

describe("verifyPhoneControlAuthoritySignature — ed25519 (legacy) lane", () => {
  it("accepts a genuine Ed25519 raw signature and agrees with the legacy verifier", () => {
    const { rawPublicKey, privateKey } = ed25519Pair();
    const signature = sign(null, PAYLOAD, privateKey).toString("base64");

    expect(verifyPhoneControlAuthoritySignature(rawPublicKey, "ed25519", PAYLOAD, signature)).toBe(true);
    expect(verifyEd25519RawSignature(rawPublicKey, PAYLOAD, signature)).toBe(true);
  });

  it("rejects a signature over a different payload", () => {
    const { rawPublicKey, privateKey } = ed25519Pair();
    const signature = sign(null, Buffer.from("tampered"), privateKey).toString("base64");

    expect(verifyPhoneControlAuthoritySignature(rawPublicKey, "ed25519", PAYLOAD, signature)).toBe(false);
  });
});

describe("verifyPhoneControlAuthoritySignature — se-p256 lane", () => {
  it("accepts a genuine ECDSA-P256/SHA-256 raw r||s signature under an x9.63 key", () => {
    const { x963, privateKey } = p256Pair();
    const signature = signP256Raw(PAYLOAD, privateKey);

    expect(x963.length).toBe(P256_X963_PUBLIC_KEY_BYTE_LENGTH);
    expect(signature.length).toBe(64);
    expect(verifyPhoneControlAuthoritySignature(x963, "se-p256", PAYLOAD, signature.toString("base64"))).toBe(true);
  });

  it("rejects a signature over a different payload", () => {
    const { x963, privateKey } = p256Pair();
    const signature = signP256Raw(Buffer.from("tampered"), privateKey).toString("base64");

    expect(verifyPhoneControlAuthoritySignature(x963, "se-p256", PAYLOAD, signature)).toBe(false);
  });

  it("rejects a signature minted by a different key", () => {
    const { x963 } = p256Pair();
    const attacker = p256Pair();
    const signature = signP256Raw(PAYLOAD, attacker.privateKey).toString("base64");

    expect(verifyPhoneControlAuthoritySignature(x963, "se-p256", PAYLOAD, signature)).toBe(false);
  });

  it("rejects a DER-encoded ECDSA signature — only the fixed-size raw wire form is valid", () => {
    const { x963, privateKey } = p256Pair();
    const derSignature = sign("sha256", PAYLOAD, privateKey); // default DER encoding, ~70 bytes

    expect(derSignature.length).not.toBe(64);
    expect(verifyPhoneControlAuthoritySignature(x963, "se-p256", PAYLOAD, derSignature.toString("base64"))).toBe(false);
  });

  it("rejects non-canonical base64 for an otherwise valid signature", () => {
    const { x963, privateKey } = p256Pair();
    const canonical = signP256Raw(PAYLOAD, privateKey).toString("base64");
    const paddingStripped = canonical.replace(/=+$/u, "");

    expect(paddingStripped).not.toBe(canonical);
    expect(verifyPhoneControlAuthoritySignature(x963, "se-p256", PAYLOAD, canonical)).toBe(true);
    expect(verifyPhoneControlAuthoritySignature(x963, "se-p256", PAYLOAD, paddingStripped)).toBe(false);
  });

  it("rejects an Ed25519-shaped 32-byte key without throwing", () => {
    const { privateKey } = p256Pair();
    const { rawPublicKey } = ed25519Pair();
    const signature = signP256Raw(PAYLOAD, privateKey).toString("base64");

    expect(verifyPhoneControlAuthoritySignature(rawPublicKey, "se-p256", PAYLOAD, signature)).toBe(false);
  });

  it("rejects a compressed (0x02-prefixed) P-256 key — only uncompressed x9.63 is pinned", () => {
    const { x963, privateKey } = p256Pair();
    const compressed = Buffer.concat([
      Buffer.from([x963[33 + 31] % 2 === 0 ? 0x02 : 0x03]),
      x963.subarray(1, 33),
    ]);
    const signature = signP256Raw(PAYLOAD, privateKey).toString("base64");

    expect(verifyPhoneControlAuthoritySignature(compressed, "se-p256", PAYLOAD, signature)).toBe(false);
  });

  it("fails closed (false, no throw) on a well-formed but off-curve key", () => {
    const { privateKey } = p256Pair();
    const offCurve = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(32, 0xab), Buffer.alloc(32, 0xcd)]);
    const signature = signP256Raw(PAYLOAD, privateKey).toString("base64");

    expect(offCurve.length).toBe(P256_X963_PUBLIC_KEY_BYTE_LENGTH);
    expect(verifyPhoneControlAuthoritySignature(offCurve, "se-p256", PAYLOAD, signature)).toBe(false);
  });

  it("rejects an Ed25519 signature presented under the se-p256 kind (cross-algorithm confusion)", () => {
    const { x963 } = p256Pair();
    const ed = ed25519Pair();
    // Ed25519 signatures are also exactly 64 bytes, so this exercises the
    // cryptographic verify rather than the length gate.
    const signature = sign(null, PAYLOAD, ed.privateKey);

    expect(signature.length).toBe(64);
    expect(verifyPhoneControlAuthoritySignature(x963, "se-p256", PAYLOAD, signature.toString("base64"))).toBe(false);
  });
});

describe("verifyAgentGrantLocalAuthProof — authorityKeyKind threading", () => {
  const INTENT_HASH = "ab".repeat(32);

  function buildProof(signWith: (payload: Buffer) => Buffer) {
    const proof = {
      proofId: "proof-1",
      deviceId: "iphone-1",
      signedIntentHash: INTENT_HASH,
      authenticatedAt: 789_000_000.25,
      expiresAt: 789_000_240.25,
      signatureEd25519: "",
    };
    proof.signatureEd25519 = signWith(agentGrantLocalAuthProofSignablePayload(proof)).toString("base64");
    return proof;
  }

  function optionsWith(authorityPublicKey: Buffer, authorityKeyKind?: "ed25519" | "se-p256") {
    return {
      sourceDeviceId: "iphone-1",
      observedIntentHashHex: INTENT_HASH,
      nowReferenceSeconds: 789_000_010.25,
      authorityPublicKey,
      authorityKeyKind,
    };
  }

  it("verifies an SE-P256-signed proof when authorityKeyKind is se-p256", () => {
    const { x963, privateKey } = p256Pair();
    const proof = buildProof((payload) => signP256Raw(payload, privateKey));

    expect(verifyAgentGrantLocalAuthProof(proof, optionsWith(x963, "se-p256"))).toBe("ok");
  });

  it("returns bad_signature for an SE-P256 proof minted by a different key", () => {
    const { x963 } = p256Pair();
    const attacker = p256Pair();
    const proof = buildProof((payload) => signP256Raw(payload, attacker.privateKey));

    expect(verifyAgentGrantLocalAuthProof(proof, optionsWith(x963, "se-p256"))).toBe("bad_signature");
  });

  it("defaults an absent authorityKeyKind to the legacy Ed25519 verify (pre-F2 compatibility)", () => {
    const { rawPublicKey, privateKey } = ed25519Pair();
    const proof = buildProof((payload) => sign(null, payload, privateKey));

    expect(verifyAgentGrantLocalAuthProof(proof, optionsWith(rawPublicKey))).toBe("ok");
  });

  it("returns bad_signature when an ECDSA signature is replayed against an Ed25519 authority", () => {
    const { rawPublicKey } = ed25519Pair();
    const p256 = p256Pair();
    const proof = buildProof((payload) => signP256Raw(payload, p256.privateKey));

    expect(verifyAgentGrantLocalAuthProof(proof, optionsWith(rawPublicKey))).toBe("bad_signature");
  });
});
