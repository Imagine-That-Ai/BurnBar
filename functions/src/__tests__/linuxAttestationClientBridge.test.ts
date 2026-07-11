import { generateKeyPairSync } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { beforeEach, describe, expect, it, vi } from "vitest";

const { providerFetch } = vi.hoisted(() => ({ providerFetch: vi.fn() }));
vi.mock("../providers/httpClient.js", () => ({ providerFetch }));

import {
  LINUX_ATTESTATION_KIND,
  RemoteSignedLinuxAttestationVerifier,
  parseLinuxAttestationEvidence,
  type LinuxAttestationChallenge,
} from "../security/linuxAttestation.js";
import {
  LINUX_ATTESTATION_MAX_EVIDENCE_BYTES,
  parseLinuxUploadTicketRequest,
} from "../security/linuxAttestationIngressTickets.js";

interface Golden {
  uploadTicketCallableRequest: { data: Record<string, unknown> };
  ingressCreateRequest: Record<string, unknown>;
  uploadReceiptResponse: { receipt: Record<string, unknown> };
  mintCallableRequest: {
    data: {
      attestation: {
        challengeId: string;
        challenge: string;
        kind: string;
        evidence: Record<string, unknown>;
      };
    };
  };
}

const GOLDEN_PATH = resolve(process.cwd(), "../tests/fixtures/linux-attestation/client-bridge-v1-golden.json");
const golden = JSON.parse(readFileSync(GOLDEN_PATH, "utf8")) as Golden;
const NOW = 1_900_000_000_000;
const UID = "linux-user-1";
const { publicKey } = generateKeyPairSync("ed25519");
const publicKeyBase64 = publicKey.export({ format: "der", type: "spki" }).toString("base64");
const authorizationHeader = "Bearer eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJmaXh0dXJlIn0.signature";
const identityTokenProvider = { getAuthorizationHeader: vi.fn() };

function challenge(): LinuxAttestationChallenge {
  const request = golden.ingressCreateRequest;
  const attestation = golden.mintCallableRequest.data.attestation;
  return {
    uid: UID,
    appId: String(request.appId),
    deviceId: String(request.deviceId),
    appVersion: "1.0.30",
    architecture: "x86_64",
    releaseDigestSha256: String(request.releaseDigestSha256),
    policyId: "openburnbar-linux-tpm2-ima-v1",
    attestationKind: LINUX_ATTESTATION_KIND,
    challengeId: attestation.challengeId,
    challenge: attestation.challenge,
    expiresAtMillis: NOW + 300_000,
    protocolVersion: 1,
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

describe("Linux attestation client bridge", () => {
  beforeEach(() => {
    providerFetch.mockReset().mockRejectedValue(new Error("stop after request capture"));
    identityTokenProvider.getAuthorizationHeader.mockReset().mockResolvedValue(authorizationHeader);
  });

  it("parses the exact upload-ticket callable payload and enforces the 16 MiB ceiling", () => {
    expect(parseLinuxUploadTicketRequest(golden.uploadTicketCallableRequest.data, UID)).toEqual({
      uid: UID,
      ...golden.uploadTicketCallableRequest.data,
    });

    expect(
      parseLinuxUploadTicketRequest(
        {
          ...golden.uploadTicketCallableRequest.data,
          expectedSize: LINUX_ATTESTATION_MAX_EVIDENCE_BYTES,
        },
        UID,
      ).expectedSize,
    ).toBe(LINUX_ATTESTATION_MAX_EVIDENCE_BYTES);
    expect(() =>
      parseLinuxUploadTicketRequest(
        {
          ...golden.uploadTicketCallableRequest.data,
          expectedSize: LINUX_ATTESTATION_MAX_EVIDENCE_BYTES + 1,
        },
        UID,
      ),
    ).toThrow(/expectedSize/i);
    expect(() =>
      parseLinuxUploadTicketRequest(
        {
          ...golden.uploadTicketCallableRequest.data,
          unknown: true,
        },
        UID,
      ),
    ).toThrow(/unknown fields/i);
  });

  it("parses the receipt-native mint attestation without changing its evidence", () => {
    const attestation = golden.mintCallableRequest.data.attestation;
    expect(parseLinuxAttestationEvidence(attestation)).toEqual(attestation);
    expect(attestation.evidence).toMatchObject({
      schemaVersion: 1,
      upload: golden.uploadReceiptResponse.receipt,
    });
  });

  it("preserves the complete receipt-native evidence through Functions normalization", async () => {
    const evidence = golden.mintCallableRequest.data.attestation.evidence;
    await expect(verifier().verify({ challenge: challenge(), evidence, nowMillis: NOW })).rejects.toThrow(
      /unavailable/i,
    );

    expect(providerFetch).toHaveBeenCalledTimes(1);
    const request = providerFetch.mock.calls[0]?.[3] as { body?: string } | undefined;
    expect(typeof request?.body).toBe("string");
    const forwarded = JSON.parse(request?.body ?? "null") as {
      challenge: LinuxAttestationChallenge;
      evidence: unknown;
    };
    expect(forwarded.challenge).toEqual(challenge());
    expect(forwarded.evidence).toEqual(evidence);
    expect(JSON.stringify(forwarded.evidence)).toBe(JSON.stringify(evidence));
  });
});
