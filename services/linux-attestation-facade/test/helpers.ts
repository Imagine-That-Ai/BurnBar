import { generateKeyPairSync, sign } from "node:crypto";
import { PublicError } from "../src/errors.js";
import type { AttestationChallenge, SignedVerdictEnvelope, VerifyRequest } from "../src/contracts.js";
import { quoteQualifyingDataSha256 } from "../src/contracts.js";
import type { AttestationPolicy, EnrollmentCandidate, EnrollmentRecord, EnrollmentStore, EvidenceObjectStore, IngressTicketStore, KeylimeResult, KeylimeVerifier, PolicyStore, UploadBinding, UploadRecord, UploadStateStore, VerdictSigner } from "../src/ports.js";
import { sha256 } from "../src/validation.js";
import { sameEnrollmentIdentity } from "../src/enrollment.js";
import type { IngressTicketCredential } from "../src/ingressTicket.js";

export class MemoryState implements UploadStateStore {
  readonly records = new Map<string, UploadRecord>();
  private leaseCounter = 0;
  async create(record: UploadRecord): Promise<void> {
    if (this.records.has(record.uploadId)) throw new PublicError(409, "conflict", "Upload exists");
    this.records.set(record.uploadId, structuredClone(record));
  }
  async get(uploadId: string): Promise<UploadRecord | undefined> {
    const result = this.records.get(uploadId);
    return result === undefined ? undefined : structuredClone(result);
  }
  async claimUploadAttempt(uploadId: string, uid: string, nowMillis: number, maxAttempts: number): Promise<UploadRecord> {
    const record = this.require(uploadId);
    if (record.uid !== uid) throw new PublicError(403, "forbidden", "Upload does not belong to this user");
    if (record.expiresAtMillis <= nowMillis) throw new PublicError(409, "conflict", "Upload has expired");
    if (record.status !== "pending" && !(record.status === "uploaded" && record.generation !== undefined)) {
      throw new PublicError(409, "conflict", "Upload has already been used");
    }
    const attemptCount = record.uploadAttemptCount ?? 0;
    if (attemptCount >= maxAttempts) throw new PublicError(429, "rate_limited", "Evidence upload retry limit was reached");
    record.uploadAttemptCount = attemptCount + 1;
    return structuredClone(record);
  }
  async completeUpload(uploadId: string, generation: string): Promise<UploadRecord> {
    const record = this.require(uploadId);
    if (record.status === "uploaded" && record.generation === generation) return structuredClone(record);
    if (record.status !== "pending") throw new PublicError(409, "conflict", "Upload used");
    record.status = "uploaded";
    record.generation = generation;
    return structuredClone(record);
  }
  async claimVerification(uploadId: string, fingerprint: string, nowMillis: number, leaseMillis: number): Promise<{ kind: "acquired"; record: UploadRecord; leaseToken: string } | { kind: "cached"; envelope: SignedVerdictEnvelope } | { kind: "busy" }> {
    const record = this.require(uploadId);
    if (record.expiresAtMillis <= nowMillis) throw new PublicError(409, "conflict", "Expired");
    if (record.verificationFingerprint !== undefined && record.verificationFingerprint !== fingerprint) throw new PublicError(409, "conflict", "Replay");
    if (record.status === "verified" && record.result !== undefined) {
      if (record.result.verdict.expiresAtMillis <= nowMillis) throw new PublicError(409, "conflict", "Expired verdict");
      return { kind: "cached", envelope: structuredClone(record.result) };
    }
    if (record.status === "rejected") throw new PublicError(409, "conflict", "Rejected");
    if (record.status === "verifying" && (record.leaseExpiresAtMillis ?? 0) > nowMillis) return { kind: "busy" };
    if (record.status !== "uploaded" && record.status !== "verifying") throw new PublicError(409, "conflict", "Not ready");
    record.status = "verifying";
    record.verificationFingerprint = fingerprint;
    const leaseToken = `lease-${String(++this.leaseCounter)}`;
    record.verificationLeaseToken = leaseToken;
    record.leaseExpiresAtMillis = nowMillis + leaseMillis;
    return { kind: "acquired", record: structuredClone(record), leaseToken };
  }
  async completeVerification(uploadId: string, fingerprint: string, leaseToken: string, envelope: SignedVerdictEnvelope): Promise<void> {
    const record = this.assertLease(uploadId, fingerprint, leaseToken);
    record.status = "verified";
    record.result = structuredClone(envelope);
    delete record.leaseExpiresAtMillis;
    delete record.verificationLeaseToken;
  }
  async rejectVerification(uploadId: string, fingerprint: string, leaseToken: string): Promise<void> {
    const record = this.assertLease(uploadId, fingerprint, leaseToken);
    record.status = "rejected";
    delete record.leaseExpiresAtMillis;
    delete record.verificationLeaseToken;
  }
  async releaseVerification(uploadId: string, fingerprint: string, leaseToken: string): Promise<void> {
    const record = this.assertLease(uploadId, fingerprint, leaseToken);
    record.status = "uploaded";
    delete record.leaseExpiresAtMillis;
    delete record.verificationLeaseToken;
  }
  private require(uploadId: string): UploadRecord {
    const record = this.records.get(uploadId);
    if (record === undefined) throw new PublicError(404, "not_found", "Not found");
    return record;
  }
  private assertLease(uploadId: string, fingerprint: string, leaseToken: string): UploadRecord {
    const record = this.require(uploadId);
    if (record.status !== "verifying" || record.verificationFingerprint !== fingerprint || record.verificationLeaseToken !== leaseToken) throw new PublicError(409, "conflict", "lease mismatch");
    return record;
  }
}

