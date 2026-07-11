import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { assertAuth } from "../auth.js";
import { getConfig } from "../config.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  LINUX_APP_CHECK_TOKEN_TTL_MS,
  linuxAttestationEnrollmentDocId,
} from "../security/linuxAttestation.js";
import {
  linuxAttestationEnrollmentTicketSlotId,
  parseStoredLinuxAttestationEnrollmentTicketSlot,
  parseStoredTicket,
} from "../security/linuxAttestationIngressTickets.js";
import {
  optionalEnumField,
  parseCallableInput,
  requiredString,
} from "../validation/callableSchema.js";
import {
  AUDIT_ACTIONS,
  auditActorLabel,
  runAuditedMutationRequired,
} from "./auditLog.js";
import { enforceHighRiskOwnerAction } from "./highRiskOwnerAction.js";

const LINUX_ATTESTATION_DEVICE_ID = /^ak-sha256:[0-9a-f]{64}$/u;
const REVOCATION_REASONS = [
  "user_requested",
  "device_lost",
  "suspected_compromise",
  "device_retired",
] as const;

type LinuxAttestationRevocationReason = (typeof REVOCATION_REASONS)[number];

const REVOKE_LINUX_ATTESTATION_INPUT = {
  deviceId: requiredString({
    maxLength: 160,
    pattern: LINUX_ATTESTATION_DEVICE_ID,
    patternMessage: "deviceId must be an AK SHA-256 device identifier.",
  }),
  reason: optionalEnumField(REVOCATION_REASONS),
};

interface RevokeLinuxAttestationInput {
  deviceId: string;
  reason: LinuxAttestationRevocationReason;
}

interface RevocationTransition {
  status: "revoked" | "already_revoked";
  revokedAtMillis: number;
  reason: string;
}

function parseRevokeLinuxAttestationInput(data: unknown): RevokeLinuxAttestationInput {
  // High-risk proof is an object and is verified by enforceHighRiskOwnerAction;
  // declare only the scalar fields here so unknown proof fields remain opaque.
  const parsed = parseCallableInput(
    "revokeLinuxAttestationEnrollment",
    {
      deviceId: REVOKE_LINUX_ATTESTATION_INPUT.deviceId,
      reason: REVOKE_LINUX_ATTESTATION_INPUT.reason,
    },
    data,
  );
  if (typeof parsed.deviceId !== "string") {
    throw new HttpsError("invalid-argument", "deviceId is required.");
  }
  const reason = parsed.reason ?? "user_requested";
  if (typeof reason !== "string" || !REVOCATION_REASONS.includes(reason as LinuxAttestationRevocationReason)) {
    throw new HttpsError("invalid-argument", "reason is not supported.");
  }
  return { deviceId: parsed.deviceId, reason: reason as LinuxAttestationRevocationReason };
}

function enrollmentRevoked(raw: FirebaseFirestore.DocumentData): boolean {
  return typeof raw.revokedAtMillis === "number"
    || raw.revokedAt != null
    || (typeof raw.revokedReason === "string" && raw.revokedReason.length > 0)
    || (typeof raw.revocationReason === "string" && raw.revocationReason.length > 0);
}

