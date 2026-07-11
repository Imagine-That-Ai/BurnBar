import { createHash, randomUUID } from "node:crypto";
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { ATTESTATION_KIND, PROTOCOL_VERSION } from "./contracts.js";
import { sameEnrollmentIdentity } from "./enrollment.js";
import { PublicError } from "./errors.js";
import {
  enrollmentMaterialHashes,
  ingressTicketClaimFingerprint,
  ingressTicketSecretHash,
  ticketHashesEqual,
  type IngressTicketCredential,
} from "./ingressTicket.js";
import type { EnrollmentCandidate, EnrollmentRecord, IngressTicketStore, UploadBinding, UploadRecord } from "./ports.js";

type TicketPurpose = "evidence_upload" | "enrollment_begin";
type TicketStatus = "issued" | "claimed" | "executing" | "succeeded" | "terminal";

interface TicketDocument {
  schemaVersion: 1;
  protocolVersion: 1;
  attestationKind: typeof ATTESTATION_KIND;
  ticketId: string;
  purpose: TicketPurpose;
  ticketSecretHashSha256: string;
  uid: string;
  deviceId: string;
  challengeId?: string;
  challengeHashSha256?: string;
  expiresAtMillis: number;
  status: TicketStatus;
  appId?: string;
  releaseDigestSha256?: string;
  expectedSha256?: string;
  expectedSize?: number;
  uploadId?: string;
  akTpmSha256?: string;
  ekTpmSha256?: string;
  ekCertificateSha256?: string;
  claimFingerprintSha256: string;
  claimLeaseToken?: string;
  claimLeaseExpiresAtMillis?: number;
  attemptCount?: number;
}

function documentId(...parts: string[]): string {
  return createHash("sha256").update(parts.join("\n")).digest("hex");
}

function unauthorizedTicket(): PublicError {
  return new PublicError(403, "forbidden", "Attestation ticket is not authorized");
}

function conflict(): PublicError {
  return new PublicError(409, "conflict", "Attestation ticket has already been used");
}

function ticketDocument(raw: FirebaseFirestore.DocumentData | undefined): TicketDocument | undefined {
  if (raw === undefined
      || raw.schemaVersion !== 1
      || raw.protocolVersion !== PROTOCOL_VERSION
      || raw.attestationKind !== ATTESTATION_KIND
      || (raw.purpose !== "evidence_upload" && raw.purpose !== "enrollment_begin")
      || typeof raw.ticketId !== "string"
      || Buffer.from(raw.ticketId, "base64url").byteLength !== 16
      || Buffer.from(raw.ticketId, "base64url").toString("base64url") !== raw.ticketId
      || typeof raw.ticketSecretHashSha256 !== "string"
      || !/^[a-f0-9]{64}$/u.test(raw.ticketSecretHashSha256)
      || typeof raw.claimFingerprintSha256 !== "string"
      || !/^[a-f0-9]{64}$/u.test(raw.claimFingerprintSha256)
      || typeof raw.uid !== "string"
      || typeof raw.deviceId !== "string"
      || typeof raw.expiresAtMillis !== "number"
      || !Number.isSafeInteger(raw.expiresAtMillis)
      || !["issued", "claimed", "executing", "succeeded", "terminal"].includes(String(raw.status))) {
    return undefined;
  }
  if (raw.purpose === "evidence_upload"
      && (typeof raw.challengeId !== "string"
        || typeof raw.challengeHashSha256 !== "string"
        || typeof raw.uploadId !== "string"
        || Buffer.from(raw.uploadId, "base64url").byteLength !== 16
        || Buffer.from(raw.uploadId, "base64url").toString("base64url") !== raw.uploadId)) return undefined;
  return raw as TicketDocument;
}

function assertBaseTicket(
  raw: FirebaseFirestore.DocumentData | undefined,
  credential: IngressTicketCredential,
  uid: string,
  purpose: TicketPurpose,
  nowMillis: number,
): TicketDocument {
  const ticket = ticketDocument(raw);
  if (ticket === undefined
      || ticket.ticketId !== credential.ticketId
      || ticket.uid !== uid
      || ticket.purpose !== purpose
      || ticket.expiresAtMillis <= nowMillis
      || !ticketHashesEqual(ticket.ticketSecretHashSha256, ingressTicketSecretHash(credential.secret))) {
    throw unauthorizedTicket();
  }
  return ticket;
}

function uploadFingerprint(binding: UploadBinding, challengeHashSha256: string): string {
  return ingressTicketClaimFingerprint("evidence_upload", [
    String(PROTOCOL_VERSION),
    ATTESTATION_KIND,
    binding.uid,
    binding.appId,
    binding.deviceId,
    binding.challengeId,
    challengeHashSha256,
    binding.releaseDigestSha256,
    binding.expectedSha256,
    String(binding.expectedSize),
  ]);
}

