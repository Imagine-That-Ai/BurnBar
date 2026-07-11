import { createHash, randomBytes } from "node:crypto";

import { Timestamp, type DocumentReference, type Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { LINUX_ATTESTATION_KIND, LINUX_ATTESTATION_PROTOCOL_VERSION, sha256Hex } from "./linuxAttestation.js";
import {
  DAY_MS,
  ENROLLMENTS_PER_DEVICE_DAY,
  ENROLLMENTS_PER_UID_DAY,
  ENROLLMENTS_PER_UID_HOUR,
  HOUR_MS,
  TEN_MINUTES_MS,
  UPLOAD_BYTES_PER_UID_DAY,
  UPLOADS_PER_DEVICE_DAY,
  UPLOADS_PER_DEVICE_TEN_MINUTES,
  UPLOADS_PER_UID_DAY,
  linuxAttestationQuotaDocId,
  linuxEnrollmentQuotaReservations,
  linuxUploadQuotaReservations,
  reserveLinuxAttestationQuotas,
} from "./linuxAttestationIngressQuota.js";

export const LINUX_ATTESTATION_TICKET_SCHEMA_VERSION = 1 as const;
export const LINUX_ATTESTATION_TICKET_ID_BYTES = 16;
export const LINUX_ATTESTATION_TICKET_ID_LENGTH = 22;
export const LINUX_ATTESTATION_TICKET_SECRET_BYTES = 32;
export const LINUX_ATTESTATION_TICKET_SECRET_LENGTH = 43;
export const LINUX_ATTESTATION_TICKET_WIRE_PREFIX = "obbat1_" as const;
export const LINUX_ATTESTATION_TICKET_SECRET_DOMAIN = "openburnbar.linux.attestation-ticket-secret.v1\0" as const;
export const LINUX_ATTESTATION_TICKET_CLAIM_DOMAIN = "openburnbar.linux.attestation-ticket-claim.v1" as const;
export const LINUX_ATTESTATION_ENROLLMENT_TICKET_TTL_MS = 5 * 60 * 1000;
export const LINUX_ATTESTATION_MAX_EVIDENCE_BYTES = 16 * 1024 * 1024;

export type LinuxAttestationTicketPurpose = "evidence_upload" | "enrollment_begin";

export interface LinuxUploadTicketRequest {
  uid: string;
  challengeId: string;
  challenge: string;
  ticketSecretHashSha256: string;
  expectedSha256: string;
  expectedSize: number;
}

export interface LinuxEnrollmentTicketRequest {
  uid: string;
  deviceId: string;
  ticketSecretHashSha256: string;
  akTpmSha256: string;
  ekTpmSha256: string;
  ekCertificateSha256: string;
}

export interface LinuxAttestationTicketIssueResult {
  ticketId: string;
  expiresAtMillis: number;
}

interface StoredChallenge {
  protocolVersion: typeof LINUX_ATTESTATION_PROTOCOL_VERSION;
  uid: string;
  appId: string;
  deviceId: string;
  releaseDigestSha256: string;
  attestationKind: typeof LINUX_ATTESTATION_KIND;
  challengeHashSha256: string;
  expiresAtMillis: number;
  consumedAtMillis?: number;
  uploadTicketId?: string;
}

interface TicketBase {
  schemaVersion: typeof LINUX_ATTESTATION_TICKET_SCHEMA_VERSION;
  protocolVersion: typeof LINUX_ATTESTATION_PROTOCOL_VERSION;
  attestationKind: typeof LINUX_ATTESTATION_KIND;
  ticketId: string;
  purpose: LinuxAttestationTicketPurpose;
  ticketSecretHashSha256: string;
  claimFingerprintSha256: string;
  uid: string;
  deviceId: string;
  issuedAtMillis: number;
  expiresAtMillis: number;
  status: "issued" | "claimed" | "executing" | "succeeded" | "terminal";
}

export interface StoredLinuxUploadTicket extends TicketBase {
  purpose: "evidence_upload";
  uploadId: string;
  appId: string;
  challengeId: string;
  challengeHashSha256: string;
  releaseDigestSha256: string;
  expectedSha256: string;
  expectedSize: number;
}

export interface StoredLinuxEnrollmentTicket extends TicketBase {
  purpose: "enrollment_begin";
  akTpmSha256: string;
  ekTpmSha256: string;
  ekCertificateSha256: string;
}

export type StoredLinuxAttestationTicket = StoredLinuxUploadTicket | StoredLinuxEnrollmentTicket;

export interface StoredLinuxAttestationEnrollmentTicketSlot {
  schemaVersion: 1; purpose: "enrollment_begin"; deviceId: string;
  ticketId?: string; claimFingerprintSha256?: string; expiresAtMillis?: number;
  revokedAtMillis?: number; revokedReason?: string;
}

const SHA256_HEX = /^[a-f0-9]{64}$/u;
const CANONICAL_CHALLENGE = /^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/u;
const SAFE_DEVICE_ID = /^[A-Za-z0-9._:+/-]+$/u;

function invalid(message: string): HttpsError {
  return new HttpsError("invalid-argument", message);
}

function boundedDeviceId(raw: unknown): string {
  const value = typeof raw === "string" ? raw : "";
  if (!value || value.length > 160 || !SAFE_DEVICE_ID.test(value)) {
    throw invalid("deviceId is malformed.");
  }
  return value;
}

function exactSha256(raw: unknown, field: string): string {
  const value = typeof raw === "string" ? raw : "";
  if (!SHA256_HEX.test(value)) throw invalid(`${field} must be lowercase SHA-256 hex.`);
  return value;
}

function exactChallenge(raw: unknown): string {
  const value = typeof raw === "string" ? raw : "";
  if (!CANONICAL_CHALLENGE.test(value) || Buffer.from(value, "base64url").byteLength !== 32) {
    throw invalid("challenge must be canonical unpadded base64url for exactly 32 bytes.");
  }
  return value;
}

function exactChallengeId(raw: unknown): string {
  const value = typeof raw === "string" ? raw : "";
  if (!value || value.length > 80 || !/^[A-Za-z0-9._:+/-]+$/u.test(value)) {
    throw invalid("challengeId is malformed.");
  }
  return value;
}

function exactEvidenceSize(raw: unknown, maximumBytes = LINUX_ATTESTATION_MAX_EVIDENCE_BYTES): number {
  if (!Number.isSafeInteger(raw) || (raw as number) < 1 || (raw as number) > maximumBytes) {
    throw invalid(`expectedSize must be an integer from 1 through ${maximumBytes}.`);
  }
  return raw as number;
}

export function parseLinuxUploadTicketRequest(
  raw: unknown,
  uid: string,
  maximumBytes = LINUX_ATTESTATION_MAX_EVIDENCE_BYTES,
): LinuxUploadTicketRequest {
  if (raw == null || typeof raw !== "object" || Array.isArray(raw)) throw invalid("Upload ticket request is required.");
  const value = raw as Record<string, unknown>;
  const expectedKeys = new Set([
    "challengeId",
    "challenge",
    "ticketSecretHashSha256",
    "expectedSha256",
    "expectedSize",
  ]);
  if (Object.keys(value).some((key) => !expectedKeys.has(key)))
    throw invalid("Upload ticket request has unknown fields.");
  return {
    uid,
    challengeId: exactChallengeId(value.challengeId),
    challenge: exactChallenge(value.challenge),
    ticketSecretHashSha256: exactSha256(value.ticketSecretHashSha256, "ticketSecretHashSha256"),
    expectedSha256: exactSha256(value.expectedSha256, "expectedSha256"),
    expectedSize: exactEvidenceSize(value.expectedSize, maximumBytes),
  };
}

export function parseLinuxEnrollmentTicketRequest(raw: unknown, uid: string): LinuxEnrollmentTicketRequest {
  if (raw == null || typeof raw !== "object" || Array.isArray(raw)) {
    throw invalid("Enrollment ticket request is required.");
  }
  const value = raw as Record<string, unknown>;
  const expectedKeys = new Set([
    "deviceId",
    "ticketSecretHashSha256",
    "akTpmSha256",
    "ekTpmSha256",
    "ekCertificateSha256",
  ]);
  if (Object.keys(value).some((key) => !expectedKeys.has(key))) {
    throw invalid("Enrollment ticket request has unknown fields.");
  }
  const akTpmSha256 = exactSha256(value.akTpmSha256, "akTpmSha256");
  const deviceId = boundedDeviceId(value.deviceId);
  if (deviceId !== `ak-sha256:${akTpmSha256}`) {
    throw invalid("deviceId must be derived from akTpmSha256.");
  }
  return {
    uid,
    deviceId,
    ticketSecretHashSha256: exactSha256(value.ticketSecretHashSha256, "ticketSecretHashSha256"),
    akTpmSha256,
    ekTpmSha256: exactSha256(value.ekTpmSha256, "ekTpmSha256"),
    ekCertificateSha256: exactSha256(value.ekCertificateSha256, "ekCertificateSha256"),
  };
}

function fingerprint(fields: readonly (string | number)[]): string {
  return sha256Hex(fields.map(String).join("\0"));
}

export const linuxAttestationEnrollmentTicketSlotId = (deviceId: string): string =>
  fingerprint(["openburnbar.linux.attestation-enrollment-ticket-slot.v1", deviceId]);

export function parseStoredLinuxAttestationEnrollmentTicketSlot(
  raw: FirebaseFirestore.DocumentData | undefined,
): StoredLinuxAttestationEnrollmentTicketSlot | undefined {
  if (
    !raw
    || raw.schemaVersion !== 1
    || raw.purpose !== "enrollment_begin"
    || typeof raw.deviceId !== "string"
  ) {
    return undefined;
  }
  if (typeof raw.revokedAtMillis === "number" && Number.isFinite(raw.revokedAtMillis)) {
    if (raw.ticketId !== undefined && !isCanonicalTicketId(raw.ticketId)) return undefined;
    return raw as StoredLinuxAttestationEnrollmentTicketSlot;
  }
  if (
    !isCanonicalTicketId(raw.ticketId)
    || typeof raw.claimFingerprintSha256 !== "string"
    || !SHA256_HEX.test(raw.claimFingerprintSha256)
    || typeof raw.expiresAtMillis !== "number"
    || !Number.isFinite(raw.expiresAtMillis)
  ) {
    return undefined;
  }
  return raw as StoredLinuxAttestationEnrollmentTicketSlot;
}

export function linuxUploadTicketClaimFingerprint(input: {
  uid: string;
  appId: string;
  deviceId: string;
  challengeId: string;
  challengeHashSha256: string;
  releaseDigestSha256: string;
  expectedSha256: string;
  expectedSize: number;
}): string {
  return fingerprint([
    LINUX_ATTESTATION_TICKET_CLAIM_DOMAIN,
    "evidence_upload",
    LINUX_ATTESTATION_PROTOCOL_VERSION,
    LINUX_ATTESTATION_KIND,
    input.uid,
    input.appId,
    input.deviceId,
    input.challengeId,
    input.challengeHashSha256,
    input.releaseDigestSha256,
    input.expectedSha256,
    input.expectedSize,
  ]);
}

export function linuxEnrollmentTicketClaimFingerprint(input: LinuxEnrollmentTicketRequest): string {
  return fingerprint([
    LINUX_ATTESTATION_TICKET_CLAIM_DOMAIN,
    "enrollment_begin",
    LINUX_ATTESTATION_PROTOCOL_VERSION,
    LINUX_ATTESTATION_KIND,
    input.uid,
    input.deviceId,
    input.akTpmSha256,
    input.ekTpmSha256,
    input.ekCertificateSha256,
  ]);
}

export function linuxAttestationTicketSecretHash(secret: Buffer): string {
  if (secret.byteLength !== LINUX_ATTESTATION_TICKET_SECRET_BYTES) {
    throw invalid(`Ticket secret must contain exactly ${LINUX_ATTESTATION_TICKET_SECRET_BYTES} bytes.`);
  }
  return createHash("sha256").update(LINUX_ATTESTATION_TICKET_SECRET_DOMAIN, "utf8").update(secret).digest("hex");
}

function parseStoredChallenge(raw: FirebaseFirestore.DocumentData | undefined): StoredChallenge | undefined {
  if (
    !raw ||
    raw.protocolVersion !== LINUX_ATTESTATION_PROTOCOL_VERSION ||
    raw.attestationKind !== LINUX_ATTESTATION_KIND ||
    typeof raw.uid !== "string" ||
    typeof raw.appId !== "string" ||
    typeof raw.deviceId !== "string" ||
    typeof raw.releaseDigestSha256 !== "string" ||
    typeof raw.challengeHashSha256 !== "string" ||
    typeof raw.expiresAtMillis !== "number"
  ) {
    return undefined;
  }
  return {
    protocolVersion: LINUX_ATTESTATION_PROTOCOL_VERSION,
    uid: raw.uid,
    appId: raw.appId,
    deviceId: raw.deviceId,
    releaseDigestSha256: raw.releaseDigestSha256,
    attestationKind: LINUX_ATTESTATION_KIND,
    challengeHashSha256: raw.challengeHashSha256,
    expiresAtMillis: raw.expiresAtMillis,
    consumedAtMillis: typeof raw.consumedAtMillis === "number" ? raw.consumedAtMillis : undefined,
    uploadTicketId: typeof raw.uploadTicketId === "string" ? raw.uploadTicketId : undefined,
  };
}

export function parseStoredTicket(
  raw: FirebaseFirestore.DocumentData | undefined,
): StoredLinuxAttestationTicket | undefined {
  if (
    !raw ||
    raw.schemaVersion !== LINUX_ATTESTATION_TICKET_SCHEMA_VERSION ||
    raw.protocolVersion !== LINUX_ATTESTATION_PROTOCOL_VERSION ||
    raw.attestationKind !== LINUX_ATTESTATION_KIND ||
    !["issued", "claimed", "executing", "succeeded", "terminal"].includes(raw.status) ||
    !isCanonicalTicketId(raw.ticketId) ||
    !SHA256_HEX.test(raw.ticketSecretHashSha256) ||
    !SHA256_HEX.test(raw.claimFingerprintSha256) ||
    typeof raw.uid !== "string" ||
    typeof raw.deviceId !== "string" ||
    typeof raw.issuedAtMillis !== "number" ||
    typeof raw.expiresAtMillis !== "number"
  ) {
    return undefined;
  }
  if (raw.purpose === "evidence_upload" && !isCanonicalTicketId(raw.uploadId)) return undefined;
  if (raw.purpose !== "evidence_upload" && raw.purpose !== "enrollment_begin") return undefined;
  if (
    raw.purpose === "enrollment_begin"
    && (!SHA256_HEX.test(raw.akTpmSha256)
      || !SHA256_HEX.test(raw.ekTpmSha256)
      || !SHA256_HEX.test(raw.ekCertificateSha256))
  ) return undefined;
  return raw as StoredLinuxAttestationTicket;
}

/** JSON projection shared with the facade schema; Firestore Timestamp metadata is intentionally omitted. */
export function linuxAttestationTicketIssuanceProjection(
  raw: FirebaseFirestore.DocumentData | undefined,
): Record<string, unknown> | undefined {
  const ticket = parseStoredTicket(raw);
  if (!ticket || ticket.status !== "issued") return undefined;
  const common = {
    schemaVersion: ticket.schemaVersion,
    protocolVersion: ticket.protocolVersion,
    attestationKind: ticket.attestationKind,
    ticketId: ticket.ticketId,
    purpose: ticket.purpose,
    ticketSecretHashSha256: ticket.ticketSecretHashSha256,
    claimFingerprintSha256: ticket.claimFingerprintSha256,
    uid: ticket.uid,
    deviceId: ticket.deviceId,
    issuedAtMillis: ticket.issuedAtMillis,
    expiresAtMillis: ticket.expiresAtMillis,
    status: ticket.status,
  };
  if (ticket.purpose === "enrollment_begin") {
    return {
      ...common,
      akTpmSha256: ticket.akTpmSha256,
      ekTpmSha256: ticket.ekTpmSha256,
      ekCertificateSha256: ticket.ekCertificateSha256,
    };
  }
  return {
    ...common,
    uploadId: ticket.uploadId,
    appId: ticket.appId,
    challengeId: ticket.challengeId,
    challengeHashSha256: ticket.challengeHashSha256,
    releaseDigestSha256: ticket.releaseDigestSha256,
    expectedSha256: ticket.expectedSha256,
    expectedSize: ticket.expectedSize,
  };
}

function newTicketId(): string {
  return randomBytes(LINUX_ATTESTATION_TICKET_ID_BYTES).toString("base64url");
}

function isCanonicalTicketId(raw: unknown): raw is string {
  if (typeof raw !== "string" || raw.length !== LINUX_ATTESTATION_TICKET_ID_LENGTH) return false;
  const decoded = Buffer.from(raw, "base64url");
  return decoded.byteLength === LINUX_ATTESTATION_TICKET_ID_BYTES && decoded.toString("base64url") === raw;
}

function ticketRef(firestore: Firestore, uid: string, ticketId: string): DocumentReference {
  return firestore.doc(`users/${uid}/linux_attestation_ingress_tickets/${ticketId}`);
}

function exactUploadRetry(
  ticket: StoredLinuxAttestationTicket | undefined,
  expected: StoredLinuxUploadTicket,
): boolean {
  return (
    ticket?.purpose === "evidence_upload" &&
    ticket.ticketId === expected.ticketId &&
    ticket.uploadId === expected.uploadId &&
    ticket.ticketSecretHashSha256 === expected.ticketSecretHashSha256 &&
    ticket.claimFingerprintSha256 === expected.claimFingerprintSha256 &&
    ticket.uid === expected.uid &&
    ticket.appId === expected.appId &&
    ticket.deviceId === expected.deviceId &&
    ticket.challengeId === expected.challengeId &&
    ticket.challengeHashSha256 === expected.challengeHashSha256 &&
    ticket.releaseDigestSha256 === expected.releaseDigestSha256 &&
    ticket.expectedSha256 === expected.expectedSha256 &&
    ticket.expectedSize === expected.expectedSize &&
    ticket.expiresAtMillis === expected.expiresAtMillis
  );
}

function exactEnrollmentRetry(
  ticket: StoredLinuxAttestationTicket | undefined,
  input: LinuxEnrollmentTicketRequest,
  claimFingerprintSha256: string,
): ticket is StoredLinuxEnrollmentTicket {
  return (
    ticket?.purpose === "enrollment_begin" &&
    ticket.ticketSecretHashSha256 === input.ticketSecretHashSha256 &&
    ticket.claimFingerprintSha256 === claimFingerprintSha256 &&
    ticket.uid === input.uid &&
    ticket.deviceId === input.deviceId &&
    ticket.akTpmSha256 === input.akTpmSha256 &&
    ticket.ekTpmSha256 === input.ekTpmSha256 &&
    ticket.ekCertificateSha256 === input.ekCertificateSha256
  );
}

export class FirestoreLinuxAttestationTicketAuthority {
  constructor(
    private readonly firestore: Firestore,
    private readonly nowMillis: () => number = Date.now,
    private readonly ticketId: () => string = newTicketId,
    private readonly uploadId: () => string = newTicketId,
  ) {}

  async issueUpload(input: LinuxUploadTicketRequest): Promise<LinuxAttestationTicketIssueResult> {
    const nowMillis = this.nowMillis();
    const candidateTicketId = this.ticketId();
    const candidateUploadId = this.uploadId();
    if (!isCanonicalTicketId(candidateTicketId))
      throw new HttpsError("internal", "Ticket id generator returned invalid data.");
    if (!isCanonicalTicketId(candidateUploadId))
      throw new HttpsError("internal", "Upload id generator returned invalid data.");
    const challengeRef = this.firestore.doc(`users/${input.uid}/linux_app_check_challenges/${input.challengeId}`);
    return this.firestore.runTransaction(async (transaction) => {
      const challengeSnapshot = await transaction.get(challengeRef);
      const challenge = challengeSnapshot.exists ? parseStoredChallenge(challengeSnapshot.data()) : undefined;
      if (!challenge || challenge.uid !== input.uid || challenge.challengeHashSha256 !== sha256Hex(input.challenge)) {
        throw new HttpsError("permission-denied", "Linux attestation challenge possession did not verify.");
      }
      if (challenge.consumedAtMillis !== undefined) {
        throw new HttpsError("permission-denied", "Linux attestation challenge was already consumed.");
      }
      if (challenge.expiresAtMillis <= nowMillis) {
        throw new HttpsError("permission-denied", "Linux attestation challenge expired.");
      }
      const claimFingerprintSha256 = linuxUploadTicketClaimFingerprint({
        uid: input.uid,
        appId: challenge.appId,
        deviceId: challenge.deviceId,
        challengeId: input.challengeId,
        challengeHashSha256: challenge.challengeHashSha256,
        releaseDigestSha256: challenge.releaseDigestSha256,
        expectedSha256: input.expectedSha256,
        expectedSize: input.expectedSize,
      });
      const existingTicketId = challenge.uploadTicketId;
      if (existingTicketId) {
        const existingSnapshot = await transaction.get(ticketRef(this.firestore, input.uid, existingTicketId));
        const expected: StoredLinuxUploadTicket = {
          schemaVersion: LINUX_ATTESTATION_TICKET_SCHEMA_VERSION,
          protocolVersion: LINUX_ATTESTATION_PROTOCOL_VERSION,
          attestationKind: LINUX_ATTESTATION_KIND,
          ticketId: existingTicketId,
          purpose: "evidence_upload",
          uploadId: typeof existingSnapshot.data()?.uploadId === "string" ? existingSnapshot.data()!.uploadId : "",
          ticketSecretHashSha256: input.ticketSecretHashSha256,
          claimFingerprintSha256,
          uid: input.uid,
          appId: challenge.appId,
          deviceId: challenge.deviceId,
          challengeId: input.challengeId,
          challengeHashSha256: challenge.challengeHashSha256,
          releaseDigestSha256: challenge.releaseDigestSha256,
          expectedSha256: input.expectedSha256,
          expectedSize: input.expectedSize,
          issuedAtMillis: 0,
          expiresAtMillis: challenge.expiresAtMillis,
          status: "issued",
        };
        const existing = parseStoredTicket(existingSnapshot.data());
        if (!existing || !exactUploadRetry(existing, { ...expected, issuedAtMillis: existing.issuedAtMillis })) {
          throw new HttpsError("already-exists", "A different upload ticket already exists for this challenge.");
        }
        return { ticketId: existing.ticketId, expiresAtMillis: existing.expiresAtMillis };
      }

      await reserveLinuxAttestationQuotas(
        transaction,
        this.firestore,
        linuxUploadQuotaReservations(input, challenge.deviceId, nowMillis),
      );
      const ticket: StoredLinuxUploadTicket = {
        schemaVersion: LINUX_ATTESTATION_TICKET_SCHEMA_VERSION,
        protocolVersion: LINUX_ATTESTATION_PROTOCOL_VERSION,
        attestationKind: LINUX_ATTESTATION_KIND,
        ticketId: candidateTicketId,
        purpose: "evidence_upload",
        uploadId: candidateUploadId,
        ticketSecretHashSha256: input.ticketSecretHashSha256,
        claimFingerprintSha256,
        uid: input.uid,
        appId: challenge.appId,
        deviceId: challenge.deviceId,
        challengeId: input.challengeId,
        challengeHashSha256: challenge.challengeHashSha256,
        releaseDigestSha256: challenge.releaseDigestSha256,
        expectedSha256: input.expectedSha256,
        expectedSize: input.expectedSize,
        issuedAtMillis: nowMillis,
        expiresAtMillis: challenge.expiresAtMillis,
        status: "issued",
      };
      transaction.create(ticketRef(this.firestore, input.uid, candidateTicketId), {
        ...ticket,
        issuedAt: Timestamp.fromMillis(nowMillis),
        expireAt: Timestamp.fromMillis(ticket.expiresAtMillis),
      });
      transaction.update(challengeRef, {
        uploadTicketId: candidateTicketId,
        uploadTicketClaimFingerprintSha256: claimFingerprintSha256,
        uploadTicketIssuedAtMillis: nowMillis,
      });
      return { ticketId: candidateTicketId, expiresAtMillis: ticket.expiresAtMillis };
    });
  }

  async issueEnrollment(input: LinuxEnrollmentTicketRequest): Promise<LinuxAttestationTicketIssueResult> {
    const nowMillis = this.nowMillis();
    const candidateTicketId = this.ticketId();
    if (!isCanonicalTicketId(candidateTicketId))
      throw new HttpsError("internal", "Ticket id generator returned invalid data.");
    const slotId = linuxAttestationEnrollmentTicketSlotId(input.deviceId);
    const slotRef = this.firestore.doc(`users/${input.uid}/linux_attestation_enrollment_ticket_slots/${slotId}`);
    const claimFingerprintSha256 = linuxEnrollmentTicketClaimFingerprint(input);
    return this.firestore.runTransaction(async (transaction) => {
      const slotSnapshot = await transaction.get(slotRef);
      const slot = slotSnapshot.data();
      if (slotSnapshot.exists && typeof slot?.revokedAtMillis === "number") {
        throw new HttpsError("failed-precondition", "Linux attestation enrollment is revoked for this device.");
      }
      if (
        slotSnapshot.exists &&
        typeof slot?.ticketId === "string" &&
        typeof slot.expiresAtMillis === "number" &&
        slot.expiresAtMillis > nowMillis
      ) {
        const existingSnapshot = await transaction.get(ticketRef(this.firestore, input.uid, slot.ticketId));
        const existing = parseStoredTicket(existingSnapshot.data());
        if (!exactEnrollmentRetry(existing, input, claimFingerprintSha256)) {
          throw new HttpsError("already-exists", "A different enrollment ticket is active for this device.");
        }
        return { ticketId: existing.ticketId, expiresAtMillis: existing.expiresAtMillis };
      }

      await reserveLinuxAttestationQuotas(
        transaction,
        this.firestore,
        linuxEnrollmentQuotaReservations(input, nowMillis),
      );
      const expiresAtMillis = nowMillis + LINUX_ATTESTATION_ENROLLMENT_TICKET_TTL_MS;
      const ticket: StoredLinuxEnrollmentTicket = {
        schemaVersion: LINUX_ATTESTATION_TICKET_SCHEMA_VERSION,
        protocolVersion: LINUX_ATTESTATION_PROTOCOL_VERSION,
        attestationKind: LINUX_ATTESTATION_KIND,
        ticketId: candidateTicketId,
        purpose: "enrollment_begin",
        ticketSecretHashSha256: input.ticketSecretHashSha256,
        claimFingerprintSha256,
        uid: input.uid,
        deviceId: input.deviceId,
        akTpmSha256: input.akTpmSha256,
        ekTpmSha256: input.ekTpmSha256,
        ekCertificateSha256: input.ekCertificateSha256,
        issuedAtMillis: nowMillis,
        expiresAtMillis,
        status: "issued",
      };
      transaction.create(ticketRef(this.firestore, input.uid, candidateTicketId), {
        ...ticket,
        issuedAt: Timestamp.fromMillis(nowMillis),
        expireAt: Timestamp.fromMillis(expiresAtMillis),
      });
      transaction.set(slotRef, {
        schemaVersion: 1,
        purpose: "enrollment_begin",
        deviceId: input.deviceId,
        claimFingerprintSha256,
        ticketId: candidateTicketId,
        expiresAtMillis,
        expireAt: Timestamp.fromMillis(expiresAtMillis),
      });
      return { ticketId: candidateTicketId, expiresAtMillis };
    });
  }
}

export const __testing__ = {
  DAY_MS,
  HOUR_MS,
  TEN_MINUTES_MS,
  UPLOADS_PER_DEVICE_TEN_MINUTES,
  UPLOADS_PER_DEVICE_DAY,
  UPLOADS_PER_UID_DAY,
  UPLOAD_BYTES_PER_UID_DAY,
  ENROLLMENTS_PER_UID_HOUR,
  ENROLLMENTS_PER_UID_DAY,
  ENROLLMENTS_PER_DEVICE_DAY,
  enrollmentReservations: linuxEnrollmentQuotaReservations,
  uploadReservations: linuxUploadQuotaReservations,
  quotaDocId: linuxAttestationQuotaDocId,
  parseStoredTicket,
  isCanonicalTicketId,
};