function timestampMillis(raw: unknown): number | undefined {
  if (typeof raw !== "object" || raw === null) return undefined;
  const toMillis = Reflect.get(raw, "toMillis");
  if (typeof toMillis !== "function") return undefined;
  const value = Reflect.apply(toMillis, raw, []);
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function existingRevocationReason(
  raw: FirebaseFirestore.DocumentData,
  fallback: LinuxAttestationRevocationReason,
): string {
  if (typeof raw.revokedReason === "string" && raw.revokedReason.length > 0) return raw.revokedReason;
  if (typeof raw.revocationReason === "string" && raw.revocationReason.length > 0) return raw.revocationReason;
  return fallback;
}

function existingRevocationTimestamp(raw: FirebaseFirestore.DocumentData): number {
  if (typeof raw.revokedAtMillis === "number" && Number.isFinite(raw.revokedAtMillis)) {
    return raw.revokedAtMillis;
  }
  return timestampMillis(raw.revokedAt)
    ?? (typeof raw.updatedAtMillis === "number" && Number.isFinite(raw.updatedAtMillis)
      ? raw.updatedAtMillis
      : timestampMillis(raw.updatedAt) ?? 0);
}

function existingRevocationAudit(raw: FirebaseFirestore.DocumentData): { seq: number; hash: string } | undefined {
  if (
    Number.isSafeInteger(raw.revocationAuditSeq)
    && raw.revocationAuditSeq >= 0
    && typeof raw.revocationAuditHashSha256 === "string"
    && /^[0-9a-f]{64}$/u.test(raw.revocationAuditHashSha256)
  ) {
    return { seq: raw.revocationAuditSeq as number, hash: raw.revocationAuditHashSha256 };
  }
  return undefined;
}

function revocationResponse(
  deviceId: string,
  transition: RevocationTransition,
  auditEvent?: { seq: number; hash: string },
) {
  return {
    ok: true,
    deviceId,
    status: transition.status,
    reason: transition.reason,
    revokedAtMillis: transition.revokedAtMillis,
    existingTokensExpireNoLaterThanMillis: transition.revokedAtMillis + LINUX_APP_CHECK_TOKEN_TTL_MS,
    audit: auditEvent ? { seq: auditEvent.seq, hashSha256: auditEvent.hash } : null,
  };
}

export const revokeLinuxAttestationEnrollment = onCallProduction(
  "revokeLinuxAttestationEnrollment",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
  },
  async (request: CallableRequest<Record<string, unknown>>) => {
    assertAuth(request);
    const uid = request.auth!.uid;
    const input = parseRevokeLinuxAttestationInput(request.data);

    const enrollmentRef = db.collection("linux_attestation_enrollments")
      .doc(linuxAttestationEnrollmentDocId(uid, input.deviceId));
    const slotRef = db.doc(
      `users/${uid}/linux_attestation_enrollment_ticket_slots/${linuxAttestationEnrollmentTicketSlotId(input.deviceId)}`,
    );
    const [existingSnapshot, existingSlotSnapshot] = await Promise.all([
      enrollmentRef.get(),
      slotRef.get(),
    ]);
    const existingEnrollment = existingSnapshot.data();
    const existingSlot = existingSlotSnapshot.exists
      ? parseStoredLinuxAttestationEnrollmentTicketSlot(existingSlotSnapshot.data())
      : undefined;
    if (existingSnapshot.exists && (!existingEnrollment
      || existingEnrollment.uid !== uid
      || existingEnrollment.deviceId !== input.deviceId)) {
      throw new HttpsError("failed-precondition", "Linux attestation enrollment ownership is inconsistent.");
    }
    if (existingSlotSnapshot.exists && (!existingSlot || existingSlot.deviceId !== input.deviceId)) {
      throw new HttpsError("failed-precondition", "Linux attestation enrollment ticket slot is inconsistent.");
    }
    if (existingEnrollment && enrollmentRevoked(existingEnrollment) && existingSlot?.revokedAtMillis !== undefined) {
      const transition: RevocationTransition = {
        status: "already_revoked",
        revokedAtMillis: existingRevocationTimestamp(existingEnrollment),
        reason: existingRevocationReason(existingEnrollment, input.reason),
      };
      logInfo({
        event: "callable_info",
        message: "linux_attestation_enrollment_revoked",
        device_id: input.deviceId,
        status: transition.status,
        reason: transition.reason,
      });
      return revocationResponse(input.deviceId, transition, existingRevocationAudit(existingEnrollment));
    }

    await enforceHighRiskOwnerAction(request, uid, {
      actionKind: "linux_attestation_enrollment_revoke",
      subjectId: input.deviceId,
    });

    const nowMillis = Date.now();
    const audited = await runAuditedMutationRequired<RevocationTransition>(
      uid,
      {
        actor: auditActorLabel(request),
        action: AUDIT_ACTIONS.linuxAttestationRevoke,
        domain: `linux_attestation:${input.deviceId}`,
      },
      async (transaction) => {
        const enrollmentSnapshot = await transaction.get(enrollmentRef);
        const enrollment = enrollmentSnapshot.data();
        const slotSnapshot = await transaction.get(slotRef);
        const slot = slotSnapshot.exists
          ? parseStoredLinuxAttestationEnrollmentTicketSlot(slotSnapshot.data())
          : undefined;
        if (enrollmentSnapshot.exists && (!enrollment || enrollment.uid !== uid || enrollment.deviceId !== input.deviceId)) {
          throw new HttpsError("failed-precondition", "Linux attestation enrollment ownership is inconsistent.");
        }
        if (slotSnapshot.exists && (!slot || slot.deviceId !== input.deviceId)) {
          throw new HttpsError("failed-precondition", "Linux attestation enrollment ticket slot is inconsistent.");
        }

        if (enrollment && enrollmentRevoked(enrollment) && slot?.revokedAtMillis !== undefined) {
          return {
            value: {
              status: "already_revoked",
              revokedAtMillis: existingRevocationTimestamp(enrollment),
              reason: existingRevocationReason(enrollment, input.reason),
            } satisfies RevocationTransition,
          };
        }

        let slotTicketRef: FirebaseFirestore.DocumentReference | undefined;
        if (slot && slot.revokedAtMillis === undefined && slot.ticketId) {
          slotTicketRef = db.doc(`users/${uid}/linux_attestation_ingress_tickets/${slot.ticketId}`);
          const ticketSnapshot = await transaction.get(slotTicketRef);
          const ticket = parseStoredTicket(ticketSnapshot.data());
          if (
            !ticketSnapshot.exists
            || !ticket
            || ticket.ticketId !== slot.ticketId
            || ticket.uid !== uid
            || ticket.deviceId !== input.deviceId
            || ticket.purpose !== "enrollment_begin"
            || ticket.claimFingerprintSha256 !== slot.claimFingerprintSha256
            || ticket.expiresAtMillis !== slot.expiresAtMillis
          ) {
            throw new HttpsError("failed-precondition", "Linux attestation enrollment ticket is inconsistent.");
          }
        }

        const now = Timestamp.fromMillis(nowMillis);
        return {
          value: {
            status: "revoked",
            revokedAtMillis: nowMillis,
            reason: input.reason,
          } satisfies RevocationTransition,
          apply: (writer, auditEvent) => {
            writer.set(
              enrollmentRef,
              {
                uid,
                deviceId: input.deviceId,
                active: false,
                revokedAtMillis: nowMillis,
                revokedAt: now,
                revokedReason: input.reason,
                revokedBy: "user",
                revokedByUid: uid,
                revocationAuditSeq: auditEvent.seq,
                revocationAuditHashSha256: auditEvent.hash,
                updatedAtMillis: nowMillis,
                updatedAt: now,
                activationBlob: FieldValue.delete(),
                registrationLeaseToken: FieldValue.delete(),
                registrationLeaseExpiresAtMillis: FieldValue.delete(),
                activationLeaseToken: FieldValue.delete(),
                activationLeaseExpiresAtMillis: FieldValue.delete(),
              },
              { merge: true },
            );
            writer.set(
              slotRef,
              {
                schemaVersion: 1,
                purpose: "enrollment_begin",
                deviceId: input.deviceId,
                revokedAtMillis: nowMillis,
                revokedAt: now,
                revokedReason: input.reason,
                expireAt: FieldValue.delete(),
              },
              { merge: true },
            );
            if (slotTicketRef) {
              writer.set(
                slotTicketRef,
                {
                  status: "terminal",
                  terminalAt: now,
                  terminalReason: "enrollment_revoked",
                  claimLeaseToken: FieldValue.delete(),
                  claimLeaseExpiresAtMillis: FieldValue.delete(),
                },
                { merge: true },
              );
            }
          },
        };
      },
    );

    logInfo({
      event: "callable_info",
      message: "linux_attestation_enrollment_revoked",
      device_id: input.deviceId,
      status: audited.value.status,
      reason: audited.value.reason,
      audit_seq: audited.auditEvent?.seq,
    });
    return revocationResponse(input.deviceId, audited.value, audited.auditEvent);
  },
);

export const __testing__ = {
  parseRevokeLinuxAttestationInput,
  enrollmentRevoked,
  timestampMillis,
  existingRevocationTimestamp,
  existingRevocationAudit,
};
