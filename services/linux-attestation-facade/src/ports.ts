import type { AttestationChallenge, EvidenceReceipt, SignedVerdictEnvelope } from "./contracts.js";
import type { IngressTicketCredential } from "./ingressTicket.js";

export interface UserIdentity {
  uid: string;
}

export interface UserAuthenticator {
  authenticate(token: string): Promise<UserIdentity>;
}

export interface ServiceAuthenticator {
  authenticate(token: string): Promise<void>;
}

export interface UploadBinding {
  uid: string;
  appId: string;
  deviceId: string;
  challengeId: string;
  releaseDigestSha256: string;
  expectedSha256: string;
  expectedSize: number;
}

export interface UploadRecord extends UploadBinding {
  uploadId: string;
  objectName: string;
  expiresAtMillis: number;
  status: "pending" | "uploaded" | "verifying" | "verified" | "rejected";
  uploadAttemptCount?: number;
  generation?: string;
  result?: SignedVerdictEnvelope;
  verificationFingerprint?: string;
  leaseExpiresAtMillis?: number;
  verificationLeaseToken?: string;
}

export interface UploadStateStore {
  get(uploadId: string): Promise<UploadRecord | undefined>;
  claimUploadAttempt(uploadId: string, uid: string, nowMillis: number, maxAttempts: number): Promise<UploadRecord>;
  completeUpload(uploadId: string, generation: string): Promise<UploadRecord>;
  claimVerification(uploadId: string, fingerprint: string, nowMillis: number, leaseMillis: number): Promise<
    | { kind: "acquired"; record: UploadRecord; leaseToken: string }
    | { kind: "cached"; envelope: SignedVerdictEnvelope }
    | { kind: "busy" }
  >;
  completeVerification(uploadId: string, fingerprint: string, leaseToken: string, envelope: SignedVerdictEnvelope): Promise<void>;
  rejectVerification(uploadId: string, fingerprint: string, leaseToken: string): Promise<void>;
  releaseVerification(uploadId: string, fingerprint: string, leaseToken: string): Promise<void>;
}

export interface EvidenceObjectStore {
  create(objectName: string, bytes: Buffer, expiresAtMillis: number): Promise<string>;
  read(objectName: string, generation: string, maxBytes: number): Promise<Buffer>;
}

export interface EnrollmentRecord {
  uid: string;
  deviceId: string;
  agentId: string;
  akTpmBase64: string;
  tpmEkPem: string;
  ekTpmBase64: string;
  ekCertificateBase64: string;
  activationBlob?: string;
  registrationLeaseToken?: string;
  registrationLeaseExpiresAtMillis?: number;
  beginTicketId?: string;
  activationLeaseToken?: string;
  activationLeaseExpiresAtMillis?: number;
  revokedAtMillis?: number;
  revokedAt?: unknown;
  revokedReason?: string;
  revocationReason?: string;
  active: boolean;
}

export interface EnrollmentCandidate extends EnrollmentRecord {
  activationBlob?: never;
  registrationLeaseToken?: never;
  registrationLeaseExpiresAtMillis?: never;
  beginTicketId?: never;
  activationLeaseToken?: never;
  activationLeaseExpiresAtMillis?: never;
  revokedAtMillis?: never;
  revokedAt?: never;
  revokedReason?: never;
  revocationReason?: never;
  active: false;
}

export interface IngressTicketStore {
  claimUpload(
    credential: IngressTicketCredential,
    binding: UploadBinding,
    nowMillis: number,
  ): Promise<UploadRecord>;
  claimEnrollmentBegin(
    credential: IngressTicketCredential,
    candidate: EnrollmentCandidate,
    nowMillis: number,
    leaseMillis: number,
    maxAttempts: number,
  ): Promise<
    | { kind: "acquired"; leaseToken: string }
    | { kind: "cached"; record: EnrollmentRecord }
    | { kind: "busy" }
  >;
  completeEnrollmentBegin(
    uid: string,
    deviceId: string,
    ticketId: string,
    leaseToken: string,
    activationBlob: string,
  ): Promise<EnrollmentRecord>;
  releaseEnrollmentBegin(uid: string, deviceId: string, ticketId: string, leaseToken: string): Promise<void>;
  terminalizeEnrollmentBegin(uid: string, deviceId: string, ticketId: string, leaseToken: string): Promise<void>;
  terminalizePendingEnrollment(uid: string, deviceId: string, agentId: string, activationLeaseToken: string): Promise<void>;
}

export interface EnrollmentStore {
  get(uid: string, deviceId: string): Promise<EnrollmentRecord | undefined>;
  claimActivation(uid: string, deviceId: string, nowMillis: number, leaseMillis: number): Promise<
    | { kind: "acquired"; record: EnrollmentRecord; leaseToken: string }
    | { kind: "cached" }
    | { kind: "busy" }
  >;
  renewActivation(uid: string, deviceId: string, leaseToken: string, nowMillis: number, leaseMillis: number): Promise<void>;
  activate(uid: string, deviceId: string, agentId: string, leaseToken: string): Promise<void>;
  releaseActivation(uid: string, deviceId: string, leaseToken: string): Promise<void>;
  requireActive(uid: string, deviceId: string): Promise<EnrollmentRecord>;
}

export interface RegistrarClient {
  begin(agentId: string, ekCertificateBase64: string, ekTpmBase64: string, akTpmBase64: string): Promise<{ activationBlob: string }>;
  activate(agentId: string, activationProof: string): Promise<void>;
  getActiveIdentity(agentId: string): Promise<RegistrarIdentity | undefined>;
}

export interface RegistrarIdentity {
  agentId: string;
  akTpmBase64: string;
  ekTpmBase64: string;
  ekCertificateBase64: string;
}

export interface AttestationPolicy {
  policyId: string;
  releaseDigestSha256: string;
  architecture: string;
  version: string;
  tpmPolicy: Readonly<Record<string, unknown>>;
  runtimePolicy: Readonly<Record<string, unknown>>;
  measuredBootPolicy: Readonly<Record<string, unknown>>;
  releaseManifestPublicKeyPem: string;
}

export interface PolicyStore {
  get(challenge: AttestationChallenge): Promise<AttestationPolicy>;
}

export interface KeylimeEvidenceInput {
  agentId: string;
  akTpmBase64: string;
  tpmEkPem: string;
  quoteAttestationBase64: string;
  quoteSignatureBase64: string;
  quotePcrValuesBase64: string;
  pcrBank: "sha256";
  pcrSelection: readonly [0, 2, 4, 7, 10];
  qualifyingDataSha256: string;
  imaMeasurementList: Buffer;
  measuredBootLog: Buffer;
}

export interface KeylimeResult {
  valid: boolean;
  receipt: Readonly<Record<string, unknown>>;
}

export interface KeylimeVerifier {
  verify(evidence: KeylimeEvidenceInput, policy: AttestationPolicy): Promise<KeylimeResult>;
}

export interface VerdictSigner {
  keyId: string;
  sign(data: Buffer): Promise<Buffer>;
}

export interface Clock {
  nowMillis(): number;
}

export interface UploadReceiptRequest extends UploadBinding {
  expiresAtMillis: number;
}

export interface CompleteUploadResult {
  receipt: EvidenceReceipt;
}