export class MemoryObjects implements EvidenceObjectStore {
  readonly objects = new Map<string, { bytes: Buffer; generation: string }>();
  async create(objectName: string, bytes: Buffer): Promise<string> {
    const existing = this.objects.get(objectName);
    if (existing !== undefined) {
      if (!existing.bytes.equals(bytes)) throw new Error("object exists with different content");
      return existing.generation;
    }
    const generation = "1";
    this.objects.set(objectName, { bytes: Buffer.from(bytes), generation });
    return generation;
  }
  async read(objectName: string, generation: string, maxBytes: number): Promise<Buffer> {
    const value = this.objects.get(objectName);
    if (value === undefined || value.generation !== generation) throw new PublicError(400, "bad_request", "Evidence missing");
    if (value.bytes.byteLength > maxBytes) throw new PublicError(413, "payload_too_large", "Too large");
    return Buffer.from(value.bytes);
  }
}

export class MemoryEnrollments implements EnrollmentStore {
  records: EnrollmentRecord[] = [];
  private leaseCounter = 0;
  async get(uid: string, deviceId: string): Promise<EnrollmentRecord | undefined> {
    const record = this.records.find(value => value.uid === uid && value.deviceId === deviceId);
    return record === undefined ? undefined : structuredClone(record);
  }
  async claimActivation(uid: string, deviceId: string, nowMillis: number, leaseMillis: number): Promise<
    | { kind: "acquired"; record: EnrollmentRecord; leaseToken: string }
    | { kind: "cached" }
    | { kind: "busy" }
  > {
    const record = this.records.find(value => value.uid === uid && value.deviceId === deviceId);
    if (record === undefined) throw new PublicError(409, "conflict", "Enrollment is not pending");
    if (record.active) return { kind: "cached" };
    if (record.activationBlob === undefined) throw new PublicError(409, "conflict", "Enrollment is not pending");
    if ((record.activationLeaseExpiresAtMillis ?? 0) > nowMillis) return { kind: "busy" };
    const leaseToken = `activation-${String(++this.leaseCounter)}`;
    record.activationLeaseToken = leaseToken;
    record.activationLeaseExpiresAtMillis = nowMillis + leaseMillis;
    return { kind: "acquired", record: structuredClone(record), leaseToken };
  }
  async claimRegistration(record: EnrollmentRecord, nowMillis: number, leaseMillis: number): Promise<{ kind: "acquired"; leaseToken: string } | { kind: "cached"; record: EnrollmentRecord } | { kind: "busy" }> {
    const existing = this.records.find(value => value.uid === record.uid && value.deviceId === record.deviceId);
    if (existing !== undefined) {
      if (existing.active || !sameEnrollmentIdentity(existing, record)) throw new PublicError(409, "conflict", "Enrollment state changed");
      if (existing.activationBlob !== undefined) return { kind: "cached", record: structuredClone(existing) };
      if ((existing.registrationLeaseExpiresAtMillis ?? 0) > nowMillis) return { kind: "busy" };
    }
    const leaseToken = `registration-${String(++this.leaseCounter)}`;
    const reserved = { ...record, registrationLeaseToken: leaseToken, registrationLeaseExpiresAtMillis: nowMillis + leaseMillis };
    this.records = this.records.filter(value => value.uid !== record.uid || value.deviceId !== record.deviceId).concat(reserved);
    return { kind: "acquired", leaseToken };
  }
  async completeRegistration(uid: string, deviceId: string, leaseToken: string, activationBlob: string): Promise<EnrollmentRecord> {
    const record = this.records.find(value => value.uid === uid && value.deviceId === deviceId && value.registrationLeaseToken === leaseToken && !value.active);
    if (record === undefined) throw new PublicError(409, "conflict", "Enrollment state changed");
    record.activationBlob = activationBlob;
    delete record.registrationLeaseToken;
    delete record.registrationLeaseExpiresAtMillis;
    return structuredClone(record);
  }
  async releaseRegistration(uid: string, deviceId: string, leaseToken: string): Promise<void> {
    this.records = this.records.filter(value => value.uid !== uid || value.deviceId !== deviceId || value.registrationLeaseToken !== leaseToken);
  }
  async deletePending(uid: string, deviceId: string, agentId: string, activationLeaseToken?: string): Promise<void> {
    this.records = this.records.filter(value => value.uid !== uid
      || value.deviceId !== deviceId
      || value.agentId !== agentId
      || value.active
      || (activationLeaseToken !== undefined && value.activationLeaseToken !== activationLeaseToken));
  }
  async activate(uid: string, deviceId: string, agentId: string, leaseToken: string): Promise<void> {
    const record = this.records.find(value => value.uid === uid
      && value.deviceId === deviceId
      && value.agentId === agentId
      && !value.active
      && value.activationLeaseToken === leaseToken);
    if (record === undefined) throw new PublicError(409, "conflict", "Enrollment state changed");
    record.active = true;
    delete record.activationBlob;
    delete record.activationLeaseToken;
    delete record.activationLeaseExpiresAtMillis;
  }
  async renewActivation(uid: string, deviceId: string, leaseToken: string, nowMillis: number, leaseMillis: number): Promise<void> {
    const record = this.records.find(value => value.uid === uid
      && value.deviceId === deviceId
      && !value.active
      && value.activationBlob !== undefined
      && value.activationLeaseToken === leaseToken);
    if (record === undefined) throw new PublicError(409, "conflict", "Enrollment state changed");
    record.activationLeaseExpiresAtMillis = nowMillis + leaseMillis;
  }
  async releaseActivation(uid: string, deviceId: string, leaseToken: string): Promise<void> {
    const record = this.records.find(value => value.uid === uid && value.deviceId === deviceId && !value.active && value.activationLeaseToken === leaseToken);
    if (record === undefined) return;
    delete record.activationLeaseToken;
    delete record.activationLeaseExpiresAtMillis;
  }
  async requireActive(uid: string, deviceId: string): Promise<EnrollmentRecord> {
    const record = this.records.find(value => value.uid === uid && value.deviceId === deviceId && value.active);
    if (record === undefined) throw new PublicError(403, "verification_failed", "Device attestation was not accepted");
    return structuredClone(record);
  }
}