function enrollmentFingerprint(candidate: EnrollmentCandidate): string {
  const hashes = enrollmentMaterialHashes(candidate);
  return ingressTicketClaimFingerprint("enrollment_begin", [
    String(PROTOCOL_VERSION),
    ATTESTATION_KIND,
    candidate.uid,
    candidate.deviceId,
    hashes.akTpmSha256,
    hashes.ekTpmSha256,
    hashes.ekCertificateSha256,
  ]);
}

function sameUpload(left: UploadRecord, right: UploadRecord): boolean {
  return left.uid === right.uid
    && left.appId === right.appId
    && left.deviceId === right.deviceId
    && left.challengeId === right.challengeId
    && left.releaseDigestSha256 === right.releaseDigestSha256
    && left.expectedSha256 === right.expectedSha256
    && left.expectedSize === right.expectedSize
    && left.uploadId === right.uploadId
    && left.objectName === right.objectName
    && left.expiresAtMillis === right.expiresAtMillis;
}

export class FirestoreIngressTicketStore implements IngressTicketStore {
  constructor(
    private readonly firestore: Firestore,
    private readonly ticketCollection = "linux_attestation_ingress_tickets",
    private readonly uploadCollection = "linux_attestation_uploads",
    private readonly enrollmentCollection = "linux_attestation_enrollments",
  ) {}

  private ticketRef(uid: string, ticketId: string) {
    return this.firestore.doc(`users/${uid}/${this.ticketCollection}/${ticketId}`);
  }

  private uploadRef(uploadId: string) {
    return this.firestore.collection(this.uploadCollection).doc(uploadId);
  }

  private enrollmentRef(uid: string, deviceId: string) {
    return this.firestore.collection(this.enrollmentCollection).doc(documentId(uid, deviceId));
  }

  async claimUpload(credential: IngressTicketCredential, binding: UploadBinding, nowMillis: number): Promise<UploadRecord> {
    return this.firestore.runTransaction(async transaction => {
      const ticketRef = this.ticketRef(binding.uid, credential.ticketId);
      const ticketSnapshot = await transaction.get(ticketRef);
      const ticket = assertBaseTicket(ticketSnapshot.data(), credential, binding.uid, "evidence_upload", nowMillis);
      if (ticket.appId !== binding.appId
          || ticket.deviceId !== binding.deviceId
          || ticket.challengeId !== binding.challengeId
          || typeof ticket.challengeHashSha256 !== "string"
          || ticket.releaseDigestSha256 !== binding.releaseDigestSha256
          || ticket.expectedSha256 !== binding.expectedSha256
          || ticket.expectedSize !== binding.expectedSize
          || typeof ticket.uploadId !== "string"
          || ticket.uploadId.length === 0) {
        throw unauthorizedTicket();
      }
      const fingerprint = uploadFingerprint(binding, ticket.challengeHashSha256);
      if (!ticketHashesEqual(ticket.claimFingerprintSha256, fingerprint)) throw unauthorizedTicket();
      const record: UploadRecord = {
        ...binding,
        uploadId: ticket.uploadId,
        objectName: `linux-attestation/evidence/${ticket.uploadId}`,
        expiresAtMillis: ticket.expiresAtMillis,
        status: "pending",
      };
      const uploadRef = this.uploadRef(record.uploadId);
      const uploadSnapshot = await transaction.get(uploadRef);
      if (ticket.status === "claimed") {
        const existing = uploadSnapshot.data() as UploadRecord | undefined;
        if (existing === undefined || !sameUpload(existing, record)) throw conflict();
        return record;
      }
      if (ticket.status !== "issued" || uploadSnapshot.exists) throw conflict();
      transaction.create(uploadRef, { ...record, expireAt: Timestamp.fromMillis(record.expiresAtMillis) });
      transaction.update(ticketRef, {
        status: "claimed",
        claimedAtMillis: nowMillis,
        claimedAt: Timestamp.fromMillis(nowMillis),
      });
      return record;
    });
  }

