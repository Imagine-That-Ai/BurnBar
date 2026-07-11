import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { describe, it } from "node:test";
import { FirestoreIngressTicketStore } from "../src/firestoreIngressTicketStore.js";
import { FirestoreEnrollmentStore, FirestoreUploadStateStore } from "../src/googleAdapters.js";
import { deterministicAgentId } from "../src/enrollment.js";
import { PublicError } from "../src/errors.js";
import { enrollmentMaterialHashes, ingressTicketClaimFingerprint, ingressTicketSecretHash } from "../src/ingressTicket.js";
import type { EnrollmentCandidate, EnrollmentRecord, UploadBinding } from "../src/ports.js";
import { ingressTicketCredential } from "./helpers.js";

interface Snapshot {
  exists: boolean;
  data(): Record<string, unknown> | undefined;
}

interface Ref {
  path: string;
  get(): Promise<Snapshot>;
}

function isDeletionTransform(value: unknown): boolean {
  if (typeof value !== "object" || value === null) return false;
  const comparison = (value as { isEqual?: (other: unknown) => boolean }).isEqual;
  return comparison?.call(value, FieldValue.delete()) ?? false;
}

class MemoryFirestore {
  readonly values = new Map<string, Record<string, unknown>>();
  private tail = Promise.resolve();

  doc(path: string): Ref { return this.ref(path); }
  collection(path: string) { return { doc: (id: string): Ref => this.ref(`${path}/${id}`) }; }

  private ref(path: string): Ref {
    return {
      path,
      get: async () => this.snapshot(path),
    };
  }

  private snapshot(path: string): Snapshot {
    const value = this.values.get(path);
    return { exists: value !== undefined, data: () => value === undefined ? undefined : structuredClone(value) };
  }

  async runTransaction<T>(body: (transaction: {
    get(ref: Ref): Promise<{ exists: boolean; data(): Record<string, unknown> | undefined }>;
    create(ref: Ref, value: Record<string, unknown>): void;
    set(ref: Ref, value: Record<string, unknown>): void;
    update(ref: Ref, value: Record<string, unknown>): void;
    delete(ref: Ref): void;
  }) => Promise<T>): Promise<T> {
    let release: (() => void) | undefined;
    const predecessor = this.tail;
    this.tail = new Promise<void>(resolve => { release = resolve; });
    await predecessor;
    try {
      const writes: Array<() => void> = [];
      const result = await body({
        get: async ref => this.snapshot(ref.path),
        create: (ref, value) => writes.push(() => {
          if (this.values.has(ref.path)) throw new Error(`already exists: ${ref.path}`);
          this.values.set(ref.path, structuredClone(value));
        }),
        set: (ref, value) => writes.push(() => this.values.set(ref.path, structuredClone(value))),
        update: (ref, value) => writes.push(() => {
          const existing = this.values.get(ref.path);
          if (existing === undefined) throw new Error(`missing: ${ref.path}`);
          for (const [key, next] of Object.entries(value)) {
            if (isDeletionTransform(next)) Reflect.deleteProperty(existing, key);
            else existing[key] = structuredClone(next);
          }
        }),
        delete: ref => writes.push(() => this.values.delete(ref.path)),
      });
      for (const write of writes) write();
      return result;
    } finally {
      release?.();
    }
  }
}

const NOW = 1_900_000_000_000;
const UID = "user-1";
const TICKET_PATH = `users/${UID}/linux_attestation_ingress_tickets/${ingressTicketCredential.ticketId}`;

function enrollmentPath(value: EnrollmentCandidate): string {
  const id = createHash("sha256").update([value.uid, value.deviceId].join("\n")).digest("hex");
  return `linux_attestation_enrollments/${id}`;
}

function uploadBinding(overrides: Partial<UploadBinding> = {}): UploadBinding {
  return {
    uid: UID,
    appId: "1:246956661961:web:2e267f5d3a84a525480118",
    deviceId: `ak-sha256:${"a".repeat(64)}`,
    challengeId: "challenge-1",
    releaseDigestSha256: "b".repeat(64),
    expectedSha256: "c".repeat(64),
    expectedSize: 4096,
    ...overrides,
  };
}

