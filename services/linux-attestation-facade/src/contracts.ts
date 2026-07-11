import {
  base64,
  base64url,
  brokerLabel,
  exactKeys,
  identifier,
  integer,
  object,
  sha256,
  sha256Hex,
} from "./validation.js";
import { PublicError } from "./errors.js";

export const PROTOCOL_VERSION = 1 as const;
export const ATTESTATION_KIND = "tpm2_ima_signed_verdict_v1" as const;

export interface AttestationChallenge {
  uid: string;
  appId: string;
  deviceId: string;
  appVersion: string;
  architecture: string;
  releaseDigestSha256: string;
  policyId: string;
  attestationKind: typeof ATTESTATION_KIND;
  challengeId: string;
  challenge: string;
  expiresAtMillis: number;
  protocolVersion: typeof PROTOCOL_VERSION;
}

export interface EvidenceReceipt {
  uploadId: string;
  generation: string;
  sha256: string;
  size: number;
}

export interface QuoteEvidence {
  schemaVersion: 1;
  deviceId: string;
  quoteAttestationBase64: string;
  quoteSignatureBase64: string;
  quotePcrValuesBase64: string;
  pcrBank: "sha256";
  pcrSelection: readonly [0, 2, 4, 7, 10];
  qualifyingDataSha256: string;
}

export interface EvidenceBundleMetadata {
  descriptorIndex: 0;
  format: "openburnbar_tpm_evidence_bundle_v1";
  byteLength: number;
  sha256: string;
}

export interface VerifyRequest {
  challenge: AttestationChallenge;
  evidence: {
    schemaVersion: 1;
    quote: QuoteEvidence;
    evidenceBundle: EvidenceBundleMetadata;
    upload: EvidenceReceipt;
  };
}

export interface SignedVerdict {
  v: 1;
  issuer: string;
  audience: string;
  decision: "allow";
  uid: string;
  appId: string;
  deviceId: string;
  appVersion: string;
  architecture: string;
  releaseDigestSha256: string;
  policyId: string;
  attestationKind: typeof ATTESTATION_KIND;
  challengeId: string;
  challengeHashSha256: string;
  trustClass: "linux_lower_trust";
  verifierReceiptHash: string;
  attestedAtMillis: number;
  expiresAtMillis: number;
}

export interface SignedVerdictEnvelope {
  algorithm: "Ed25519";
  keyId: string;
  verdict: SignedVerdict;
  signatureBase64: string;
}

const challengeKeys = [
  "uid",
  "appId",
  "deviceId",
  "appVersion",
  "architecture",
  "releaseDigestSha256",
  "policyId",
  "attestationKind",
  "challengeId",
  "challenge",
  "expiresAtMillis",
  "protocolVersion",
] as const;

export function parseChallenge(value: unknown): AttestationChallenge {
  const source = object(value, "challenge");
  exactKeys(source, challengeKeys, "challenge");
  if (
    source.attestationKind !== ATTESTATION_KIND ||
    source.protocolVersion !== PROTOCOL_VERSION
  ) {
    throw new PublicError(
      400,
      "bad_request",
      "Unsupported attestation protocol",
    );
  }
  const challenge = base64url(source.challenge, "challenge.challenge", 32);
  if (Buffer.from(challenge, "base64url").byteLength !== 32)
    throw new PublicError(400, "bad_request", "challenge.challenge is invalid");
  return {
    uid: identifier(source.uid, "challenge.uid"),
    appId: brokerLabel(source.appId, "challenge.appId"),
    deviceId: brokerLabel(source.deviceId, "challenge.deviceId"),
    appVersion: brokerLabel(source.appVersion, "challenge.appVersion", 80),
    architecture: (() => {
      const architecture = brokerLabel(
        source.architecture,
        "challenge.architecture",
      );
      if (architecture !== "aarch64" && architecture !== "x86_64")
        throw new PublicError(
          400,
          "bad_request",
          "challenge.architecture is invalid",
        );
      return architecture;
    })(),
    releaseDigestSha256: sha256Hex(
      source.releaseDigestSha256,
      "challenge.releaseDigestSha256",
    ),
    policyId: brokerLabel(source.policyId, "challenge.policyId"),
    attestationKind: ATTESTATION_KIND,
    challengeId: brokerLabel(source.challengeId, "challenge.challengeId"),
    challenge,
    expiresAtMillis: integer(
      source.expiresAtMillis,
      "challenge.expiresAtMillis",
      1,
      Number.MAX_SAFE_INTEGER,
    ),
    protocolVersion: PROTOCOL_VERSION,
  };
}

