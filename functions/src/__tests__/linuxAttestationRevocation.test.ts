import { createHash } from "node:crypto";

import type { Firestore } from "firebase-admin/firestore";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  callableRequest,
  callableRunner,
  pathKeyedFirestore,
  seedDoc,
} from "./bola/callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const { store, transactionControl, enforceHighRiskOwnerAction } = vi.hoisted(() => ({
  store: new Map<string, Record<string, unknown>>(),
  transactionControl: { fail: false },
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));

vi.mock("../adminRuntime.js", () => {
  const base = pathKeyedFirestore(store);
  return {
    auth: {},
    db: {
      ...base,
      runTransaction: async (callback: Parameters<typeof base.runTransaction>[0]) => {
        if (transactionControl.fail) throw new Error("required audited transaction unavailable");
        return base.runTransaction(callback);
      },
    },
  };
});
vi.mock("../callables/highRiskOwnerAction.js", () => ({ enforceHighRiskOwnerAction }));
vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

import { db } from "../adminRuntime.js";
import { revokeLinuxAttestationEnrollment } from "../callables/linuxAttestationAdmin.js";
import {
  FirestoreLinuxAttestationEnrollmentTrustStore,
  LINUX_APP_CHECK_TOKEN_TTL_MS,
} from "../security/linuxAttestation.js";
import { linuxAttestationEnrollmentTicketSlotId } from "../security/linuxAttestationIngressTickets.js";

const UID = "linux-owner";
const DEVICE_ID = `ak-sha256:${"b".repeat(64)}`;
const run = callableRunner(revokeLinuxAttestationEnrollment);

function enrollmentPath(uid = UID, deviceId = DEVICE_ID): string {
  const id = createHash("sha256").update([uid, deviceId].join("\n")).digest("hex");
  return `linux_attestation_enrollments/${id}`;
}

function slotPath(uid = UID, deviceId = DEVICE_ID): string {
  return `users/${uid}/linux_attestation_enrollment_ticket_slots/${linuxAttestationEnrollmentTicketSlotId(deviceId)}`;
}

function seedEnrollmentTicket(ticketId: string, overrides: Record<string, unknown> = {}): void {
  seedDoc(store, `users/${UID}/linux_attestation_ingress_tickets/${ticketId}`, {
    schemaVersion: 1,
    protocolVersion: 1,
    attestationKind: "tpm2_ima_signed_verdict_v1",
    ticketId,
    purpose: "enrollment_begin",
    ticketSecretHashSha256: "a".repeat(64),
    claimFingerprintSha256: "c".repeat(64),
    uid: UID,
    deviceId: DEVICE_ID,
    akTpmSha256: "b".repeat(64),
    ekTpmSha256: "d".repeat(64),
    ekCertificateSha256: "e".repeat(64),
    issuedAtMillis: 1_900_000_000_000,
    expiresAtMillis: 1_900_000_300_000,
    status: "executing",
    claimLeaseToken: "claim-lease",
    claimLeaseExpiresAtMillis: 9_999_999_999_999,
    ...overrides,
  });
}

function seedEnrollmentSlot(ticketId: string, overrides: Record<string, unknown> = {}): void {
  seedDoc(store, slotPath(), {
    schemaVersion: 1,
    purpose: "enrollment_begin",
    deviceId: DEVICE_ID,
    claimFingerprintSha256: "c".repeat(64),
    ticketId,
    expiresAtMillis: 1_900_000_300_000,
    expireAt: "ttl-marker",
    ...overrides,
  });
}

function request(overrides: Record<string, unknown> = {}) {
  return callableRequest(UID, {
    deviceId: DEVICE_ID,
    reason: "suspected_compromise",
    trustedDeviceId: "owner-phone",
    nonce: "high-risk-nonce",
    actionProof: { signature: "trusted-device-proof" },
    ...overrides,
  });
}

function seedEnrollment(overrides: Record<string, unknown> = {}): void {
  seedDoc(store, enrollmentPath(), {
    uid: UID,
    deviceId: DEVICE_ID,
    agentId: "linux-agent",
    akTpmBase64: "YWstdHBt",
    ekTpmBase64: "ZWstdHBt",
    ekCertificateBase64: "ZWstY2VydA==",
    tpmEkPem: "-----BEGIN PUBLIC KEY-----\nfixture\n-----END PUBLIC KEY-----",
    active: true,
    ...overrides,
  });
}