function uploadTicket(binding = uploadBinding()): Record<string, unknown> {
  const challengeHashSha256 = "d".repeat(64);
  return {
    schemaVersion: 1,
    protocolVersion: 1,
    attestationKind: "tpm2_ima_signed_verdict_v1",
    ticketId: ingressTicketCredential.ticketId,
    purpose: "evidence_upload",
    ticketSecretHashSha256: ingressTicketSecretHash(ingressTicketCredential.secret),
    uid: binding.uid,
    appId: binding.appId,
    deviceId: binding.deviceId,
    challengeId: binding.challengeId,
    challengeHashSha256,
    releaseDigestSha256: binding.releaseDigestSha256,
    expectedSha256: binding.expectedSha256,
    expectedSize: binding.expectedSize,
    uploadId: Buffer.alloc(16, 5).toString("base64url"),
    claimFingerprintSha256: ingressTicketClaimFingerprint("evidence_upload", [
      "1", "tpm2_ima_signed_verdict_v1", binding.uid, binding.appId, binding.deviceId, binding.challengeId,
      challengeHashSha256, binding.releaseDigestSha256, binding.expectedSha256, String(binding.expectedSize),
    ]),
    issuedAtMillis: NOW,
    expiresAtMillis: NOW + 300_000,
    status: "issued",
  };
}

function candidate(): EnrollmentCandidate {
  const deviceId = `ak-sha256:${"a".repeat(64)}`;
  return {
    uid: UID,
    deviceId,
    agentId: deterministicAgentId(UID, deviceId),
    akTpmBase64: Buffer.from("ak").toString("base64"),
    ekTpmBase64: Buffer.from("ek").toString("base64"),
    ekCertificateBase64: Buffer.from("certificate").toString("base64"),
    tpmEkPem: "-----BEGIN PUBLIC KEY-----\nfixture\n-----END PUBLIC KEY-----\n",
    active: false,
  };
}

function enrollmentTicket(value = candidate()): Record<string, unknown> {
  const hashes = enrollmentMaterialHashes(value);
  return {
    schemaVersion: 1,
    protocolVersion: 1,
    attestationKind: "tpm2_ima_signed_verdict_v1",
    ticketId: ingressTicketCredential.ticketId,
    purpose: "enrollment_begin",
    ticketSecretHashSha256: ingressTicketSecretHash(ingressTicketCredential.secret),
    uid: value.uid,
    deviceId: value.deviceId,
    ...hashes,
    claimFingerprintSha256: ingressTicketClaimFingerprint("enrollment_begin", [
      "1", "tpm2_ima_signed_verdict_v1", value.uid, value.deviceId,
      hashes.akTpmSha256, hashes.ekTpmSha256, hashes.ekCertificateSha256,
    ]),
    issuedAtMillis: NOW,
    expiresAtMillis: NOW + 300_000,
    status: "issued",
    attemptCount: 0,
  };
}

