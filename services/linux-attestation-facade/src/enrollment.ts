import { createHash, X509Certificate } from "node:crypto";
import { PublicError } from "./errors.js";
import type { EnrollmentRecord } from "./ports.js";
import { sha256 } from "./validation.js";

export function deviceIdForAk(akTpmBase64: string): string {
  return `ak-sha256:${sha256(Buffer.from(akTpmBase64, "base64"))}`;
}

export function deterministicAgentId(uid: string, deviceId: string): string {
  const digest = createHash("sha256")
    .update("openburnbar.linux.keylime-agent.v1\0", "utf8")
    .update(uid, "utf8")
    .update("\0", "utf8")
    .update(deviceId, "utf8")
    .digest();
  const bytes = Buffer.from(digest.subarray(0, 16));
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x80;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function ekPublicKeyPem(ekCertificateBase64: string): string {
  try {
    const certificate = new X509Certificate(Buffer.from(ekCertificateBase64, "base64"));
    return certificate.publicKey.export({ format: "pem", type: "spki" }).toString();
  } catch {
    throw new PublicError(400, "bad_request", "EK certificate is invalid");
  }
}

export function sameEnrollmentIdentity(left: EnrollmentRecord, right: EnrollmentRecord): boolean {
  return left.uid === right.uid
    && left.deviceId === right.deviceId
    && left.agentId === right.agentId
    && left.akTpmBase64 === right.akTpmBase64
    && left.ekTpmBase64 === right.ekTpmBase64
    && left.ekCertificateBase64 === right.ekCertificateBase64
    && left.tpmEkPem === right.tpmEkPem;
}

export function enrollmentRevoked(record: EnrollmentRecord): boolean {
  return typeof record.revokedAtMillis === "number"
    || record.revokedAt != null
    || (typeof record.revokedReason === "string" && record.revokedReason.length > 0)
    || (typeof record.revocationReason === "string" && record.revocationReason.length > 0);
}

export function isActiveEnrollment(record: EnrollmentRecord | undefined, uid: string, deviceId: string): record is EnrollmentRecord {
  return record?.active === true
    && record.uid === uid
    && record.deviceId === deviceId
    && typeof record.agentId === "string"
    && record.agentId.length > 0
    && typeof record.akTpmBase64 === "string"
    && record.akTpmBase64.length > 0
    && typeof record.tpmEkPem === "string"
    && record.tpmEkPem.length > 0
    && !enrollmentRevoked(record);
}