  async claimEnrollmentBegin(
    credential: IngressTicketCredential,
    candidate: EnrollmentCandidate,
    nowMillis: number,
    leaseMillis: number,
    maxAttempts: number,
  ): Promise<{ kind: "acquired"; leaseToken: string } | { kind: "cached"; record: EnrollmentRecord } | { kind: "busy" }> {
    const leaseToken = randomUUID();
    const fingerprint = enrollmentFingerprint(candidate);
    const outcome = await this.firestore.runTransaction(async transaction => {
      const ticketRef = this.ticketRef(candidate.uid, credential.ticketId);
      const enrollmentRef = this.enrollmentRef(candidate.uid, candidate.deviceId);
      const ticketSnapshot = await transaction.get(ticketRef);
      const enrollmentSnapshot = await transaction.get(enrollmentRef);
      const ticket = assertBaseTicket(ticketSnapshot.data(), credential, candidate.uid, "enrollment_begin", nowMillis);
      const hashes = enrollmentMaterialHashes(candidate);
      if (ticket.deviceId !== candidate.deviceId
          || ticket.akTpmSha256 !== hashes.akTpmSha256
          || ticket.ekTpmSha256 !== hashes.ekTpmSha256
          || ticket.ekCertificateSha256 !== hashes.ekCertificateSha256
          || !ticketHashesEqual(ticket.claimFingerprintSha256, fingerprint)) {
        throw unauthorizedTicket();
      }
      const existing = enrollmentSnapshot.data() as EnrollmentRecord | undefined;
      let previousTicketRaw: FirebaseFirestore.DocumentData | undefined;
      let previousTicketExists = false;
      if (existing?.beginTicketId !== undefined && existing.beginTicketId !== ticket.ticketId) {
        const previousTicketSnapshot = await transaction.get(this.ticketRef(candidate.uid, existing.beginTicketId));
        previousTicketRaw = previousTicketSnapshot.data();
        previousTicketExists = previousTicketSnapshot.exists;
      }
      if (ticket.status === "succeeded") {
        if (existing === undefined
            || existing.activationBlob === undefined
            || existing.beginTicketId !== ticket.ticketId
            || !sameEnrollmentIdentity(existing, candidate)) throw conflict();
        return { kind: "cached" as const, record: existing };
      }
      if (ticket.status === "terminal" || ticket.status === "claimed") throw conflict();
      if (ticket.status === "executing" && (ticket.claimLeaseExpiresAtMillis ?? 0) > nowMillis) {
        return { kind: "busy" as const };
      }
      const attemptCount = ticket.attemptCount ?? 0;
      if (attemptCount >= maxAttempts) {
        transaction.update(ticketRef, { status: "terminal", terminalAt: Timestamp.fromMillis(nowMillis) });
        if (existing !== undefined && !existing.active && existing.beginTicketId === ticket.ticketId) transaction.delete(enrollmentRef);
        return { kind: "attempts_exhausted" as const };
      }
      if (existing !== undefined) {
        if (existing.active || !sameEnrollmentIdentity(existing, candidate)) throw conflict();
        if (existing.beginTicketId === undefined) throw conflict();
        if (existing.beginTicketId !== ticket.ticketId) {
          if ((existing.registrationLeaseExpiresAtMillis ?? 0) > nowMillis
              || (existing.activationLeaseExpiresAtMillis ?? 0) > nowMillis) throw conflict();
          const previousTicket = ticketDocument(previousTicketRaw);
          if (previousTicket !== undefined
              && previousTicket.uid === candidate.uid
              && previousTicket.deviceId === candidate.deviceId
              && previousTicket.purpose === "enrollment_begin"
              && previousTicket.status !== "terminal"
              && previousTicket.expiresAtMillis > nowMillis) throw conflict();
          if (previousTicketExists) {
            transaction.update(this.ticketRef(candidate.uid, existing.beginTicketId), {
              status: "terminal",
              terminalAt: Timestamp.fromMillis(nowMillis),
              claimLeaseToken: FieldValue.delete(),
              claimLeaseExpiresAtMillis: FieldValue.delete(),
            });
          }
          if (existing.activationBlob !== undefined) {
            const rebound = { ...existing, beginTicketId: ticket.ticketId };
            delete rebound.registrationLeaseToken;
            delete rebound.registrationLeaseExpiresAtMillis;
            delete rebound.activationLeaseToken;
            delete rebound.activationLeaseExpiresAtMillis;
            transaction.set(enrollmentRef, rebound);
            transaction.update(ticketRef, {
              status: "succeeded",
              claimedAtMillis: nowMillis,
              claimedAt: Timestamp.fromMillis(nowMillis),
            });
            return { kind: "cached" as const, record: rebound };
          }
        }
      }
      const reserved: EnrollmentRecord = {
        ...candidate,
        beginTicketId: ticket.ticketId,
        registrationLeaseToken: leaseToken,
        registrationLeaseExpiresAtMillis: nowMillis + leaseMillis,
      };
      if (enrollmentSnapshot.exists) transaction.set(enrollmentRef, reserved);
      else transaction.create(enrollmentRef, reserved);
      transaction.update(ticketRef, {
        status: "executing",
        claimLeaseToken: leaseToken,
        claimLeaseExpiresAtMillis: nowMillis + leaseMillis,
        attemptCount: attemptCount + 1,
      });
      return { kind: "acquired" as const, leaseToken };
    });
    if (outcome.kind === "attempts_exhausted") {
      throw new PublicError(429, "rate_limited", "Enrollment ticket retry limit was reached");
    }
    return outcome;
  }