function auditEventCount(): number {
  return [...store.keys()].filter((path) => path.includes(`users/${UID}/unified_audit_log/`)).length;
}

describe("revokeLinuxAttestationEnrollment", () => {
  beforeEach(() => {
    store.clear();
    transactionControl.fail = false;
    enforceHighRiskOwnerAction.mockClear();
  });

  it("preserves identity material, removes live leases, terminalizes the begin ticket, and audits the tombstone", async () => {
    const ticketId = "A".repeat(22);
    seedEnrollment({
      active: false,
      beginTicketId: ticketId,
      activationBlob: "credential-secret",
      registrationLeaseToken: "registration-lease",
      registrationLeaseExpiresAtMillis: 9_999_999_999_999,
      activationLeaseToken: "activation-lease",
      activationLeaseExpiresAtMillis: 9_999_999_999_999,
    });
    seedEnrollmentTicket(ticketId);
    seedEnrollmentSlot(ticketId);

    const result = await run(request()) as Record<string, unknown>;
    const enrollment = store.get(enrollmentPath());
    const ticket = store.get(`users/${UID}/linux_attestation_ingress_tickets/${ticketId}`);
    const slot = store.get(slotPath());

    expect(enforceHighRiskOwnerAction).toHaveBeenCalledWith(
      expect.objectContaining({ auth: expect.objectContaining({ uid: UID }) }),
      UID,
      { actionKind: "linux_attestation_enrollment_revoke", subjectId: DEVICE_ID },
    );
    expect(enrollment).toEqual(expect.objectContaining({
      uid: UID,
      deviceId: DEVICE_ID,
      agentId: "linux-agent",
      akTpmBase64: "YWstdHBt",
      ekTpmBase64: "ZWstdHBt",
      ekCertificateBase64: "ZWstY2VydA==",
      active: false,
      revokedReason: "suspected_compromise",
      revokedBy: "user",
      revokedByUid: UID,
    }));
    expect(enrollment).not.toHaveProperty("activationBlob");
    expect(enrollment).not.toHaveProperty("registrationLeaseToken");
    expect(enrollment).not.toHaveProperty("activationLeaseToken");
    expect(ticket).toEqual(expect.objectContaining({
      status: "terminal",
      terminalReason: "enrollment_revoked",
    }));
    expect(ticket).not.toHaveProperty("claimLeaseToken");
    expect(slot).toEqual(expect.objectContaining({
      purpose: "enrollment_begin",
      deviceId: DEVICE_ID,
      revokedReason: "suspected_compromise",
    }));
    expect(slot).not.toHaveProperty("expireAt");
    expect(result).toEqual(expect.objectContaining({
      ok: true,
      deviceId: DEVICE_ID,
      status: "revoked",
      reason: "suspected_compromise",
      audit: expect.objectContaining({ seq: 0, hashSha256: expect.stringMatching(/^[0-9a-f]{64}$/u) }),
    }));
    expect(result.existingTokensExpireNoLaterThanMillis).toBe(
      Number(result.revokedAtMillis) + LINUX_APP_CHECK_TOKEN_TTL_MS,
    );
    expect(JSON.stringify(result)).not.toMatch(/YWstdHBt|ZWstdHBt|ZWstY2VydA/u);
    expect(auditEventCount()).toBe(1);

    const trustStore = new FirestoreLinuxAttestationEnrollmentTrustStore(db as unknown as Firestore);
    await expect(trustStore.requireActive(UID, DEVICE_ID)).rejects.toThrow(/denied/u);
  });

  it("is idempotent and preserves the original revocation timestamp without duplicating completion audit events", async () => {
    seedEnrollment();
    const first = await run(request()) as Record<string, unknown>;
    const originalTimestamp = first.revokedAtMillis;
    const second = await run(request({ reason: "device_retired" })) as Record<string, unknown>;

    expect(second).toEqual(expect.objectContaining({
      status: "already_revoked",
      revokedAtMillis: originalTimestamp,
      reason: "suspected_compromise",
      audit: first.audit,
    }));
    expect(enforceHighRiskOwnerAction).toHaveBeenCalledTimes(1);
    expect(auditEventCount()).toBe(1);
  });

  it("creates durable enrollment and slot tombstones when revocation precedes enrollment materialization", async () => {
    const result = await run(request()) as Record<string, unknown>;

    expect(result.status).toBe("revoked");
    expect(store.get(enrollmentPath())).toEqual(expect.objectContaining({
      uid: UID,
      deviceId: DEVICE_ID,
      active: false,
      revokedReason: "suspected_compromise",
    }));
    expect(store.get(slotPath())).toEqual(expect.objectContaining({
      purpose: "enrollment_begin",
      deviceId: DEVICE_ID,
      revokedReason: "suspected_compromise",
    }));
    expect(auditEventCount()).toBe(1);
  });

  it("terminalizes an issued slot ticket even when the facade has not materialized enrollment", async () => {
    const ticketId = "A".repeat(22);
    seedEnrollmentTicket(ticketId, { status: "issued" });
    seedEnrollmentSlot(ticketId);

    await run(request());

    expect(store.get(enrollmentPath())?.revokedReason).toBe("suspected_compromise");
    expect(store.get(slotPath())?.revokedReason).toBe("suspected_compromise");
    expect(store.get(`users/${UID}/linux_attestation_ingress_tickets/${ticketId}`)?.status).toBe("terminal");
    expect(auditEventCount()).toBe(1);
  });

  it("fails closed for corrupt enrollment ownership without appending completion audit", async () => {
    seedEnrollment({ uid: "different-owner" });
    await expect(run(request())).rejects.toMatchObject({ code: "failed-precondition" });
    expect(store.get(enrollmentPath())?.active).toBe(true);
    expect(auditEventCount()).toBe(0);
  });

  it("fails closed when the deterministic slot ticket binding is inconsistent", async () => {
    const ticketId = "A".repeat(22);
    seedEnrollment();
    seedEnrollmentTicket(ticketId, { deviceId: `ak-sha256:${"f".repeat(64)}` });
    seedEnrollmentSlot(ticketId);

    await expect(run(request())).rejects.toMatchObject({ code: "failed-precondition" });
    expect(store.get(enrollmentPath())?.active).toBe(true);
    expect(store.get(`users/${UID}/linux_attestation_ingress_tickets/${ticketId}`)?.status).toBe("executing");
    expect(auditEventCount()).toBe(0);
  });

  it("leaves an active enrollment untouched when the required audited transaction is unavailable", async () => {
    seedEnrollment();
    transactionControl.fail = true;

    await expect(run(request())).rejects.toThrow(/required audited transaction unavailable/u);
    expect(store.get(enrollmentPath())?.active).toBe(true);
    expect(auditEventCount()).toBe(0);
  });

  it("does not mutate or audit when trusted-device authorization is rejected", async () => {
    seedEnrollment();
    enforceHighRiskOwnerAction.mockRejectedValueOnce(new Error("trusted-device proof rejected"));

    await expect(run(request())).rejects.toThrow(/proof rejected/u);
    expect(store.get(enrollmentPath())?.active).toBe(true);
    expect(auditEventCount()).toBe(0);
  });

  it("rejects malformed input before invoking the high-risk authorization gate", async () => {
    seedEnrollment();
    await expect(run(request({ deviceId: "linux-device" }))).rejects.toMatchObject({ code: "invalid-argument" });
    await expect(run(request({ reason: "because-i-said-so" }))).rejects.toMatchObject({ code: "invalid-argument" });
    expect(enforceHighRiskOwnerAction).not.toHaveBeenCalled();
    expect(store.get(enrollmentPath())?.active).toBe(true);
  });

  it("rejects unauthenticated access before authorization or Firestore mutation", async () => {
    seedEnrollment();
    const unauthenticated = {
      data: request().data,
      app: request().app,
      rawRequest: request().rawRequest,
    };

    await expect(run(unauthenticated)).rejects.toMatchObject({ code: "unauthenticated" });
    expect(enforceHighRiskOwnerAction).not.toHaveBeenCalled();
    expect(store.get(enrollmentPath())?.active).toBe(true);
  });
});