describe("FirestoreIngressTicketStore", () => {
  it("atomically claims one server-owned upload and returns it on an identical retry", async () => {
    const firestore = new MemoryFirestore();
    const binding = uploadBinding();
    firestore.values.set(TICKET_PATH, uploadTicket(binding));
    const store = new FirestoreIngressTicketStore(firestore as unknown as Firestore);

    const [first, second] = await Promise.all([
      store.claimUpload(ingressTicketCredential, binding, NOW + 1),
      store.claimUpload(ingressTicketCredential, binding, NOW + 1),
    ]);
    assert.deepEqual(second, first);
    assert.equal(first.uploadId, Buffer.alloc(16, 5).toString("base64url"));
    assert.equal(first.expiresAtMillis, NOW + 300_000);
    assert.equal(firestore.values.get(TICKET_PATH)?.status, "claimed");
    assert.equal([...firestore.values.keys()].filter(path => path.startsWith("linux_attestation_uploads/")).length, 1);
  });

  it("uniformly rejects wrong secret, UID, expiry, and binding without allocating an upload", async () => {
    for (const mutate of [
      (firestore: MemoryFirestore) => firestore.values.set(TICKET_PATH, { ...uploadTicket(), expiresAtMillis: NOW }),
      (firestore: MemoryFirestore) => firestore.values.set(TICKET_PATH, { ...uploadTicket(), uid: "other" }),
      (firestore: MemoryFirestore) => firestore.values.set(TICKET_PATH, { ...uploadTicket(), expectedSize: 1 }),
    ]) {
      const firestore = new MemoryFirestore();
      mutate(firestore);
      const store = new FirestoreIngressTicketStore(firestore as unknown as Firestore);
      await assert.rejects(store.claimUpload(ingressTicketCredential, uploadBinding(), NOW + 1), (error: unknown) =>
        error instanceof PublicError && error.status === 403 && error.code === "forbidden");
      assert.equal([...firestore.values.keys()].some(path => path.startsWith("linux_attestation_uploads/")), false);
    }
    const firestore = new MemoryFirestore();
    firestore.values.set(TICKET_PATH, uploadTicket());
    const store = new FirestoreIngressTicketStore(firestore as unknown as Firestore);
    await assert.rejects(store.claimUpload({ ...ingressTicketCredential, secret: Buffer.alloc(32) }, uploadBinding(), NOW + 1), (error: unknown) =>
      error instanceof PublicError && error.status === 403);
  });

  it("leases bounded enrollment attempts and caches the successful activation blob", async () => {
    const firestore = new MemoryFirestore();
    const enrollment = candidate();
    firestore.values.set(TICKET_PATH, enrollmentTicket(enrollment));
    const store = new FirestoreIngressTicketStore(firestore as unknown as Firestore);
    const first = await store.claimEnrollmentBegin(ingressTicketCredential, enrollment, NOW + 1, 75_000, 3);
    assert.equal(first.kind, "acquired");
    if (first.kind !== "acquired") throw new Error("fixture did not acquire enrollment");
    assert.deepEqual(await store.claimEnrollmentBegin(ingressTicketCredential, enrollment, NOW + 2, 75_000, 3), { kind: "busy" });
    await store.completeEnrollmentBegin(UID, enrollment.deviceId, ingressTicketCredential.ticketId, first.leaseToken, "activation-blob");
    const cached = await store.claimEnrollmentBegin(ingressTicketCredential, enrollment, NOW + 3, 75_000, 3);
    assert.equal(cached.kind, "cached");
    if (cached.kind !== "cached") throw new Error("fixture did not cache enrollment");
    assert.equal(cached.record.activationBlob, "activation-blob");
    const hashes = enrollmentMaterialHashes(enrollment);
    assert.equal(firestore.values.get(TICKET_PATH)?.claimFingerprintSha256, ingressTicketClaimFingerprint("enrollment_begin", [
      "1", "tpm2_ima_signed_verdict_v1", UID, enrollment.deviceId, hashes.akTpmSha256, hashes.ekTpmSha256, hashes.ekCertificateSha256,
    ]));
  });

  it("terminalizes a ticket after three retryable registrar attempts", async () => {
    const firestore = new MemoryFirestore();
    const enrollment = candidate();
    firestore.values.set(TICKET_PATH, enrollmentTicket(enrollment));
    const store = new FirestoreIngressTicketStore(firestore as unknown as Firestore);
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const claim = await store.claimEnrollmentBegin(ingressTicketCredential, enrollment, NOW + attempt, 75_000, 3);
      if (claim.kind !== "acquired") throw new Error("fixture did not acquire enrollment");
      await store.releaseEnrollmentBegin(UID, enrollment.deviceId, ingressTicketCredential.ticketId, claim.leaseToken);
    }
    await assert.rejects(store.claimEnrollmentBegin(ingressTicketCredential, enrollment, NOW + 4, 75_000, 3), (error: unknown) =>
      error instanceof PublicError && error.status === 429 && error.code === "rate_limited");
    assert.equal(firestore.values.get(TICKET_PATH)?.status, "terminal");
  });

  it("rebinds an activation blob from an expired prior ticket without repeating registration", async () => {
    const firestore = new MemoryFirestore();
    const enrollment = candidate();
    const previousTicketId = Buffer.alloc(16, 4).toString("base64url");
    const previousPath = `users/${UID}/linux_attestation_ingress_tickets/${previousTicketId}`;
    firestore.values.set(TICKET_PATH, enrollmentTicket(enrollment));
    firestore.values.set(previousPath, {
      ...enrollmentTicket(enrollment),
      ticketId: previousTicketId,
      expiresAtMillis: NOW,
      status: "succeeded",
    });
    const pending: EnrollmentRecord = {
      ...enrollment,
      beginTicketId: previousTicketId,
      activationBlob: "activation-blob",
    };
    firestore.values.set(enrollmentPath(enrollment), pending as unknown as Record<string, unknown>);
    const store = new FirestoreIngressTicketStore(firestore as unknown as Firestore);

    const result = await store.claimEnrollmentBegin(ingressTicketCredential, enrollment, NOW + 1, 75_000, 3);
    assert.equal(result.kind, "cached");
    if (result.kind !== "cached") throw new Error("fixture did not recover cached enrollment");
    assert.equal(result.record.activationBlob, "activation-blob");
    assert.equal(result.record.beginTicketId, ingressTicketCredential.ticketId);
    assert.equal(firestore.values.get(TICKET_PATH)?.status, "succeeded");
    assert.equal(firestore.values.get(previousPath)?.status, "terminal");
  });

  it("reclaims an exact pending identity after its prior ticket was removed by TTL", async () => {
    const firestore = new MemoryFirestore();
    const enrollment = candidate();
    const previousTicketId = Buffer.alloc(16, 3).toString("base64url");
    firestore.values.set(TICKET_PATH, enrollmentTicket(enrollment));
    firestore.values.set(enrollmentPath(enrollment), {
      ...enrollment,
      beginTicketId: previousTicketId,
    } as unknown as Record<string, unknown>);
    const store = new FirestoreIngressTicketStore(firestore as unknown as Firestore);

    const result = await store.claimEnrollmentBegin(ingressTicketCredential, enrollment, NOW + 1, 75_000, 3);
    assert.equal(result.kind, "acquired");
    assert.equal(firestore.values.get(enrollmentPath(enrollment))?.beginTicketId, ingressTicketCredential.ticketId);
  });

  it("never replaces a live prior ticket or changes the pending TPM identity", async () => {
    const previousTicketId = Buffer.alloc(16, 2).toString("base64url");
    for (const setup of [
      (firestore: MemoryFirestore, enrollment: EnrollmentCandidate) => {
        firestore.values.set(`users/${UID}/linux_attestation_ingress_tickets/${previousTicketId}`, {
          ...enrollmentTicket(enrollment),
          ticketId: previousTicketId,
          expiresAtMillis: NOW + 300_000,
        });
        return enrollment;
      },
      (_firestore: MemoryFirestore, enrollment: EnrollmentCandidate) => ({
        ...enrollment,
        akTpmBase64: Buffer.from("different-ak").toString("base64"),
      }),
    ]) {
      const firestore = new MemoryFirestore();
      const existing = candidate();
      const requested = setup(firestore, existing);
      firestore.values.set(TICKET_PATH, enrollmentTicket(requested));
      firestore.values.set(enrollmentPath(existing), {
        ...existing,
        beginTicketId: previousTicketId,
      } as unknown as Record<string, unknown>);
      const store = new FirestoreIngressTicketStore(firestore as unknown as Firestore);
      await assert.rejects(
        store.claimEnrollmentBegin(ingressTicketCredential, requested, NOW + 1, 75_000, 3),
        (error: unknown) => error instanceof PublicError && error.code === "conflict",
      );
    }
  });

  it("preserves revoked enrollment tombstones against replacement", async () => {
    const firestore = new MemoryFirestore();
    const enrollment = candidate();
    firestore.values.set(TICKET_PATH, enrollmentTicket(enrollment));
    firestore.values.set(enrollmentPath(enrollment), {
      uid: enrollment.uid,
      deviceId: enrollment.deviceId,
      active: false,
      revokedAtMillis: NOW,
      revokedReason: "operator_revoke",
    } as unknown as Record<string, unknown>);
    const store = new FirestoreIngressTicketStore(firestore as unknown as Firestore);

    await assert.rejects(
      store.claimEnrollmentBegin(ingressTicketCredential, enrollment, NOW + 1, 75_000, 3),
      (error: unknown) => error instanceof PublicError && error.code === "conflict",
    );
    assert.equal(firestore.values.get(enrollmentPath(enrollment))?.revokedReason, "operator_revoke");
  });

  it("preserves a revoked tombstone when retry exhaustion terminals its ticket", async () => {
    const firestore = new MemoryFirestore();
    const enrollment = candidate();
    firestore.values.set(TICKET_PATH, { ...enrollmentTicket(enrollment), attemptCount: 3 });
    firestore.values.set(enrollmentPath(enrollment), {
      ...enrollment,
      beginTicketId: ingressTicketCredential.ticketId,
      revokedAtMillis: NOW,
      revokedReason: "operator_revoke",
    } as unknown as Record<string, unknown>);
    const store = new FirestoreIngressTicketStore(firestore as unknown as Firestore);

    await assert.rejects(
      store.claimEnrollmentBegin(ingressTicketCredential, enrollment, NOW + 1, 75_000, 3),
      (error: unknown) => error instanceof PublicError && error.code === "rate_limited",
    );
    assert.equal(firestore.values.get(enrollmentPath(enrollment))?.revokedReason, "operator_revoke");
    assert.equal(firestore.values.get(TICKET_PATH)?.status, "terminal");
  });
});

