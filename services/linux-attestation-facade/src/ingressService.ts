import { PublicError } from "./errors.js";
import type { IngressTicketCredential } from "./ingressTicket.js";
import type { CompleteUploadResult, EnrollmentCandidate, EnrollmentRecord, EnrollmentStore, EvidenceObjectStore, IngressTicketStore, RegistrarClient, RegistrarIdentity, UploadReceiptRequest, UploadRecord, UploadStateStore } from "./ports.js";
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
  uploadMaxAttempts: number;
  enrollmentLeaseMillis: number;
  activationLeaseMillis: number;
  enrollmentMaxAttempts: number;
}

function sameRegistrarIdentity(enrollment: EnrollmentRecord, identity: RegistrarIdentity): boolean {
  return identity.agentId === enrollment.agentId
    && identity.akTpmBase64 === enrollment.akTpmBase64
    && identity.ekTpmBase64 === enrollment.ekTpmBase64
    && identity.ekCertificateBase64 === enrollment.ekCertificateBase64;
}

export class IngressService {
  constructor(
    private readonly state: UploadStateStore,
    private readonly objects: EvidenceObjectStore,
    private readonly enrollments: EnrollmentStore,
    private readonly tickets: IngressTicketStore,
    private readonly registrar: RegistrarClient,
    private readonly options: IngressServiceOptions,
    private readonly now: () => number = Date.now,
  ) {}

  async beginEnrollment(uid: string, credential: IngressTicketCredential, request: { deviceId: string; ekCertificateBase64: string; ekTpmBase64: string; akTpmBase64: string }): Promise<{ activationBlob: string }> {
    if (request.deviceId !== deviceIdForAk(request.akTpmBase64)) throw new PublicError(400, "bad_request", "Device ID is not bound to the attestation key");
    const candidate: EnrollmentCandidate = {
      uid,
      deviceId: request.deviceId,
      agentId: deterministicAgentId(uid, request.deviceId),
      akTpmBase64: request.akTpmBase64,
      ekTpmBase64: request.ekTpmBase64,
      ekCertificateBase64: request.ekCertificateBase64,
      tpmEkPem: ekPublicKeyPem(request.ekCertificateBase64),
      active: false,
    };
    const claim = await dependencyCall(() => this.tickets.claimEnrollmentBegin(
      credential,
      candidate,
      this.now(),
      this.options.enrollmentLeaseMillis,
      this.options.enrollmentMaxAttempts,
    ));
    if (claim.kind === "cached") {
      if (!sameEnrollmentIdentity(claim.record, candidate) || claim.record.activationBlob === undefined) throw new PublicError(409, "conflict", "Enrollment state changed");
      return { activationBlob: claim.record.activationBlob };
    }
    if (claim.kind === "busy") throw new PublicError(409, "conflict", "Enrollment is already in progress", true);
    try {
      const response = await dependencyCall(() => this.registrar.begin(candidate.agentId, request.ekCertificateBase64, request.ekTpmBase64, request.akTpmBase64));
      const persisted = await dependencyCall(() => this.tickets.completeEnrollmentBegin(uid, request.deviceId, credential.ticketId, claim.leaseToken, response.activationBlob));
      if (!sameEnrollmentIdentity(persisted, candidate) || persisted.active || persisted.activationBlob === undefined) throw new PublicError(409, "conflict", "Enrollment state changed");
      return { activationBlob: persisted.activationBlob };
    } catch (error) {
      const terminal = error instanceof PublicError && !error.retryable;
      const transition = terminal ? this.tickets.terminalizeEnrollmentBegin.bind(this.tickets) : this.tickets.releaseEnrollmentBegin.bind(this.tickets);
      await transition(uid, request.deviceId, credential.ticketId, claim.leaseToken).catch(() => undefined);
      throw error;
    }
  }

