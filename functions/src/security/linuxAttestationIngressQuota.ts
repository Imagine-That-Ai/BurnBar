import { createHash } from "node:crypto";

import { Timestamp, type Firestore, type Transaction } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

interface UploadQuotaInput {
  uid: string;
  expectedSize: number;
}

interface EnrollmentQuotaInput {
  uid: string;
  deviceId: string;
}

export interface LinuxAttestationQuotaReservation {
  action: string;
  subjectHashSha256: string;
  windowStartMillis: number;
  windowEndMillis: number;
  maximumCount: number;
  maximumBytes?: number;
  countCost: number;
  byteCost: number;
}

export const TEN_MINUTES_MS = 10 * 60 * 1000;
export const HOUR_MS = 60 * 60 * 1000;
export const DAY_MS = 24 * HOUR_MS;
const QUOTA_TTL_GRACE_MS = 2 * DAY_MS;
export const UPLOADS_PER_DEVICE_TEN_MINUTES = 6;
export const UPLOADS_PER_DEVICE_DAY = 72;
export const UPLOADS_PER_UID_DAY = 216;
export const UPLOAD_BYTES_PER_UID_DAY = 2 * 1024 * 1024 * 1024;
export const ENROLLMENTS_PER_UID_HOUR = 2;
export const ENROLLMENTS_PER_UID_DAY = 5;
export const ENROLLMENTS_PER_DEVICE_DAY = 3;

function fingerprint(fields: readonly (string | number)[]): string {
  return createHash("sha256").update(fields.map(String).join("\0")).digest("hex");
}

function quotaSubjectHash(...parts: string[]): string {
  return fingerprint(["openburnbar.linux.attestation-quota-subject.v1", ...parts]);
}

function reservation(
  action: string,
  subjectHashSha256: string,
  nowMillis: number,
  windowMillis: number,
  maximumCount: number,
  byteCost = 0,
  maximumBytes?: number,
): LinuxAttestationQuotaReservation {
  const windowStartMillis = Math.floor(nowMillis / windowMillis) * windowMillis;
  return {
    action,
    subjectHashSha256,
    windowStartMillis,
    windowEndMillis: windowStartMillis + windowMillis,
    maximumCount,
    maximumBytes,
    countCost: 1,
    byteCost,
  };
}

export function linuxUploadQuotaReservations(
  input: UploadQuotaInput,
  deviceId: string,
  nowMillis: number,
): LinuxAttestationQuotaReservation[] {
  const uid = quotaSubjectHash(input.uid);
  const device = quotaSubjectHash(input.uid, deviceId);
  return [
    reservation("upload_device_10m", device, nowMillis, TEN_MINUTES_MS, UPLOADS_PER_DEVICE_TEN_MINUTES),
    reservation("upload_device_24h", device, nowMillis, DAY_MS, UPLOADS_PER_DEVICE_DAY),
    reservation(
      "upload_uid_24h",
      uid,
      nowMillis,
      DAY_MS,
      UPLOADS_PER_UID_DAY,
      input.expectedSize,
      UPLOAD_BYTES_PER_UID_DAY,
    ),
  ];
}

export function linuxEnrollmentQuotaReservations(
  input: EnrollmentQuotaInput,
  nowMillis: number,
): LinuxAttestationQuotaReservation[] {
  const uid = quotaSubjectHash(input.uid);
  const device = quotaSubjectHash(input.uid, input.deviceId);
  return [
    reservation("enrollment_uid_1h", uid, nowMillis, HOUR_MS, ENROLLMENTS_PER_UID_HOUR),
    reservation("enrollment_uid_24h", uid, nowMillis, DAY_MS, ENROLLMENTS_PER_UID_DAY),
    reservation("enrollment_device_24h", device, nowMillis, DAY_MS, ENROLLMENTS_PER_DEVICE_DAY),
  ];
}

export function linuxAttestationQuotaDocId(value: LinuxAttestationQuotaReservation): string {
  return fingerprint([
    "openburnbar.linux.attestation-quota-document.v1",
    value.action,
    value.subjectHashSha256,
    value.windowStartMillis,
  ]);
}

function assertQuotaState(
  raw: FirebaseFirestore.DocumentData | undefined,
  value: LinuxAttestationQuotaReservation,
): void {
  if (
    raw &&
    (raw.schemaVersion !== 1 ||
      raw.action !== value.action ||
      raw.subjectHashSha256 !== value.subjectHashSha256 ||
      raw.windowStartMillis !== value.windowStartMillis ||
      raw.windowEndMillis !== value.windowEndMillis)
  ) {
    throw new HttpsError("internal", "Linux attestation quota state is invalid.");
  }
  const count = typeof raw?.count === "number" ? raw.count : 0;
  const bytes = typeof raw?.bytes === "number" ? raw.bytes : 0;
  if (
    !Number.isSafeInteger(count) ||
    !Number.isSafeInteger(bytes) ||
    count < 0 ||
    bytes < 0 ||
    count + value.countCost > value.maximumCount ||
    (value.maximumBytes !== undefined && bytes + value.byteCost > value.maximumBytes)
  ) {
    throw new HttpsError("resource-exhausted", "Linux attestation quota exceeded.", {
      reason: "linux_attestation_quota_exceeded",
      retryAtMillis: value.windowEndMillis,
    });
  }
}

export async function reserveLinuxAttestationQuotas(
  transaction: Transaction,
  firestore: Firestore,
  values: readonly LinuxAttestationQuotaReservation[],
): Promise<void> {
  const refs = values.map((value) => firestore.doc(`linux_attestation_quota/${linuxAttestationQuotaDocId(value)}`));
  const snapshots = await Promise.all(refs.map((ref) => transaction.get(ref)));
  values.forEach((value, index) => assertQuotaState(snapshots[index]?.data(), value));
  values.forEach((value, index) => {
    const raw = snapshots[index]?.data();
    transaction.set(refs[index]!, {
      schemaVersion: 1,
      action: value.action,
      subjectHashSha256: value.subjectHashSha256,
      windowStartMillis: value.windowStartMillis,
      windowEndMillis: value.windowEndMillis,
      maximumCount: value.maximumCount,
      maximumBytes: value.maximumBytes ?? null,
      count: (typeof raw?.count === "number" ? raw.count : 0) + value.countCost,
      bytes: (typeof raw?.bytes === "number" ? raw.bytes : 0) + value.byteCost,
      updatedAt: Timestamp.now(),
      expireAt: Timestamp.fromMillis(value.windowEndMillis + QUOTA_TTL_GRACE_MS),
    });
  });
}
