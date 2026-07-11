import { PublicError } from "./errors.js";
import type { Clock, EnrollmentRecord, EnrollmentStore, EvidenceObjectStore, KeylimeVerifier, PolicyStore, UploadRecord, UploadStateStore, VerdictSigner } from "./ports.js";
import type { SignedVerdict, SignedVerdictEnvelope, VerifyRequest } from "./contracts.js";
import { canonicalVerdict, quoteQualifyingDataSha256 } from "./contracts.js";
import { sameEnrollmentIdentity } from "./enrollment.js";
import { parseEvidenceBundle, verifyInstalledManifest } from "./evidenceBundle.js";
import { sha256 } from "./validation.js";

export interface VerifierServiceOptions {
  issuer: string;
  audience: string;
  maxEvidenceBytes: number;
  verdictTtlMillis: number;
  verificationLeaseMillis: number;
  maxClockSkewMillis: number;
}

function assertEnrollmentUnchanged(initial: EnrollmentRecord, latest: EnrollmentRecord): void {
  if (!sameEnrollmentIdentity(initial, latest)) {
    throw new PublicError(403, "verification_failed", "Device attestation was not accepted");
  }
}

export class VerifierService {
  constructor(
    private readonly state: UploadStateStore,
    private readonly objects: EvidenceObjectStore,
    private readonly enrollments: EnrollmentStore,
    private readonly policies: PolicyStore,
    private readonly keylime: KeylimeVerifier,
    private readonly signer: VerdictSigner,
    private readonly clock: Clock,
    private readonly options: VerifierServiceOptions,
  ) {}

  async verify(request: VerifyRequest): Promise<SignedVerdictEnvelope> {
    const now = this.clock.nowMillis();
    if (request.challenge.expiresAtMillis + this.options.maxClockSkewMillis < now) {
      throw new PublicError(400, "bad_request", "Attestation challenge has expired");
    }
    const fingerprint = sha256(JSON.stringify(request));
    const claim = await this.state.claimVerification(request.evidence.upload.uploadId, fingerprint, now, this.options.verificationLeaseMillis);
    if (claim.kind === "cached") return claim.envelope;
    if (claim.kind === "busy") throw new PublicError(409, "conflict", "Verification is already in progress", true);

    const record = claim.record;
    const leaseToken = claim.leaseToken;
    try {
      this.assertReceiptBinding(request, record);
      const upload = request.evidence.upload;
      const bytes = await this.objects.read(record.objectName, upload.generation, this.options.maxEvidenceBytes);
      if (bytes.byteLength !== upload.size || sha256(bytes) !== upload.sha256) {
        throw new PublicError(400, "bad_request", "Evidence receipt is invalid");
      }
      const bundle = parseEvidenceBundle(bytes);
      if (request.evidence.quote.deviceId !== request.challenge.deviceId
        || request.evidence.quote.qualifyingDataSha256 !== quoteQualifyingDataSha256(request.challenge)) {
        throw new PublicError(400, "bad_request", "Evidence is not bound to this challenge");
      }
      const enrollment = await this.enrollments.requireActive(request.challenge.uid, request.challenge.deviceId);
      const policy = await this.policies.get(request.challenge);
      verifyInstalledManifest(bundle, request.challenge, policy.releaseManifestPublicKeyPem);
      const result = await this.keylime.verify({
        agentId: enrollment.agentId,
        akTpmBase64: enrollment.akTpmBase64,
        tpmEkPem: enrollment.tpmEkPem,
        quoteAttestationBase64: request.evidence.quote.quoteAttestationBase64,
        quoteSignatureBase64: request.evidence.quote.quoteSignatureBase64,
        quotePcrValuesBase64: request.evidence.quote.quotePcrValuesBase64,
        pcrBank: request.evidence.quote.pcrBank,
        pcrSelection: request.evidence.quote.pcrSelection,
        qualifyingDataSha256: request.evidence.quote.qualifyingDataSha256,
        imaMeasurementList: bundle.imaLog,
        measuredBootLog: bundle.uefiLog,
      }, policy);
      if (!result.valid) {
        throw new PublicError(403, "verification_failed", "Device attestation was not accepted");
      }
      assertEnrollmentUnchanged(enrollment, await this.enrollments.requireActive(request.challenge.uid, request.challenge.deviceId));
      const attestedAtMillis = this.clock.nowMillis();
      if (request.challenge.expiresAtMillis <= attestedAtMillis) {
        throw new PublicError(400, "bad_request", "Attestation challenge has expired");
      }
      const verdict: SignedVerdict = {
        v: 1,
        issuer: this.options.issuer,
        audience: this.options.audience,
        decision: "allow",
        uid: request.challenge.uid,
        appId: request.challenge.appId,
        deviceId: request.challenge.deviceId,
        appVersion: request.challenge.appVersion,
        architecture: request.challenge.architecture,
        releaseDigestSha256: request.challenge.releaseDigestSha256,
        policyId: request.challenge.policyId,
        attestationKind: request.challenge.attestationKind,
        challengeId: request.challenge.challengeId,
        challengeHashSha256: sha256(request.challenge.challenge),
        trustClass: "linux_lower_trust",
        verifierReceiptHash: sha256(JSON.stringify({ evidenceSha256: upload.sha256, policyVersion: policy.version, keylimeReceipt: result.receipt })),
        attestedAtMillis,
        expiresAtMillis: Math.min(request.challenge.expiresAtMillis, attestedAtMillis + this.options.verdictTtlMillis),
      };
      const signature = await this.signer.sign(Buffer.from(canonicalVerdict(verdict), "utf8"));
      const envelope: SignedVerdictEnvelope = { algorithm: "Ed25519", keyId: this.signer.keyId, verdict, signatureBase64: signature.toString("base64") };
      await this.state.completeVerification(record.uploadId, fingerprint, leaseToken, envelope);
      return envelope;
    } catch (error) {
      if (error instanceof PublicError && !error.retryable && error.code !== "dependency_unavailable" && error.code !== "internal") {
        await this.state.rejectVerification(record.uploadId, fingerprint, leaseToken);
        throw error;
      }
      await this.state.releaseVerification(record.uploadId, fingerprint, leaseToken);
      if (error instanceof PublicError) throw error;
      throw new PublicError(503, "dependency_unavailable", "Attestation verifier is temporarily unavailable", true);
    }
  }

  private assertReceiptBinding(request: VerifyRequest, record: UploadRecord): void {
    const matches = record.status === "verifying"
      && record.uid === request.challenge.uid
      && record.appId === request.challenge.appId
      && record.deviceId === request.challenge.deviceId
      && record.challengeId === request.challenge.challengeId
      && record.releaseDigestSha256 === request.challenge.releaseDigestSha256
      && request.evidence.evidenceBundle.byteLength === request.evidence.upload.size
      && request.evidence.evidenceBundle.sha256 === request.evidence.upload.sha256
      && record.expectedSha256 === request.evidence.upload.sha256
      && record.expectedSize === request.evidence.upload.size
      && record.generation === request.evidence.upload.generation;
    if (!matches) throw new PublicError(400, "bad_request", "Evidence receipt is not bound to this challenge");
  }
}