  async completeEnrollmentBegin(uid: string, deviceId: string, ticketId: string, leaseToken: string, activationBlob: string): Promise<EnrollmentRecord> {
    return this.firestore.runTransaction(async transaction => {
      const ticketRef = this.ticketRef(uid, ticketId);
      const enrollmentRef = this.enrollmentRef(uid, deviceId);
      const ticketSnapshot = await transaction.get(ticketRef);
      const enrollmentSnapshot = await transaction.get(enrollmentRef);
      const ticket = ticketDocument(ticketSnapshot.data());
      const existing = enrollmentSnapshot.data() as EnrollmentRecord | undefined;
      if (ticket?.status !== "executing"
          || ticket.claimLeaseToken !== leaseToken
          || ticket.uid !== uid
          || ticket.deviceId !== deviceId
          || existing === undefined
          || existing.active
          || existing.beginTicketId !== ticketId
          || existing.registrationLeaseToken !== leaseToken) throw conflict();
      const completed = { ...existing, activationBlob };
      delete completed.registrationLeaseToken;
      delete completed.registrationLeaseExpiresAtMillis;
      transaction.set(enrollmentRef, completed);
      transaction.update(ticketRef, {
        status: "succeeded",
        claimLeaseToken: FieldValue.delete(),
        claimLeaseExpiresAtMillis: FieldValue.delete(),
      });
      return completed;
    });
  }

  async releaseEnrollmentBegin(uid: string, deviceId: string, ticketId: string, leaseToken: string): Promise<void> {
    await this.transitionEnrollmentBegin(uid, deviceId, ticketId, leaseToken, false);
  }

  async terminalizeEnrollmentBegin(uid: string, deviceId: string, ticketId: string, leaseToken: string): Promise<void> {
    await this.transitionEnrollmentBegin(uid, deviceId, ticketId, leaseToken, true);
  }

  private async transitionEnrollmentBegin(uid: string, deviceId: string, ticketId: string, leaseToken: string, terminal: boolean): Promise<void> {
    await this.firestore.runTransaction(async transaction => {
      const ticketRef = this.ticketRef(uid, ticketId);
      const enrollmentRef = this.enrollmentRef(uid, deviceId);
      const ticketSnapshot = await transaction.get(ticketRef);
      const enrollmentSnapshot = await transaction.get(enrollmentRef);
      const ticket = ticketDocument(ticketSnapshot.data());
      const enrollment = enrollmentSnapshot.data() as EnrollmentRecord | undefined;
      if (ticket?.status !== "executing" || ticket.claimLeaseToken !== leaseToken) return;
      if (terminal) {
        transaction.update(ticketRef, {
          status: "terminal",
          claimLeaseToken: FieldValue.delete(),
          claimLeaseExpiresAtMillis: FieldValue.delete(),
        });
        if (enrollment !== undefined && !enrollment.active && enrollment.beginTicketId === ticketId) transaction.delete(enrollmentRef);
      } else {
        transaction.update(ticketRef, {
          status: "issued",
          claimLeaseToken: FieldValue.delete(),
          claimLeaseExpiresAtMillis: FieldValue.delete(),
        });
        if (enrollment !== undefined && !enrollment.active && enrollment.beginTicketId === ticketId) {
          const retryable = { ...enrollment };
          delete retryable.registrationLeaseToken;
          delete retryable.registrationLeaseExpiresAtMillis;
          transaction.set(enrollmentRef, retryable);
        }
      }
    });
  }

  async terminalizePendingEnrollment(uid: string, deviceId: string, agentId: string, activationLeaseToken: string): Promise<void> {
    await this.firestore.runTransaction(async transaction => {
      const enrollmentRef = this.enrollmentRef(uid, deviceId);
      const enrollmentSnapshot = await transaction.get(enrollmentRef);
      const enrollment = enrollmentSnapshot.data() as EnrollmentRecord | undefined;
      if (enrollment === undefined
          || enrollment.active
          || enrollment.agentId !== agentId
          || enrollment.activationLeaseToken !== activationLeaseToken) return;
      if (enrollment.beginTicketId !== undefined) {
        const ticketRef = this.ticketRef(uid, enrollment.beginTicketId);
        const ticketSnapshot = await transaction.get(ticketRef);
        if (ticketSnapshot.exists) transaction.update(ticketRef, { status: "terminal" });
      }
      transaction.delete(enrollmentRef);
    });
  }
}
