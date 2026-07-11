import { generateKeyPairSync, sign } from "node:crypto";

import { beforeEach, describe, expect, it, vi } from "vitest";

const { providerFetch } = vi.hoisted(() => ({ providerFetch: vi.fn() }));
vi.mock("../providers/httpClient.js", () => ({ providerFetch }));

import {
  __testing__,
  GoogleCloudRunIdentityTokenProvider,
  LINUX_ATTESTATION_KIND,
  RemoteSignedLinuxAttestationVerifier,
  sha256Hex,
  type LinuxAttestationChallenge,
} from "../security/linuxAttestation.js";

const NOW = 1_900_000_000_000;
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const publicKeyBase64 = publicKey.export({ format: "der", type: "spki" }).toString("base64");
const authorizationHeader = "Bearer eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJmaXh0dXJlIn0.signature";
const identityTokenProvider = { getAuthorizationHeader: vi.fn() };

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
    oidcAudience: "https://attest.burnbar.ai",
    publicKeyBase64,
    keyId: "linux-attestation-key-1",
    issuer: "https://attest.burnbar.ai",
    audience: "openburnbar-linux-app-check",
    identityTokenProvider,
  });
}

describe("remote signed Linux attestation verifier", () => {
  beforeEach(() => {
    providerFetch.mockReset();
    identityTokenProvider.getAuthorizationHeader.mockReset().mockResolvedValue(authorizationHeader);
  });

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
      expect.objectContaining({
        method: "POST",
        redirect: "error",
        signal: expect.any(AbortSignal),
        headers: {
          Authorization: authorizationHeader,
          "content-type": "application/json",
          "cache-control": "no-store",
        },
      }),
    );
  });

  it("does not make an unauthenticated request when identity-token acquisition fails", async () => {
    identityTokenProvider.getAuthorizationHeader.mockRejectedValueOnce(new Error("ADC unavailable"));

    await expect(verifier().verify({ challenge: challenge(), evidence: {}, nowMillis: NOW })).rejects.toThrow(
      /unavailable/i,
    );
    expect(providerFetch).not.toHaveBeenCalled();
  });

  it("rejects malformed identity-token headers before making a request", async () => {
    identityTokenProvider.getAuthorizationHeader.mockResolvedValueOnce("Bearer not-a-jwt");

    await expect(verifier().verify({ challenge: challenge(), evidence: {}, nowMillis: NOW })).rejects.toThrow(
      /unavailable/i,
    );
    expect(providerFetch).not.toHaveBeenCalled();
  });

  it("requires the transport OIDC audience to be the exact verifier HTTPS origin", () => {
    const base = {
      endpoint: new URL("https://attest.burnbar.ai/v1/verify"),
      publicKeyBase64,
      keyId: "linux-attestation-key-1",
      issuer: "https://attest.burnbar.ai",
      audience: "openburnbar-linux-app-check",
      identityTokenProvider,
    };

    expect(() => new RemoteSignedLinuxAttestationVerifier({ ...base, oidcAudience: "" })).toThrow(/not configured/i);
    expect(
      () =>
        new RemoteSignedLinuxAttestationVerifier({
          ...base,
          oidcAudience: "https://other-service.example.test",
        }),
    ).toThrow(/not configured/i);
    expect(
      () =>
        new RemoteSignedLinuxAttestationVerifier({
          ...base,
          endpoint: new URL("https://user:password@attest.burnbar.ai/v1/verify"),
          oidcAudience: "https://attest.burnbar.ai",
        }),
    ).toThrow(/not configured/i);
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

describe("Google Cloud Run identity-token provider", () => {
  it("shares one ID-token client across concurrent requests", async () => {
    const getRequestHeaders = vi.fn().mockResolvedValue({ get: () => authorizationHeader });
    const getIdTokenClient = vi.fn().mockResolvedValue({ getRequestHeaders });
    const provider = new GoogleCloudRunIdentityTokenProvider("https://attest.burnbar.ai", { getIdTokenClient });

    await expect(Promise.all([provider.getAuthorizationHeader(), provider.getAuthorizationHeader()])).resolves.toEqual([
      authorizationHeader,
      authorizationHeader,
    ]);
    expect(getIdTokenClient).toHaveBeenCalledTimes(1);
    expect(getIdTokenClient).toHaveBeenCalledWith("https://attest.burnbar.ai");
  });

  it("does not permanently cache a failed ID-token client acquisition", async () => {
    const getIdTokenClient = vi
      .fn()
      .mockRejectedValueOnce(new Error("metadata unavailable"))
      .mockResolvedValueOnce({
        getRequestHeaders: vi.fn().mockResolvedValue({ get: () => authorizationHeader }),
      });
    const provider = new GoogleCloudRunIdentityTokenProvider("https://attest.burnbar.ai", { getIdTokenClient });

    await expect(provider.getAuthorizationHeader()).rejects.toThrow(/metadata unavailable/i);
    await expect(provider.getAuthorizationHeader()).resolves.toBe(authorizationHeader);
    expect(getIdTokenClient).toHaveBeenCalledTimes(2);
  });
});

describe("Linux verifier request deadline", () => {
  it("fails a pending operation when its shared request signal aborts", async () => {
    const controller = new AbortController();
    const operation = __testing__.abortable(new Promise<string>(() => undefined), controller.signal);

    controller.abort(new Error("deadline exceeded"));

    await expect(operation).rejects.toThrow(/deadline exceeded/i);
  });
});
