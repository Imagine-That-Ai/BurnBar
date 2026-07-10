import { randomUUID } from "node:crypto";
import { PublicError } from "./errors.js";
import type { CompleteUploadResult, EnrollmentStore, EvidenceObjectStore, RegistrarClient, UploadReceiptRequest, UploadStateStore } from "./ports.js";
import { sha256 } from "./validation.js";
import { deterministicAgentId, deviceIdForAk, ekPublicKeyPem, sameEnrollmentIdentity } from "./enrollment.js";

async function dependencyCall<T>(operation: () => Promise<T>): Promise<T> {
  try {
    return await operation();
  } catch (error) {
    if (error instanceof PublicError) throw error;
    throw new PublicError(503, "dependency_unavailable", "Attestation service is temporarily unavailable", true);
  }
}

export interface IngressServiceOptions {
  maxEvidenceBytes: number;
  uploadTtlMillis: number;
  enrollmentLeaseMillis: number;
}

export class IngressService {
  constructor(
    private readonly state: UploadStateStore,
    private readonly objects: EvidenceObjectStore,
    private readonly enrollments: EnrollmentStore,
    private readonly registrar: RegistrarClient,
    private readonly options: IngressServiceOptions,
    private readonly now: () => number = Date.now,
    private readonly id: () => string = randomUUID,
  ) {}

  async beginEnrollment(uid: string, request: { deviceId: string; ekCertificateBase64: string; ekTpmBase64: string; akTpmBase64: string }): Promise<{ activationBlob: string }> {
    if (request.deviceId !== deviceIdForAk(request.akTpmBase64)) throw new PublicError(400, "bad_request", "Device ID is not bound to the attestation key");
    const candidate = {
      uid,
      deviceId: request.deviceId,
      agentId: deterministicAgentId(uid, request.deviceId),
      akTpmBase64: request.akTpmBase64,
      ekTpmBase64: request.ekTpmBase64,
      ekCertificateBase64: request.ekCertificateBase64,
      tpmEkPem: ekPublicKeyPem(request.ekCertificateBase64),
      active: false,
    };
    const claim = await dependencyCall(() => this.enrollments.claimRegistration(candidate, this.now(), this.options.enrollmentLeaseMillis));
    if (claim.kind === "cached") {
      if (!sameEnrollmentIdentity(claim.record, candidate) || claim.record.activationBlob === undefined) throw new PublicError(409, "conflict", "Enrollment state changed");
      return { activationBlob: claim.record.activationBlob };
    }
    if (claim.kind === "busy") throw new PublicError(409, "conflict", "Enrollment is already in progress", true);
    try {
      const response = await dependencyCall(() => this.registrar.begin(candidate.agentId, request.ekCertificateBase64, request.ekTpmBase64, request.akTpmBase64));
      const persisted = await dependencyCall(() => this.enrollments.completeRegistration(uid, request.deviceId, claim.leaseToken, response.activationBlob));
      if (!sameEnrollmentIdentity(persisted, candidate) || persisted.active || persisted.activationBlob === undefined) throw new PublicError(409, "conflict", "Enrollment state changed");
      return { activationBlob: persisted.activationBlob };
    } catch (error) {
      await this.enrollments.releaseRegistration(uid, request.deviceId, claim.leaseToken).catch(() => undefined);
      throw error;
    }
  }

  async completeEnrollment(uid: string, request: { deviceId: string; activationProof: string }): Promise<void> {
    const enrollment = await dependencyCall(() => this.enrollments.get(uid, request.deviceId));
    if (enrollment?.active === true) return;
    if (enrollment === undefined || enrollment.activationBlob === undefined) throw new PublicError(409, "conflict", "Enrollment is not pending");
    try {
      await dependencyCall(() => this.registrar.activate(enrollment.agentId, request.activationProof));
    } catch (error) {
      if (error instanceof PublicError && !error.retryable) {
        await dependencyCall(() => this.enrollments.deletePending(uid, request.deviceId, enrollment.agentId));
      }
      throw error;
    }
    await dependencyCall(() => this.enrollments.activate(uid, request.deviceId, enrollment.agentId));
  }

  async createUpload(uid: string, request: Omit<UploadReceiptRequest, "uid" | "expiresAtMillis">): Promise<{ uploadId: string; expiresAtMillis: number }> {
    if (request.expectedSize > this.options.maxEvidenceBytes) throw new PublicError(413, "payload_too_large", "Evidence payload is too large");
    const uploadId = this.id();
    const expiresAtMillis = this.now() + this.options.uploadTtlMillis;
    await dependencyCall(() => this.state.create({
      ...request,
      uid,
      uploadId,
      objectName: `linux-attestation/evidence/${uploadId}`,
      expiresAtMillis,
      status: "pending",
    }));
    return { uploadId, expiresAtMillis };
  }

  async upload(uid: string, uploadId: string, bytes: Buffer): Promise<CompleteUploadResult> {
    const record = await dependencyCall(() => this.state.get(uploadId));
    if (record === undefined) throw new PublicError(404, "not_found", "Upload was not found");
    if (record.uid !== uid) throw new PublicError(403, "forbidden", "Upload does not belong to this user");
    if (record.expiresAtMillis <= this.now()) throw new PublicError(409, "conflict", "Upload has expired");
    if (bytes.byteLength !== record.expectedSize || sha256(bytes) !== record.expectedSha256) {
      throw new PublicError(400, "bad_request", "Evidence payload does not match its declared digest and size");
    }
    if (record.status === "uploaded" && record.generation !== undefined) {
      return { receipt: { uploadId, generation: record.generation, sha256: record.expectedSha256, size: record.expectedSize } };
    }
    if (record.status !== "pending") throw new PublicError(409, "conflict", "Upload has already been used");
    const generation = await dependencyCall(() => this.objects.create(record.objectName, bytes, record.expiresAtMillis));
    const completed = await dependencyCall(() => this.state.completeUpload(uploadId, generation));
    if (completed.generation === undefined) throw new Error("Completed evidence upload has no object generation");
    return { receipt: { uploadId, generation: completed.generation, sha256: record.expectedSha256, size: record.expectedSize } };
  }
}