export class MemoryTickets implements IngressTicketStore {
  uploadClaims = 0;
  enrollmentClaims = 0;

  constructor(
    private readonly state: MemoryState,
    private readonly enrollments: MemoryEnrollments,
    private readonly expiresAtMillis = 301_000,
  ) {}

  async claimUpload(_credential: IngressTicketCredential, binding: UploadBinding): Promise<UploadRecord> {
    this.uploadClaims += 1;
    const existing = await this.state.get("upload-1");
    if (existing !== undefined) return existing;
    const record: UploadRecord = {
      ...binding,
      uploadId: "upload-1",
      objectName: "linux-attestation/evidence/upload-1",
      expiresAtMillis: this.expiresAtMillis,
      status: "pending",
    };
    await this.state.create(record);
    return record;
  }

  async claimEnrollmentBegin(
    _credential: IngressTicketCredential,
    candidate: EnrollmentCandidate,
    nowMillis: number,
    leaseMillis: number,
  ) {
    this.enrollmentClaims += 1;
    return this.enrollments.claimRegistration(candidate, nowMillis, leaseMillis);
  }

  async completeEnrollmentBegin(uid: string, deviceId: string, _ticketId: string, leaseToken: string, activationBlob: string) {
    return this.enrollments.completeRegistration(uid, deviceId, leaseToken, activationBlob);
  }

