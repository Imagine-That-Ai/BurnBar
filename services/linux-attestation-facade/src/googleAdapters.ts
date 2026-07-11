import { readFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { Storage } from "@google-cloud/storage";
import type { Auth } from "firebase-admin/auth";
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { OAuth2Client, type VerifyIdTokenOptions } from "google-auth-library";
import { PublicError } from "./errors.js";
import type { AttestationChallenge, SignedVerdictEnvelope } from "./contracts.js";
import type { AttestationPolicy, EnrollmentRecord, EnrollmentStore, EvidenceObjectStore, PolicyStore, ServiceAuthenticator, UploadRecord, UploadStateStore, UserAuthenticator } from "./ports.js";
import { exactKeys, object, sha256Hex, string } from "./validation.js";
import { enrollmentRevoked, isActiveEnrollment, sameEnrollmentIdentity } from "./enrollment.js";

export class FirebaseUserAuthenticator implements UserAuthenticator {
  constructor(private readonly auth: Auth) {}
  async authenticate(token: string): Promise<{ uid: string }> {
    try {
      const decoded = await this.auth.verifyIdToken(token, true);
      return { uid: decoded.uid };
    } catch {
      throw new PublicError(401, "unauthorized", "Authentication is required");
    }
  }
}

export interface IdTokenVerifier {
  verifyIdToken(options: VerifyIdTokenOptions): Promise<{ getPayload(): { aud?: string | string[]; email?: string; email_verified?: boolean } | undefined }>;
}

export class GoogleOidcAuthenticator implements ServiceAuthenticator {
  constructor(
    private readonly audience: string,
    private readonly callerServiceAccount: string,
    private readonly client: IdTokenVerifier = new OAuth2Client(),
  ) {}
  async authenticate(token: string): Promise<void> {
    try {
      const ticket = await this.client.verifyIdToken({ idToken: token, audience: this.audience });
      const payload = ticket.getPayload();
      if (payload?.aud !== this.audience || payload.email !== this.callerServiceAccount || payload.email_verified !== true) {
        throw new Error("caller mismatch");
      }
    } catch {
      throw new PublicError(401, "unauthorized", "Authentication is required");
    }
  }
}

export class GcsEvidenceObjectStore implements EvidenceObjectStore {
  private readonly bucket;
  constructor(bucketName: string, storage = new Storage()) {
    this.bucket = storage.bucket(bucketName);
  }
  async create(objectName: string, bytes: Buffer, expiresAtMillis: number): Promise<string> {
    const file = this.bucket.file(objectName);
    try {
      await file.save(bytes, {
        resumable: false,
        validation: "crc32c",
        preconditionOpts: { ifGenerationMatch: 0 },
        metadata: {
          contentType: "application/octet-stream",
          cacheControl: "no-store",
          customTime: new Date(expiresAtMillis).toISOString(),
          metadata: { classification: "private-linux-attestation-evidence" },
        },
      });
    } catch (error) {
      const code = typeof error === "object" && error !== null && "code" in error ? Number(error.code) : 0;
      if (code !== 412) throw error;
      const [existing] = await file.download({ validation: "crc32c" });
      if (!existing.equals(bytes)) throw new PublicError(409, "conflict", "Evidence object already exists with different content");
    }
    const [metadata] = await file.getMetadata();
    if (metadata.generation === undefined) throw new Error("GCS did not return an object generation");
    return String(metadata.generation);
  }
  async read(objectName: string, generation: string, maxBytes: number): Promise<Buffer> {
    const file = this.bucket.file(objectName, { generation });
    const [metadata] = await file.getMetadata();
    const size = Number(metadata.size);
    if (!Number.isSafeInteger(size) || size <= 0 || size > maxBytes) {
      throw new PublicError(413, "payload_too_large", "Evidence payload is too large");
    }
    const [bytes] = await file.download({ validation: "crc32c" });
    if (bytes.byteLength !== size || bytes.byteLength > maxBytes) throw new Error("GCS evidence size changed during read");
    return bytes;
  }
}

function recordFromData(data: FirebaseFirestore.DocumentData): UploadRecord {
  return data as UploadRecord;
}

export class FirestoreUploadStateStore implements UploadStateStore {
  constructor(private readonly firestore: Firestore, private readonly collection = "linux_attestation_uploads") {}
  async create(record: UploadRecord): Promise<void> {
    await this.firestore.collection(this.collection).doc(record.uploadId).create(record);
  }
  async get(uploadId: string): Promise<UploadRecord | undefined> {
    const snapshot = await this.firestore.collection(this.collection).doc(uploadId).get();
    const data = snapshot.data();
    return snapshot.exists && data !== undefined ? recordFromData(data) : undefined;
  }
  async claimUploadAttempt(uploadId: string, uid: string, nowMillis: number, maxAttempts: number): Promise<UploadRecord> {
    return this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(uploadId);
      const snapshot = await transaction.get(ref);
      const data = snapshot.data();
      if (!snapshot.exists || data === undefined) throw new PublicError(404, "not_found", "Upload was not found");
      const record = recordFromData(data);
      if (record.uid !== uid) throw new PublicError(403, "forbidden", "Upload does not belong to this user");
      if (record.expiresAtMillis <= nowMillis) throw new PublicError(409, "conflict", "Upload has expired");
      if (record.status !== "pending" && !(record.status === "uploaded" && record.generation !== undefined)) {
        throw new PublicError(409, "conflict", "Upload has already been used");
      }
      const attemptCount = record.uploadAttemptCount ?? 0;
      if (!Number.isSafeInteger(attemptCount) || attemptCount < 0) throw new Error("Upload attempt state is invalid");
      if (attemptCount >= maxAttempts) throw new PublicError(429, "rate_limited", "Evidence upload retry limit was reached");
      const updated = { ...record, uploadAttemptCount: attemptCount + 1 };
      transaction.set(ref, updated);
      return updated;
    });
  }
  async completeUpload(uploadId: string, generation: string): Promise<UploadRecord> {
    return this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(uploadId);
      const snapshot = await transaction.get(ref);
      const data = snapshot.data();
      if (!snapshot.exists || data === undefined) throw new PublicError(404, "not_found", "Upload was not found");
      const record = recordFromData(data);
      if (record.status === "uploaded" && record.generation === generation) return record;
      if (record.status !== "pending") throw new PublicError(409, "conflict", "Upload has already been used");
      const updated: UploadRecord = { ...record, generation, status: "uploaded" };
      transaction.set(ref, updated);
      return updated;
    });
  }
  async claimVerification(uploadId: string, fingerprint: string, nowMillis: number, leaseMillis: number): Promise<{ kind: "acquired"; record: UploadRecord; leaseToken: string } | { kind: "cached"; envelope: SignedVerdictEnvelope } | { kind: "busy" }> {
    return this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(uploadId);
      const snapshot = await transaction.get(ref);
      const data = snapshot.data();
      if (!snapshot.exists || data === undefined) throw new PublicError(404, "not_found", "Evidence upload was not found");
      const record = recordFromData(data);
      if (record.expiresAtMillis <= nowMillis) throw new PublicError(409, "conflict", "Evidence upload has expired");
      if (record.verificationFingerprint !== undefined && record.verificationFingerprint !== fingerprint) {
        throw new PublicError(409, "conflict", "Evidence upload has already been used");
      }
      if (record.status === "verified" && record.result !== undefined) {
        if (record.result.verdict.expiresAtMillis <= nowMillis) throw new PublicError(409, "conflict", "Evidence upload has already been used");
        return { kind: "cached" as const, envelope: record.result };
      }
      if (record.status === "rejected") throw new PublicError(409, "conflict", "Evidence upload has already been used");
      if (record.status === "verifying" && (record.leaseExpiresAtMillis ?? 0) > nowMillis) return { kind: "busy" as const };
      if (record.status !== "uploaded" && record.status !== "verifying") throw new PublicError(409, "conflict", "Evidence upload is not ready");
      const leaseToken = randomUUID();
      const updated: UploadRecord = { ...record, status: "verifying", verificationFingerprint: fingerprint, verificationLeaseToken: leaseToken, leaseExpiresAtMillis: nowMillis + leaseMillis };
      transaction.set(ref, updated);
      return { kind: "acquired" as const, record: updated, leaseToken };
    });
  }
  async completeVerification(uploadId: string, fingerprint: string, leaseToken: string, envelope: SignedVerdictEnvelope): Promise<void> {
    await this.transition(uploadId, fingerprint, leaseToken, "verified", { result: envelope, leaseExpiresAtMillis: FieldValue.delete(), verificationLeaseToken: FieldValue.delete() });
  }
  async rejectVerification(uploadId: string, fingerprint: string, leaseToken: string): Promise<void> {
    await this.transition(uploadId, fingerprint, leaseToken, "rejected", { leaseExpiresAtMillis: FieldValue.delete(), verificationLeaseToken: FieldValue.delete() });
  }
  async releaseVerification(uploadId: string, fingerprint: string, leaseToken: string): Promise<void> {
    await this.transition(uploadId, fingerprint, leaseToken, "uploaded", { leaseExpiresAtMillis: FieldValue.delete(), verificationLeaseToken: FieldValue.delete() });
  }
  private async transition(uploadId: string, fingerprint: string, leaseToken: string, status: UploadRecord["status"], fields: FirebaseFirestore.UpdateData<FirebaseFirestore.DocumentData>): Promise<void> {
    await this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(uploadId);
      const snapshot = await transaction.get(ref);
      const data = snapshot.data();
      if (!snapshot.exists || data?.status !== "verifying" || data.verificationFingerprint !== fingerprint || data.verificationLeaseToken !== leaseToken) {
        throw new PublicError(409, "conflict", "Verification state changed");
      }
      transaction.update(ref, { status, ...fields });
    });
  }
}