export function quoteQualifyingDataSha256(
  challenge: AttestationChallenge,
): string {
  const fields = [
    Buffer.from("openburnbar.linux.tpm-quote.v1", "utf8"),
    Buffer.from(challenge.challenge, "base64url"),
    Buffer.from(challenge.appId, "utf8"),
    Buffer.from(challenge.deviceId, "utf8"),
    Buffer.from(challenge.appVersion, "utf8"),
    Buffer.from(challenge.architecture, "utf8"),
    Buffer.from(challenge.releaseDigestSha256, "utf8"),
    Buffer.from(challenge.policyId, "utf8"),
    Buffer.from(challenge.attestationKind, "utf8"),
  ];
  const separator = Buffer.from([0]);
  return sha256(
    Buffer.concat(
      fields.flatMap((field, index) =>
        index === fields.length - 1 ? [field] : [field, separator],
      ),
    ),
  );
}

export function parseEvidenceReceipt(value: unknown): EvidenceReceipt {
  const source = object(value, "evidence.upload");
  exactKeys(
    source,
    ["uploadId", "generation", "sha256", "size"],
    "evidence.upload",
  );
  return {
    uploadId: identifier(source.uploadId, "evidence.upload.uploadId"),
    generation: identifier(source.generation, "evidence.upload.generation"),
    sha256: sha256Hex(source.sha256, "evidence.upload.sha256"),
    size: integer(source.size, "evidence.upload.size", 1, 16 * 1024 * 1024),
  };
}

export function parseVerifyRequest(value: unknown): VerifyRequest {
  const source = object(value, "request");
  exactKeys(source, ["challenge", "evidence"], "request");
  const evidence = object(source.evidence, "evidence");
  exactKeys(
    evidence,
    ["schemaVersion", "quote", "evidenceBundle", "upload"],
    "evidence",
  );
  if (evidence.schemaVersion !== 1)
    throw new PublicError(400, "bad_request", "Unsupported evidence schema");
  const quote = object(evidence.quote, "evidence.quote");
  exactKeys(
    quote,
    [
      "schemaVersion",
      "deviceId",
      "quoteAttestationBase64",
      "quoteSignatureBase64",
      "quotePcrValuesBase64",
      "pcrBank",
      "pcrSelection",
      "qualifyingDataSha256",
    ],
    "evidence.quote",
  );
  if (
    quote.schemaVersion !== 1 ||
    quote.pcrBank !== "sha256" ||
    !Array.isArray(quote.pcrSelection) ||
    quote.pcrSelection.length !== 5 ||
    quote.pcrSelection.some((value, index) => value !== [0, 2, 4, 7, 10][index])
  ) {
    throw new PublicError(400, "bad_request", "Unsupported quote evidence");
  }
  const quoteEvidence: QuoteEvidence = {
    schemaVersion: 1,
    deviceId: brokerLabel(quote.deviceId, "evidence.quote.deviceId"),
    quoteAttestationBase64: base64(
      quote.quoteAttestationBase64,
      "evidence.quote.quoteAttestationBase64",
      12_288,
    ),
    quoteSignatureBase64: base64(
      quote.quoteSignatureBase64,
      "evidence.quote.quoteSignatureBase64",
      3_072,
    ),
    quotePcrValuesBase64: base64(
      quote.quotePcrValuesBase64,
      "evidence.quote.quotePcrValuesBase64",
      12_288,
    ),
    pcrBank: "sha256",
    pcrSelection: [0, 2, 4, 7, 10],
    qualifyingDataSha256: sha256Hex(
      quote.qualifyingDataSha256,
      "evidence.quote.qualifyingDataSha256",
    ),
  };
  const bundle = object(evidence.evidenceBundle, "evidence.evidenceBundle");
  exactKeys(
    bundle,
    ["descriptorIndex", "format", "byteLength", "sha256"],
    "evidence.evidenceBundle",
  );
  if (
    bundle.descriptorIndex !== 0 ||
    bundle.format !== "openburnbar_tpm_evidence_bundle_v1"
  )
    throw new PublicError(400, "bad_request", "Unsupported evidence bundle");
  return {
    challenge: parseChallenge(source.challenge),
    evidence: {
      schemaVersion: 1,
      quote: quoteEvidence,
      evidenceBundle: {
        descriptorIndex: 0,
        format: "openburnbar_tpm_evidence_bundle_v1",
        byteLength: integer(
          bundle.byteLength,
          "evidence.evidenceBundle.byteLength",
          1,
          16 * 1024 * 1024,
        ),
        sha256: sha256Hex(bundle.sha256, "evidence.evidenceBundle.sha256"),
      },
      upload: parseEvidenceReceipt(evidence.upload),
    },
  };
}

export function canonicalVerdict(verdict: SignedVerdict): string {
  return [
    verdict.v,
    verdict.issuer,
    verdict.audience,
    verdict.decision,
    verdict.uid,
    verdict.appId,
    verdict.deviceId,
    verdict.appVersion,
    verdict.architecture,
    verdict.releaseDigestSha256,
    verdict.policyId,
    verdict.attestationKind,
    verdict.challengeId,
    verdict.challengeHashSha256,
    verdict.trustClass,
    verdict.verifierReceiptHash,
    verdict.attestedAtMillis,
    verdict.expiresAtMillis,
  ].join("\n");
}