  async releaseEnrollmentBegin(uid: string, deviceId: string, _ticketId: string, leaseToken: string): Promise<void> {
    await this.enrollments.releaseRegistration(uid, deviceId, leaseToken);
  }

  async terminalizeEnrollmentBegin(uid: string, deviceId: string, _ticketId: string, leaseToken: string): Promise<void> {
    await this.enrollments.releaseRegistration(uid, deviceId, leaseToken);
  }

  async terminalizePendingEnrollment(uid: string, deviceId: string, agentId: string, activationLeaseToken: string): Promise<void> {
    await this.enrollments.deletePending(uid, deviceId, agentId, activationLeaseToken);
  }
}

export const ingressTicketCredential: IngressTicketCredential = {
  ticketId: Buffer.alloc(16, 7).toString("base64url"),
  secret: Buffer.alloc(32, 9),
};

export class FakeKeylime implements KeylimeVerifier {
  calls = 0;
  result: KeylimeResult = { valid: true, receipt: { evaluation: "accepted" } };
  error: Error | undefined = undefined;
  onVerify: (() => void) | undefined = undefined;
  async verify(): Promise<KeylimeResult> {
    this.calls += 1;
    this.onVerify?.();
    if (this.error !== undefined) throw this.error;
    return this.result;
  }
}

export class CryptoSigner implements VerdictSigner {
  readonly keyId = "projects/test/locations/global/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1";
  readonly publicKey;
  calls = 0;
  error: Error | undefined = undefined;
  private readonly privateKey;
  constructor() {
    const keys = generateKeyPairSync("ed25519");
    this.privateKey = keys.privateKey;
    this.publicKey = keys.publicKey;
  }
  async sign(data: Buffer): Promise<Buffer> {
    this.calls += 1;
    if (this.error !== undefined) throw this.error;
    return sign(null, data, this.privateKey);
  }
}

export const releaseKeys = generateKeyPairSync("ed25519");

export const policy: AttestationPolicy = {
  policyId: "openburnbar-linux-tpm2-ima-v1",
  releaseDigestSha256: "a".repeat(64),
  architecture: "x86_64",
  version: "policy-1",
  tpmPolicy: { "0": "0x0" },
  runtimePolicy: { type: "runtime" },
  measuredBootPolicy: { type: "measured-boot" },
  releaseManifestPublicKeyPem: releaseKeys.publicKey.export({ format: "pem", type: "spki" }).toString(),
};

export const policyStore: PolicyStore = { async get() { return policy; } };