describe("Firestore ingress state adapters", () => {
  it("never deletes a revoked pending-enrollment tombstone during stale-worker cleanup", async () => {
    const firestore = new MemoryFirestore();
    const enrollment = candidate();
    const path = enrollmentPath(enrollment);
    firestore.values.set(path, {
      ...enrollment,
      registrationLeaseToken: "registration-lease",
      registrationLeaseExpiresAtMillis: NOW + 10_000,
      activationLeaseToken: "activation-lease",
      activationLeaseExpiresAtMillis: NOW + 10_000,
      revokedAtMillis: NOW,
      revokedReason: "suspected_compromise",
    } as unknown as Record<string, unknown>);

    const enrollmentStore = new FirestoreEnrollmentStore(firestore as unknown as Firestore);
    await enrollmentStore.releaseRegistration(UID, enrollment.deviceId, "registration-lease");
    await enrollmentStore.deletePending(UID, enrollment.deviceId, enrollment.agentId);

    const ingressStore = new FirestoreIngressTicketStore(firestore as unknown as Firestore);
    await ingressStore.terminalizePendingEnrollment(
      UID,
      enrollment.deviceId,
      enrollment.agentId,
      "activation-lease",
    );

    assert.equal(firestore.values.get(path)?.revokedReason, "suspected_compromise");
    assert.equal(firestore.values.get(path)?.revokedAtMillis, NOW);
  });

  it("admits at most three concurrent upload body attempts, including receipt retries", async () => {
    const firestore = new MemoryFirestore();
    const binding = uploadBinding();
    const uploadId = Buffer.alloc(16, 5).toString("base64url");
    const path = `linux_attestation_uploads/${uploadId}`;
    firestore.values.set(path, {
      ...binding,
      uploadId,
      objectName: `linux-attestation/evidence/${uploadId}`,
      expiresAtMillis: NOW + 300_000,
      status: "uploaded",
      generation: "1",
    });
    const store = new FirestoreUploadStateStore(firestore as unknown as Firestore);
    const claims = await Promise.allSettled(Array.from({ length: 4 }, () => store.claimUploadAttempt(uploadId, UID, NOW + 1, 3)));
    assert.equal(claims.filter(result => result.status === "fulfilled").length, 3);
    assert.equal(claims.filter(result => result.status === "rejected"
      && result.reason instanceof PublicError
      && result.reason.code === "rate_limited").length, 1);
    assert.equal(firestore.values.get(path)?.uploadAttemptCount, 3);
  });

  it("fences stale activation workers after lease reclamation", async () => {
    const firestore = new MemoryFirestore();
    const enrollment = candidate();
    firestore.values.set(enrollmentPath(enrollment), {
      ...enrollment,
      activationBlob: "activation-blob",
      beginTicketId: ingressTicketCredential.ticketId,
    } as unknown as Record<string, unknown>);
    const store = new FirestoreEnrollmentStore(firestore as unknown as Firestore);
    const first = await store.claimActivation(UID, enrollment.deviceId, NOW, 10);
    assert.equal(first.kind, "acquired");
    assert.deepEqual(await store.claimActivation(UID, enrollment.deviceId, NOW + 5, 10), { kind: "busy" });
    const second = await store.claimActivation(UID, enrollment.deviceId, NOW + 11, 10);
    if (first.kind !== "acquired" || second.kind !== "acquired") throw new Error("fixture did not acquire activation leases");
    await assert.rejects(
      store.activate(UID, enrollment.deviceId, enrollment.agentId, first.leaseToken),
      (error: unknown) => error instanceof PublicError && error.code === "conflict",
    );
    await store.releaseActivation(UID, enrollment.deviceId, first.leaseToken);
    assert.equal(firestore.values.get(enrollmentPath(enrollment))?.activationLeaseToken, second.leaseToken);
    await store.activate(UID, enrollment.deviceId, enrollment.agentId, second.leaseToken);
    assert.equal(firestore.values.get(enrollmentPath(enrollment))?.active, true);
    assert.equal(firestore.values.get(enrollmentPath(enrollment))?.activationBlob, undefined);
  });

  it("rejects revoked active enrollments from verifier use", async () => {
    const firestore = new MemoryFirestore();
    const enrollment = candidate();
    firestore.values.set(enrollmentPath(enrollment), {
      ...enrollment,
      active: true,
      revokedAtMillis: NOW,
      revokedReason: "operator_revoke",
    } as unknown as Record<string, unknown>);
    const store = new FirestoreEnrollmentStore(firestore as unknown as Firestore);

    await assert.rejects(
      store.requireActive(UID, enrollment.deviceId),
      (error: unknown) => error instanceof PublicError && error.status === 403 && error.code === "verification_failed",
    );
  });
});