  async completeEnrollment(uid: string, request: { deviceId: string; activationProof: string }): Promise<void> {
    const claim = await dependencyCall(() => this.enrollments.claimActivation(
      uid,
      request.deviceId,
      this.now(),
      this.options.activationLeaseMillis,
    ));
    if (claim.kind === "cached") return;
    if (claim.kind === "busy") throw new PublicError(409, "conflict", "Enrollment activation is already in progress", true);
    const { record: enrollment, leaseToken } = claim;
    let mutationAttempted = false;
    try {
      const before = await dependencyCall(() => this.registrar.getActiveIdentity(enrollment.agentId));
      if (before !== undefined) {
        if (!sameRegistrarIdentity(enrollment, before)) {
          await dependencyCall(() => this.tickets.terminalizePendingEnrollment(uid, request.deviceId, enrollment.agentId, leaseToken));
          throw new PublicError(409, "conflict", "Enrollment identity changed");
        }
        await this.commitActivation(uid, request.deviceId, enrollment, leaseToken);
        return;
      }

      await dependencyCall(() => this.enrollments.renewActivation(
        uid,
        request.deviceId,
        leaseToken,
        this.now(),
        this.options.activationLeaseMillis,
      ));
      mutationAttempted = true;
      let activationError: unknown;
      try {
        await dependencyCall(() => this.registrar.activate(enrollment.agentId, request.activationProof));
      } catch (error) {
        activationError = error;
      }

      const after = await dependencyCall(() => this.registrar.getActiveIdentity(enrollment.agentId));
      if (after !== undefined) {
        if (!sameRegistrarIdentity(enrollment, after)) {
          await dependencyCall(() => this.tickets.terminalizePendingEnrollment(uid, request.deviceId, enrollment.agentId, leaseToken));
          throw new PublicError(409, "conflict", "Enrollment identity changed");
        }
        await this.commitActivation(uid, request.deviceId, enrollment, leaseToken);
        return;
      }
      if (activationError !== undefined) {
        if (activationError instanceof PublicError && !activationError.retryable) {
          await dependencyCall(() => this.tickets.terminalizePendingEnrollment(uid, request.deviceId, enrollment.agentId, leaseToken));
        }
        if (activationError instanceof Error) throw activationError;
        throw new PublicError(503, "dependency_unavailable", "Attestation service is temporarily unavailable", true);
      }
      throw new PublicError(503, "dependency_unavailable", "Attestation service is temporarily unavailable", true);
    } catch (error) {
      if (!mutationAttempted) {
        await this.enrollments.releaseActivation(uid, request.deviceId, leaseToken).catch(() => undefined);
      }
      throw error;
    }
  }

  async createUpload(uid: string, credential: IngressTicketCredential, request: Omit<UploadReceiptRequest, "uid" | "expiresAtMillis">): Promise<{ uploadId: string; expiresAtMillis: number }> {
    if (request.expectedSize > this.options.maxEvidenceBytes) throw new PublicError(413, "payload_too_large", "Evidence payload is too large");
    const record = await dependencyCall(() => this.tickets.claimUpload(credential, { ...request, uid }, this.now()));
    return { uploadId: record.uploadId, expiresAtMillis: record.expiresAtMillis };
  }

  async beginUploadAttempt(uid: string, uploadId: string): Promise<UploadRecord> {
    return dependencyCall(() => this.state.claimUploadAttempt(uploadId, uid, this.now(), this.options.uploadMaxAttempts));
  }

  async upload(uid: string, uploadId: string, bytes: Buffer, claimed?: UploadRecord): Promise<CompleteUploadResult> {
    const record = claimed ?? await this.beginUploadAttempt(uid, uploadId);
    if (record.uid !== uid || record.uploadId !== uploadId) throw new PublicError(409, "conflict", "Upload state changed");
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

  private async commitActivation(uid: string, deviceId: string, enrollment: EnrollmentRecord, leaseToken: string): Promise<void> {
    try {
      await dependencyCall(() => this.enrollments.activate(uid, deviceId, enrollment.agentId, leaseToken));
    } catch (error) {
      const reconciled = await this.enrollments.get(uid, deviceId).catch(() => undefined);
      if (reconciled?.active === true && sameEnrollmentIdentity(reconciled, enrollment)) return;
      throw error;
    }
  }
}