function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value) as string;
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const source = value as Record<string, unknown>;
  return `{${Object.keys(source).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(source[key])}`).join(",")}}`;
}

export function evidenceBundle(records: readonly { kind: string; bytes: Buffer }[]): Buffer {
  let headerLength = 0;
  for (let attempt = 0; attempt < 16; attempt += 1) {
    let offset = 12 + headerLength;
    const headerRecords = records.map(record => {
      const result = { kind: record.kind, offset, byteLength: record.bytes.byteLength, sha256: sha256(record.bytes) };
      offset += record.bytes.byteLength;
      return result;
    });
    const header = Buffer.from(canonicalJson({ schemaVersion: 1, records: headerRecords }));
    if (header.byteLength === headerLength) {
      const prefix = Buffer.alloc(12);
      prefix.write("OBBATST1", 0, "ascii");
      prefix.writeUInt32BE(header.byteLength, 8);
      return Buffer.concat([prefix, header, ...records.map(record => record.bytes)]);
    }
    headerLength = header.byteLength;
  }
  throw new Error("header did not stabilize");
}

export function fixture(now = 1_700_000_000_000): { challenge: AttestationChallenge; bytes: Buffer; request: VerifyRequest; record: UploadRecord } {
  const challenge: AttestationChallenge = {
    uid: "user-1", appId: "1:246956661961:web:2e267f5d3a84a525480118", deviceId: "device-1", appVersion: "1.0.0", architecture: "x86_64",
    releaseDigestSha256: "a".repeat(64), policyId: policy.policyId, attestationKind: "tpm2_ima_signed_verdict_v1",
    challengeId: "challenge-1", challenge: Buffer.alloc(32, 255).toString("base64url"), expiresAtMillis: now + 120_000, protocolVersion: 1,
  };
  const daemonDigest = "e".repeat(64);
  const daemonFile = { path: "/usr/bin/openburnbar-daemon", type: "file", sha256: daemonDigest, size: 123, mode: "0755", uid: 0, gid: 0 };
  const filesRoot = sha256(`${daemonFile.path}\0file\0${daemonDigest}\0${daemonFile.size}\0${daemonFile.mode}\0${daemonFile.uid}\0${daemonFile.gid}`);
  const manifest = Buffer.from(`${canonicalJson({
    schemaVersion: 1, product: "OpenBurnBar", appId: "dev.openburnbar.OpenBurnBar", firebaseAppId: challenge.appId,
    packageVersion: challenge.appVersion, gitCommit: "c".repeat(40), packageArchitecture: challenge.architecture, packageFormat: "deb",
    packageName: "open-burn-bar", policyId: challenge.policyId, brokerProtocolVersion: 2, installedFilesRootSha256: filesRoot,
    authorizedClients: [{ role: "daemon", path: daemonFile.path, sha256: daemonDigest, ownerUid: 0, ownerGid: 0, mode: 0o755 }], files: [daemonFile],
  })}\n`);
  challenge.releaseDigestSha256 = sha256(manifest);
  policy.releaseDigestSha256 = challenge.releaseDigestSha256;
  const manifestSignature = sign(null, manifest, releaseKeys.privateKey);
  const bytes = evidenceBundle([
    { kind: "ima_ascii_runtime_measurements", bytes: Buffer.from("ima") },
    { kind: "uefi_binary_bios_measurements", bytes: Buffer.from("uefi") },
    { kind: "installed_manifest", bytes: manifest },
    { kind: "installed_manifest_signature", bytes: manifestSignature },
  ]);
  const digest = sha256(bytes);
  const request: VerifyRequest = {
    challenge,
    evidence: {
      schemaVersion: 1,
      quote: {
        schemaVersion: 1, deviceId: challenge.deviceId, quoteAttestationBase64: Buffer.from("quote").toString("base64"),
        quoteSignatureBase64: Buffer.from("quote-signature").toString("base64"), quotePcrValuesBase64: Buffer.from("pcr-values").toString("base64"), pcrBank: "sha256", pcrSelection: [0, 2, 4, 7, 10],
        qualifyingDataSha256: quoteQualifyingDataSha256(challenge),
      },
      evidenceBundle: { descriptorIndex: 0, format: "openburnbar_tpm_evidence_bundle_v1", byteLength: bytes.byteLength, sha256: digest },
      upload: { uploadId: "upload-1", generation: "1", sha256: digest, size: bytes.byteLength },
    },
  };
  const record: UploadRecord = {
    uploadId: "upload-1", objectName: "linux-attestation/evidence/upload-1", uid: challenge.uid, appId: challenge.appId,
    deviceId: challenge.deviceId, challengeId: challenge.challengeId, releaseDigestSha256: challenge.releaseDigestSha256,
    expectedSha256: request.evidence.upload.sha256, expectedSize: request.evidence.upload.size, expiresAtMillis: now + 120_000, status: "uploaded", generation: "1",
  };
  return { challenge, bytes, request, record };
}