function documentId(...parts: string[]): string {
  return createHash("sha256").update(parts.join("\n")).digest("hex");
}

export class FirestoreEnrollmentStore implements EnrollmentStore {
  constructor(private readonly firestore: Firestore, private readonly collection = "linux_attestation_enrollments") {}
  async get(uid: string, deviceId: string): Promise<EnrollmentRecord | undefined> {
    const snapshot = await this.firestore.collection(this.collection).doc(documentId(uid, deviceId)).get();
    return snapshot.exists ? snapshot.data() as EnrollmentRecord : undefined;
  }
  async claimRegistration(record: EnrollmentRecord, nowMillis: number, leaseMillis: number): Promise<{ kind: "acquired"; leaseToken: string } | { kind: "cached"; record: EnrollmentRecord } | { kind: "busy" }> {
    if (record.active || record.activationBlob !== undefined || record.registrationLeaseToken !== undefined) throw new PublicError(400, "bad_request", "Enrollment reservation is invalid");
    return this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(documentId(record.uid, record.deviceId));
      const snapshot = await transaction.get(ref);
      const existing = snapshot.data() as EnrollmentRecord | undefined;
      if (existing !== undefined) {
        if (enrollmentRevoked(existing) || existing.active || !sameEnrollmentIdentity(existing, record)) throw new PublicError(409, "conflict", "Enrollment state changed");
        if (existing.activationBlob !== undefined) return { kind: "cached" as const, record: existing };
        if ((existing.registrationLeaseExpiresAtMillis ?? 0) > nowMillis) return { kind: "busy" as const };
      }
      const leaseToken = randomUUID();
      const reserved: EnrollmentRecord = { ...record, registrationLeaseToken: leaseToken, registrationLeaseExpiresAtMillis: nowMillis + leaseMillis };
      if (existing === undefined) transaction.create(ref, reserved);
      else transaction.set(ref, reserved);
      return { kind: "acquired" as const, leaseToken };
    });
  }
  async completeRegistration(uid: string, deviceId: string, leaseToken: string, activationBlob: string): Promise<EnrollmentRecord> {
    return this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(documentId(uid, deviceId));
      const snapshot = await transaction.get(ref);
      const existing = snapshot.data() as EnrollmentRecord | undefined;
      if (existing === undefined || enrollmentRevoked(existing) || existing.active || existing.registrationLeaseToken !== leaseToken || existing.activationBlob !== undefined) throw new PublicError(409, "conflict", "Enrollment state changed");
      const completed: EnrollmentRecord = { ...existing, activationBlob };
      delete completed.registrationLeaseToken;
      delete completed.registrationLeaseExpiresAtMillis;
      transaction.set(ref, completed);
      return completed;
    });
  }
  async releaseRegistration(uid: string, deviceId: string, leaseToken: string): Promise<void> {
    await this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(documentId(uid, deviceId));
      const snapshot = await transaction.get(ref);
      const existing = snapshot.data() as EnrollmentRecord | undefined;
      if (existing !== undefined && !existing.active && existing.activationBlob === undefined && existing.registrationLeaseToken === leaseToken) transaction.delete(ref);
    });
  }
  async deletePending(uid: string, deviceId: string, agentId: string): Promise<void> {
    await this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(documentId(uid, deviceId));
      const snapshot = await transaction.get(ref);
      const existing = snapshot.data() as EnrollmentRecord | undefined;
      if (existing !== undefined && !existing.active && existing.agentId === agentId) transaction.delete(ref);
    });
  }
  async claimActivation(uid: string, deviceId: string, nowMillis: number, leaseMillis: number): Promise<
    | { kind: "acquired"; record: EnrollmentRecord; leaseToken: string }
    | { kind: "cached" }
    | { kind: "busy" }
  > {
    return this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(documentId(uid, deviceId));
      const snapshot = await transaction.get(ref);
      const existing = snapshot.data() as EnrollmentRecord | undefined;
      if (!snapshot.exists || existing?.uid !== uid || existing.deviceId !== deviceId) {
        throw new PublicError(409, "conflict", "Enrollment is not pending");
      }
      if (enrollmentRevoked(existing)) throw new PublicError(409, "conflict", "Enrollment state changed");
      if (existing.active) return { kind: "cached" as const };
      if (existing.activationBlob === undefined) throw new PublicError(409, "conflict", "Enrollment is not pending");
      if ((existing.activationLeaseExpiresAtMillis ?? 0) > nowMillis) return { kind: "busy" as const };
      const leaseToken = randomUUID();
      const claimed = {
        ...existing,
        activationLeaseToken: leaseToken,
        activationLeaseExpiresAtMillis: nowMillis + leaseMillis,
      };
      transaction.set(ref, claimed);
      return { kind: "acquired" as const, record: claimed, leaseToken };
    });
  }
  async activate(uid: string, deviceId: string, agentId: string, leaseToken: string): Promise<void> {
    await this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(documentId(uid, deviceId));
      const snapshot = await transaction.get(ref);
      const data = snapshot.data() as EnrollmentRecord | undefined;
      if (!snapshot.exists || data?.uid !== uid || data.deviceId !== deviceId || data.agentId !== agentId || enrollmentRevoked(data) || data.active || data.activationBlob === undefined || data.activationLeaseToken !== leaseToken) {
        throw new PublicError(409, "conflict", "Enrollment state changed");
      }
      transaction.update(ref, {
        active: true,
        activationBlob: FieldValue.delete(),
        activationLeaseToken: FieldValue.delete(),
        activationLeaseExpiresAtMillis: FieldValue.delete(),
      });
    });
  }
  async renewActivation(uid: string, deviceId: string, leaseToken: string, nowMillis: number, leaseMillis: number): Promise<void> {
    await this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(documentId(uid, deviceId));
      const snapshot = await transaction.get(ref);
      const data = snapshot.data() as EnrollmentRecord | undefined;
      if (!snapshot.exists
          || data?.uid !== uid
          || data.deviceId !== deviceId
          || enrollmentRevoked(data)
          || data.active
          || data.activationBlob === undefined
          || data.activationLeaseToken !== leaseToken) {
        throw new PublicError(409, "conflict", "Enrollment state changed");
      }
      transaction.update(ref, { activationLeaseExpiresAtMillis: nowMillis + leaseMillis });
    });
  }
  async releaseActivation(uid: string, deviceId: string, leaseToken: string): Promise<void> {
    await this.firestore.runTransaction(async transaction => {
      const ref = this.firestore.collection(this.collection).doc(documentId(uid, deviceId));
      const snapshot = await transaction.get(ref);
      const data = snapshot.data() as EnrollmentRecord | undefined;
      if (!snapshot.exists || data?.active || data?.activationLeaseToken !== leaseToken) return;
      transaction.update(ref, {
        activationLeaseToken: FieldValue.delete(),
        activationLeaseExpiresAtMillis: FieldValue.delete(),
      });
    });
  }
  async requireActive(uid: string, deviceId: string): Promise<EnrollmentRecord> {
    const snapshot = await this.firestore.collection(this.collection).doc(documentId(uid, deviceId)).get();
    const data = snapshot.data() as EnrollmentRecord | undefined;
    if (!snapshot.exists || !isActiveEnrollment(data, uid, deviceId)) {
      throw new PublicError(403, "verification_failed", "Device attestation was not accepted");
    }
    return data;
  }
}

