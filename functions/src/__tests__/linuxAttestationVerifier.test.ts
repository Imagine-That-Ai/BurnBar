import { generateKeyPairSync, sign } from "node:crypto";

import { beforeEach, describe, expect, it, vi } from "vitest";

const { providerFetch } = vi.hoisted(() => ({ providerFetch: vi.fn() }));
vi.mock("../providers/httpClient.js", () => ({ providerFetch }));

import {
  __testing__,
  LINUX_ATTESTATION_KIND,
  RemoteSignedLinuxAttestationVerifier,
  sha256Hex,
  type LinuxAttestationChallenge,
} from "../security/linuxAttestation.js";

const NOW = 1_900_000_000_000;
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const publicKeyBase64 = publicKey.export({ format: "der", type: "spki" }).toString("base64");

function challenge(): LinuxAttestationChallenge {
  return {
    uid: "user-1",
    appId: "1:123456:web:abcdef",
    deviceId: "device-1",
    appVersion: "1.0.30",
    architecture: "x86_64",
    releaseDigestSha256: "a".repeat(64),
    policyId: "openburnbar-linux-policy-v1",
    attestationKind: LINUX_ATTESTATION_KIND,
    challengeId: "challenge-id-1",
    challenge: "challenge-value-012345678901234567890123456789",
    expiresAtMillis: NOW + 120_000,
    protocolVersion: 1,
  };
}

function signedEnvelope(input: LinuxAttestationChallenge) {
  const verdict = {
    v: 1 as const,
    issuer: "https://attest.burnbar.ai",
    audience: "openburnbar-linux-app-check",
    decision: "allow" as const,
    uid: input.uid,
    appId: input.appId,
    deviceId: input.deviceId,
    appVersion: input.appVersion,
    architecture: input.architecture,
    releaseDigestSha256: input.releaseDigestSha256,
    policyId: input.policyId,
    attestationKind: input.attestationKind,
    challengeId: input.challengeId,
    challengeHashSha256: sha256Hex(input.challenge),
    trustClass: "linux_lower_trust" as const,
    verifierReceiptHash: "b".repeat(64),
    attestedAtMillis: NOW,
    expiresAtMillis: NOW + 60_000,
  };
  return {
    algorithm: "Ed25519" as const,
    keyId: "linux-attestation-key-1",
    verdict,
    signatureBase64: sign(null, Buffer.from(__testing__.canonicalVerdict(verdict)), privateKey).toString("base64"),
  };
}

function verifier(): RemoteSignedLinuxAttestationVerifier {
  return new RemoteSignedLinuxAttestationVerifier({
    endpoint: new URL("https://attest.burnbar.ai/v1/verify"),
    publicKeyBase64,
    keyId: "linux-attestation-key-1",
    issuer: "https://attest.burnbar.ai",
    audience: "openburnbar-linux-app-check",
  });
}

describe("remote signed Linux attestation verifier", () => {
  beforeEach(() => providerFetch.mockReset());

  it("accepts only a pinned Ed25519 verdict with exact challenge bindings", async () => {
    const input = challenge();
    providerFetch.mockResolvedValue(new Response(JSON.stringify(signedEnvelope(input)), { status: 200 }));

    await expect(
      verifier().verify({ challenge: input, evidence: { quote: "fixture" }, nowMillis: NOW }),
    ).resolves.toMatchObject({
      uid: input.uid,
      appId: input.appId,
      deviceId: input.deviceId,
      trustClass: "linux_lower_trust",
    });
    expect(providerFetch).toHaveBeenCalledWith(
      "linux-attestation",
      "verify",
      new URL("https://attest.burnbar.ai/v1/verify"),
      expect.objectContaining({ method: "POST" }),
    );
  });

  it("fails closed for forged signatures and mismatched challenge bindings", async () => {
    const input = challenge();
    const forged = signedEnvelope(input);
    forged.signatureBase64 = Buffer.alloc(64, 7).toString("base64");
    providerFetch.mockResolvedValueOnce(new Response(JSON.stringify(forged), { status: 200 }));
    await expect(verifier().verify({ challenge: input, evidence: {}, nowMillis: NOW })).rejects.toThrow(
      /invalid verdict/i,
    );

    const mismatched = signedEnvelope(input);
    mismatched.verdict.deviceId = "other-device";
    mismatched.signatureBase64 = sign(
      null,
      Buffer.from(__testing__.canonicalVerdict(mismatched.verdict)),
      privateKey,
    ).toString("base64");
    providerFetch.mockResolvedValueOnce(new Response(JSON.stringify(mismatched), { status: 200 }));
    await expect(verifier().verify({ challenge: input, evidence: {}, nowMillis: NOW })).rejects.toThrow(
      /invalid verdict/i,
    );
  });

  it("bounds evidence and maps verifier outages without leaking response details", async () => {
    await expect(
      verifier().verify({ challenge: challenge(), evidence: { blob: "x".repeat(513 * 1024) }, nowMillis: NOW }),
    ).rejects.toThrow(/malformed/i);
    expect(providerFetch).not.toHaveBeenCalled();

    providerFetch.mockRejectedValueOnce(new Error("contains-sensitive-upstream-detail"));
    await expect(verifier().verify({ challenge: challenge(), evidence: {}, nowMillis: NOW })).rejects.toThrow(
      /unavailable/i,
    );

    providerFetch.mockResolvedValueOnce(new Response("x".repeat(65 * 1024), { status: 200 }));
    await expect(verifier().verify({ challenge: challenge(), evidence: {}, nowMillis: NOW })).rejects.toThrow(
      /invalid verdict/i,
    );
  });
});