export class FirestorePolicyStore implements PolicyStore {
  constructor(private readonly firestore: Firestore, private readonly collection = "linux_attestation_policies") {}
  async get(challenge: AttestationChallenge): Promise<AttestationPolicy> {
    const snapshot = await this.firestore.collection(this.collection).doc(documentId(challenge.policyId, challenge.releaseDigestSha256, challenge.architecture)).get();
    if (!snapshot.exists) throw new PublicError(403, "verification_failed", "Device attestation was not accepted");
    const source = object(snapshot.data(), "attestation policy");
    exactKeys(source, ["policyId", "releaseDigestSha256", "architecture", "version", "active", "tpmPolicy", "runtimePolicy", "measuredBootPolicy", "releaseManifestPublicKeyPem"], "attestation policy");
    if (source.active !== true) throw new PublicError(403, "verification_failed", "Device attestation was not accepted");
    const policy: AttestationPolicy = {
      policyId: string(source.policyId, "policyId", 128),
      releaseDigestSha256: sha256Hex(source.releaseDigestSha256, "releaseDigestSha256"),
      architecture: string(source.architecture, "architecture", 64),
      version: string(source.version, "version", 64),
      tpmPolicy: object(source.tpmPolicy, "tpmPolicy"),
      runtimePolicy: object(source.runtimePolicy, "runtimePolicy"),
      measuredBootPolicy: object(source.measuredBootPolicy, "measuredBootPolicy"),
      releaseManifestPublicKeyPem: string(source.releaseManifestPublicKeyPem, "releaseManifestPublicKeyPem", 8 * 1024),
    };
    if (policy.policyId !== challenge.policyId || policy.releaseDigestSha256 !== challenge.releaseDigestSha256 || policy.architecture !== challenge.architecture) {
      throw new PublicError(403, "verification_failed", "Device attestation was not accepted");
    }
    return policy;
  }
}

export async function readMtlsFiles(caPath: string, certificatePath: string, keyPath: string): Promise<{ ca: Buffer; cert: Buffer; key: Buffer }> {
  const [ca, cert, key] = await Promise.all([readFile(caPath), readFile(certificatePath), readFile(keyPath)]);
  return { ca, cert, key };
}
