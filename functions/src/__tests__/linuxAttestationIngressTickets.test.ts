import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import type { Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { describe, expect, it } from "vitest";

import {
  LINUX_ATTESTATION_CHALLENGE_TTL_MS,
  LINUX_ATTESTATION_KIND,
  LINUX_ATTESTATION_PROTOCOL_VERSION,
  sha256Hex,
} from "../security/linuxAttestation.js";
import {
  FirestoreLinuxAttestationTicketAuthority,
  LINUX_ATTESTATION_ENROLLMENT_TICKET_TTL_MS,
  LINUX_ATTESTATION_MAX_EVIDENCE_BYTES,
  LINUX_ATTESTATION_TICKET_ID_LENGTH,
  LINUX_ATTESTATION_TICKET_SECRET_LENGTH,
  LINUX_ATTESTATION_TICKET_WIRE_PREFIX,
  __testing__,
  linuxAttestationTicketIssuanceProjection,
  linuxAttestationTicketSecretHash,
  linuxEnrollmentTicketClaimFingerprint,
  linuxUploadTicketClaimFingerprint,
  parseLinuxEnrollmentTicketRequest,
  parseLinuxUploadTicketRequest,
  type LinuxEnrollmentTicketRequest,
  type LinuxUploadTicketRequest,
} from "../security/linuxAttestationIngressTickets.js";
import {
  reserveLinuxAttestationQuotas,
  type LinuxAttestationQuotaReservation,
} from "../security/linuxAttestationIngressQuota.js";

const NOW = 1_900_000_000_000;
const UID = "linux-user-1";
const APP_ID = "1:987654321:web:abcdef0123456789";
const RELEASE_DIGEST = "b".repeat(64);
const EXPECTED_DIGEST = "c".repeat(64);
const SECRET_HASH = "1f19e5b47fa987a92f2c36048a53c385f87eb0b86762fe68a631ef9e55585f7f";
const GOLDEN_PATH = resolve(process.cwd(), "../tests/fixtures/linux-attestation/ingress-ticket-v1-golden.json");

interface Ref {
  path: string;
}

class Snapshot {
  constructor(private readonly value: Record<string, unknown> | undefined) {}
  get exists(): boolean {
    return this.value !== undefined;
  }
  data(): Record<string, unknown> | undefined {
    return this.value === undefined ? undefined : { ...this.value };
  }
}

class MemoryTransaction {
  private readonly writes: Array<() => void> = [];
  constructor(private readonly docs: Map<string, Record<string, unknown>>) {}
  async get(ref: Ref): Promise<Snapshot> {
    return new Snapshot(this.docs.get(ref.path));
  }
  create(ref: Ref, value: Record<string, unknown>): void {
    this.writes.push(() => {
      if (this.docs.has(ref.path)) throw new Error(`already exists: ${ref.path}`);
      this.docs.set(ref.path, { ...value });
    });
  }
  set(ref: Ref, value: Record<string, unknown>): void {
    this.writes.push(() => this.docs.set(ref.path, { ...value }));
  }
  update(ref: Ref, value: Record<string, unknown>): void {
    this.writes.push(() => {
      const existing = this.docs.get(ref.path);
      if (!existing) throw new Error(`missing: ${ref.path}`);
      this.docs.set(ref.path, { ...existing, ...value });
    });
  }
  commit(): void {
    for (const write of this.writes) write();
  }
}

class MemoryFirestore {
  readonly docs = new Map<string, Record<string, unknown>>();
  private serial: Promise<void> = Promise.resolve();
  failNextTransaction = false;

  doc(path: string): Ref {
    return { path };
  }

  runTransaction<T>(body: (transaction: MemoryTransaction) => Promise<T>): Promise<T> {
    const run = this.serial.then(async () => {
      const shadow = new Map([...this.docs].map(([path, value]) => [path, { ...value }]));
      const transaction = new MemoryTransaction(shadow);
      const result = await body(transaction);
      transaction.commit();
      if (this.failNextTransaction) {
        this.failNextTransaction = false;
        throw new Error("injected commit failure");
      }
      this.docs.clear();
      for (const [path, value] of shadow) this.docs.set(path, value);
      return result;
    });
    this.serial = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  asFirestore(): Firestore {
    return this as unknown as Firestore;
  }
}

function challenge(
  index: number,
  deviceDigest = "a".repeat(64),
  now = NOW,
): {
  id: string;
  raw: string;
  record: Record<string, unknown>;
} {
  const id = `challenge-${index}`;
  const bytes = Buffer.alloc(32);
  bytes.writeUInt32BE(index, 28);
  const raw = bytes.toString("base64url");
  return {
    id,
    raw,
    record: {
      protocolVersion: LINUX_ATTESTATION_PROTOCOL_VERSION,
      uid: UID,
      appId: APP_ID,
      deviceId: `ak-sha256:${deviceDigest}`,
      appVersion: "1.0.30",
      architecture: "x86_64",
      releaseDigestSha256: RELEASE_DIGEST,
      policyId: "openburnbar-linux-tpm2-ima-v1",
      attestationKind: LINUX_ATTESTATION_KIND,
      challengeHashSha256: sha256Hex(raw),
      createdAtMillis: now,
      expiresAtMillis: now + LINUX_ATTESTATION_CHALLENGE_TTL_MS,
      consumedAtMillis: null,
    },
  };
}

function seedChallenge(store: MemoryFirestore, value: ReturnType<typeof challenge>): void {
  store.docs.set(`users/${UID}/linux_app_check_challenges/${value.id}`, value.record);
}

function uploadRequest(
  value: ReturnType<typeof challenge>,
  overrides: Partial<LinuxUploadTicketRequest> = {},
): LinuxUploadTicketRequest {
  return {
    uid: UID,
    challengeId: value.id,
    challenge: value.raw,
    ticketSecretHashSha256: SECRET_HASH,
    expectedSha256: EXPECTED_DIGEST,
    expectedSize: 1_048_576,
    ...overrides,
  };
}

function enrollmentRequest(
  index: number,
  overrides: Partial<LinuxEnrollmentTicketRequest> = {},
): LinuxEnrollmentTicketRequest {
  const digest = index.toString(16).padStart(64, "0");
  return {
    uid: UID,
    deviceId: `ak-sha256:${digest}`,
    ticketSecretHashSha256: SECRET_HASH,
    akTpmSha256: digest,
    ekTpmSha256: "d".repeat(64),
    ekCertificateSha256: "e".repeat(64),
    ...overrides,
  };
}

function authority(store: MemoryFirestore, now: () => number = () => NOW): FirestoreLinuxAttestationTicketAuthority {
  let next = 0;
  return new FirestoreLinuxAttestationTicketAuthority(store.asFirestore(), now, () => {
    const value = Buffer.alloc(16);
    value.writeUInt32BE(next++, 12);
    return value.toString("base64url");
  });
}

function errorCode(error: unknown): string | undefined {
  return error instanceof HttpsError ? error.code : undefined;
}

async function reserveQuota(
  store: MemoryFirestore,
  value: LinuxAttestationQuotaReservation,
): Promise<void> {
  await store.runTransaction((transaction) =>
    reserveLinuxAttestationQuotas(
      transaction as unknown as Parameters<typeof reserveLinuxAttestationQuotas>[0],
      store.asFirestore(),
      [value],
    ),
  );
}

describe("Linux attestation ingress ticket contract", () => {
  it("matches the shared hash, wire, and claim-fingerprint golden", () => {
    const golden = JSON.parse(readFileSync(GOLDEN_PATH, "utf8")) as {
      upload: {
        ticketId: string;
        ticketSecret: string;
        ticketWire: string;
        issueRequest: Record<string, unknown>;
        ticketRecord: Record<string, unknown>;
      };
      enrollment: {
        ticketId: string;
        ticketSecret: string;
        ticketWire: string;
        issueRequest: Record<string, unknown>;
        ticketRecord: Record<string, unknown>;
      };
    };
    expect(golden.upload.ticketId).toHaveLength(LINUX_ATTESTATION_TICKET_ID_LENGTH);
    expect(golden.upload.ticketSecret).toHaveLength(LINUX_ATTESTATION_TICKET_SECRET_LENGTH);
    expect(golden.upload.ticketWire).toBe(
      `${LINUX_ATTESTATION_TICKET_WIRE_PREFIX}${golden.upload.ticketId}.${golden.upload.ticketSecret}`,
    );
    expect(linuxAttestationTicketSecretHash(Buffer.from(golden.upload.ticketSecret, "base64url"))).toBe(
      golden.upload.issueRequest.ticketSecretHashSha256,
    );
    expect(linuxAttestationTicketSecretHash(Buffer.from(golden.enrollment.ticketSecret, "base64url"))).toBe(
      golden.enrollment.issueRequest.ticketSecretHashSha256,
    );
    expect(sha256Hex(String(golden.upload.issueRequest.challenge))).toBe(
      golden.upload.ticketRecord.challengeHashSha256,
    );
    expect(
      linuxUploadTicketClaimFingerprint({
        uid: String(golden.upload.ticketRecord.uid),
        appId: String(golden.upload.ticketRecord.appId),
        deviceId: String(golden.upload.ticketRecord.deviceId),
        challengeId: String(golden.upload.ticketRecord.challengeId),
        challengeHashSha256: String(golden.upload.ticketRecord.challengeHashSha256),
        releaseDigestSha256: String(golden.upload.ticketRecord.releaseDigestSha256),
        expectedSha256: String(golden.upload.ticketRecord.expectedSha256),
        expectedSize: Number(golden.upload.ticketRecord.expectedSize),
      }),
    ).toBe(golden.upload.ticketRecord.claimFingerprintSha256);
    expect(
      linuxEnrollmentTicketClaimFingerprint({
        uid: String(golden.enrollment.ticketRecord.uid),
        deviceId: String(golden.enrollment.ticketRecord.deviceId),
        ticketSecretHashSha256: String(golden.enrollment.ticketRecord.ticketSecretHashSha256),
        akTpmSha256: String(golden.enrollment.ticketRecord.akTpmSha256),
        ekTpmSha256: String(golden.enrollment.ticketRecord.ekTpmSha256),
        ekCertificateSha256: String(golden.enrollment.ticketRecord.ekCertificateSha256),
      }),
    ).toBe(golden.enrollment.ticketRecord.claimFingerprintSha256);
  });

  it("binds complete emitted Firestore issuance projections to the shared golden", async () => {
    const golden = JSON.parse(readFileSync(GOLDEN_PATH, "utf8")) as {
      upload: { ticketId: string; issueRequest: Record<string, unknown>; ticketRecord: Record<string, unknown> };
      enrollment: { ticketId: string; issueRequest: Record<string, unknown>; ticketRecord: Record<string, unknown> };
    };
    const store = new MemoryFirestore();
    const uploadRecord = golden.upload.ticketRecord;
    store.docs.set(`users/${UID}/linux_app_check_challenges/${String(golden.upload.issueRequest.challengeId)}`, {
      protocolVersion: LINUX_ATTESTATION_PROTOCOL_VERSION,
      uid: uploadRecord.uid,
      appId: uploadRecord.appId,
      deviceId: uploadRecord.deviceId,
      releaseDigestSha256: uploadRecord.releaseDigestSha256,
      attestationKind: LINUX_ATTESTATION_KIND,
      challengeHashSha256: uploadRecord.challengeHashSha256,
      expiresAtMillis: uploadRecord.expiresAtMillis,
      consumedAtMillis: null,
    });
    const ticketIds = [golden.upload.ticketId, golden.enrollment.ticketId];
    const tickets = new FirestoreLinuxAttestationTicketAuthority(
      store.asFirestore(),
      () => NOW,
      () => ticketIds.shift() ?? "",
      () => String(uploadRecord.uploadId),
    );
    await tickets.issueUpload({ uid: UID, ...golden.upload.issueRequest } as LinuxUploadTicketRequest);
    await tickets.issueEnrollment({ uid: UID, ...golden.enrollment.issueRequest } as LinuxEnrollmentTicketRequest);

    const emittedUpload = store.docs.get(`users/${UID}/linux_attestation_ingress_tickets/${golden.upload.ticketId}`);
    const emittedEnrollment = store.docs.get(`users/${UID}/linux_attestation_ingress_tickets/${golden.enrollment.ticketId}`);
    expect(emittedUpload).toMatchObject({ issuedAt: expect.anything(), expireAt: expect.anything() });
    expect(emittedEnrollment).toMatchObject({ issuedAt: expect.anything(), expireAt: expect.anything() });
    expect(linuxAttestationTicketIssuanceProjection(emittedUpload)).toEqual(golden.upload.ticketRecord);
    expect(linuxAttestationTicketIssuanceProjection(emittedEnrollment)).toEqual(golden.enrollment.ticketRecord);
  });

  it("uses a five-minute single-use challenge and enrollment-ticket lifetime", () => {
    expect(LINUX_ATTESTATION_CHALLENGE_TTL_MS).toBe(5 * 60 * 1000);
    expect(LINUX_ATTESTATION_ENROLLMENT_TICKET_TTL_MS).toBe(5 * 60 * 1000);
  });

  it("parses exact requests and rejects unknown, noncanonical, oversized, or non-AK-bound values", () => {
    const value = challenge(1);
    expect(
      parseLinuxUploadTicketRequest(
        {
          challengeId: value.id,
          challenge: value.raw,
          ticketSecretHashSha256: SECRET_HASH,
          expectedSha256: EXPECTED_DIGEST,
          expectedSize: 8,
        },
        UID,
      ),
    ).toMatchObject({ uid: UID, expectedSize: 8 });
    expect(() =>
      parseLinuxUploadTicketRequest(
        {
          challengeId: value.id,
          challenge: value.raw,
          ticketSecretHashSha256: SECRET_HASH,
          expectedSha256: EXPECTED_DIGEST,
          expectedSize: LINUX_ATTESTATION_MAX_EVIDENCE_BYTES + 1,
        },
        UID,
      ),
    ).toThrow(/expectedSize/u);
    expect(() => parseLinuxUploadTicketRequest({ extra: true }, UID)).toThrow(/unknown fields/u);
    expect(() =>
      parseLinuxUploadTicketRequest(
        {
          challengeId: ` ${value.id}`,
          challenge: value.raw,
          ticketSecretHashSha256: SECRET_HASH,
          expectedSha256: EXPECTED_DIGEST,
          expectedSize: 8,
        },
        UID,
      ),
    ).toThrow(/challengeId/u);
    expect(__testing__.isCanonicalTicketId("A".repeat(21) + "B")).toBe(false);
    expect(__testing__.isCanonicalTicketId("A".repeat(22))).toBe(true);
    expect(() =>
      parseLinuxEnrollmentTicketRequest(
        {
          deviceId: `ak-sha256:${"f".repeat(64)}`,
          ticketSecretHashSha256: SECRET_HASH,
          akTpmSha256: "a".repeat(64),
          ekTpmSha256: "d".repeat(64),
          ekCertificateSha256: "e".repeat(64),
        },
        UID,
      ),
    ).toThrow(/derived/u);
  });

  it("atomically binds one upload ticket to challenge possession and never persists raw credentials", async () => {
    const store = new MemoryFirestore();
    const value = challenge(1);
    seedChallenge(store, value);
    const tickets = authority(store);
    const first = await tickets.issueUpload(uploadRequest(value));
    const second = await tickets.issueUpload(uploadRequest(value));
    expect(second).toEqual(first);
    expect(first.expiresAtMillis).toBe(NOW + LINUX_ATTESTATION_CHALLENGE_TTL_MS);
    const persisted = store.docs.get(`users/${UID}/linux_attestation_ingress_tickets/${first.ticketId}`);
    expect(persisted).toMatchObject({
      purpose: "evidence_upload",
      uid: UID,
      challengeId: value.id,
      challengeHashSha256: sha256Hex(value.raw),
      expectedSha256: EXPECTED_DIGEST,
      expectedSize: 1_048_576,
    });
    expect(JSON.stringify(persisted)).not.toContain(value.raw);
    expect(JSON.stringify(persisted)).not.toContain("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8");
    const quotas = [...store.docs.entries()].filter(([path]) => path.startsWith("linux_attestation_quota/"));
    expect(quotas).toHaveLength(3);
    expect(quotas.every(([, record]) => record.count === 1)).toBe(true);
  });

  it("rejects wrong challenge possession, expiry, consumption, and mismatched idempotent retry", async () => {
    const store = new MemoryFirestore();
    const value = challenge(1);
    seedChallenge(store, value);
    const tickets = authority(store);
    await expect(
      tickets.issueUpload(uploadRequest(value, { challenge: Buffer.alloc(32, 2).toString("base64url") })),
    ).rejects.toSatisfy((error: unknown) => errorCode(error) === "permission-denied");
    await tickets.issueUpload(uploadRequest(value));
    await expect(tickets.issueUpload(uploadRequest(value, { expectedSha256: "d".repeat(64) }))).rejects.toSatisfy(
      (error: unknown) => errorCode(error) === "already-exists",
    );
    const consumed = challenge(2);
    consumed.record.consumedAtMillis = NOW;
    seedChallenge(store, consumed);
    await expect(tickets.issueUpload(uploadRequest(consumed))).rejects.toSatisfy(
      (error: unknown) => errorCode(error) === "permission-denied",
    );
    const expired = challenge(3, "a".repeat(64), NOW - LINUX_ATTESTATION_CHALLENGE_TTL_MS - 1);
    seedChallenge(store, expired);
    await expect(tickets.issueUpload(uploadRequest(expired))).rejects.toSatisfy(
      (error: unknown) => errorCode(error) === "permission-denied",
    );
  });

  it("has one winner at the per-device burst boundary under concurrent callers", async () => {
    const store = new MemoryFirestore();
    const values = Array.from({ length: __testing__.UPLOADS_PER_DEVICE_TEN_MINUTES + 1 }, (_, index) =>
      challenge(index + 1),
    );
    values.forEach((value) => seedChallenge(store, value));
    const tickets = authority(store);
    const outcomes = await Promise.allSettled(values.map((value) => tickets.issueUpload(uploadRequest(value))));
    expect(outcomes.filter((outcome) => outcome.status === "fulfilled")).toHaveLength(
      __testing__.UPLOADS_PER_DEVICE_TEN_MINUTES,
    );
    const rejected = outcomes.filter((outcome): outcome is PromiseRejectedResult => outcome.status === "rejected");
    expect(rejected).toHaveLength(1);
    expect(errorCode(rejected[0]?.reason)).toBe("resource-exhausted");
    expect((rejected[0]?.reason as HttpsError).details).toEqual({
      reason: "linux_attestation_quota_exceeded",
      retryAtMillis:
        Math.floor(NOW / __testing__.TEN_MINUTES_MS) * __testing__.TEN_MINUTES_MS + __testing__.TEN_MINUTES_MS,
    });
  });

  it.each([
    {
      action: "upload_device_10m",
      windowMillis: __testing__.TEN_MINUTES_MS,
      reservation: (now: number) => __testing__.uploadReservations(
        { uid: UID, expectedSize: 1 },
        `ak-sha256:${"a".repeat(64)}`,
        now,
      )[0]!,
    },
    {
      action: "upload_device_24h",
      windowMillis: __testing__.DAY_MS,
      reservation: (now: number) => __testing__.uploadReservations(
        { uid: UID, expectedSize: 1 },
        `ak-sha256:${"a".repeat(64)}`,
        now,
      )[1]!,
    },
    {
      action: "upload_uid_24h",
      windowMillis: __testing__.DAY_MS,
      reservation: (now: number) => __testing__.uploadReservations(
        { uid: UID, expectedSize: 1 },
        `ak-sha256:${"a".repeat(64)}`,
        now,
      )[2]!,
    },
    {
      action: "enrollment_uid_1h",
      windowMillis: __testing__.HOUR_MS,
      reservation: (now: number) => __testing__.enrollmentReservations(
        { uid: UID, deviceId: `ak-sha256:${"a".repeat(64)}` },
        now,
      )[0]!,
    },
    {
      action: "enrollment_uid_24h",
      windowMillis: __testing__.DAY_MS,
      reservation: (now: number) => __testing__.enrollmentReservations(
        { uid: UID, deviceId: `ak-sha256:${"a".repeat(64)}` },
        now,
      )[1]!,
    },
    {
      action: "enrollment_device_24h",
      windowMillis: __testing__.DAY_MS,
      reservation: (now: number) => __testing__.enrollmentReservations(
        { uid: UID, deviceId: `ak-sha256:${"a".repeat(64)}` },
        now,
      )[2]!,
    },
  ])("enforces $action exactly under concurrency and rolls the fixed window", async ({ action, windowMillis, reservation }) => {
    const store = new MemoryFirestore();
    const current = reservation(NOW);
    const outcomes = await Promise.allSettled(
      Array.from({ length: current.maximumCount + 1 }, () => reserveQuota(store, current)),
    );
    expect(outcomes.filter((outcome) => outcome.status === "fulfilled")).toHaveLength(current.maximumCount);
    const rejected = outcomes.filter((outcome): outcome is PromiseRejectedResult => outcome.status === "rejected");
    expect(rejected).toHaveLength(1);
    expect(errorCode(rejected[0]?.reason)).toBe("resource-exhausted");
    expect((rejected[0]?.reason as HttpsError).details).toEqual({
      reason: "linux_attestation_quota_exceeded",
      retryAtMillis: current.windowEndMillis,
    });

    const next = reservation(current.windowEndMillis);
    expect(next.windowStartMillis).toBe(current.windowStartMillis + windowMillis);
    await expect(reserveQuota(store, next)).resolves.toBeUndefined();
    const records = [...store.docs.values()].filter((record) => record.action === action);
    expect(records).toHaveLength(2);
    expect(records.map((record) => record.count).sort((left, right) => Number(left) - Number(right))).toEqual([
      1,
      current.maximumCount,
    ]);
  });

  it("enforces the aggregate declared-byte ceiling concurrently without refunds", async () => {
    const store = new MemoryFirestore();
    const count = __testing__.UPLOAD_BYTES_PER_UID_DAY / LINUX_ATTESTATION_MAX_EVIDENCE_BYTES;
    const values = Array.from({ length: count + 1 }, (_, index) =>
      challenge(index + 1, (index + 1).toString(16).padStart(64, "0")),
    );
    values.forEach((value) => seedChallenge(store, value));
    const tickets = authority(store);
    const outcomes = await Promise.allSettled(
      values.map((value) => tickets.issueUpload(
        uploadRequest(value, { expectedSize: LINUX_ATTESTATION_MAX_EVIDENCE_BYTES }),
      )),
    );
    expect(outcomes.filter((outcome) => outcome.status === "fulfilled")).toHaveLength(count);
    const rejected = outcomes.filter((outcome): outcome is PromiseRejectedResult => outcome.status === "rejected");
    expect(rejected).toHaveLength(1);
    expect(errorCode(rejected[0]?.reason)).toBe("resource-exhausted");
    expect(
      [...store.docs.values()].some(
        (record) => record.action === "upload_uid_24h" && record.bytes === __testing__.UPLOAD_BYTES_PER_UID_DAY,
      ),
    ).toBe(true);
  });

  it("rolls fixed quota windows forward while retaining prior charged reservations", async () => {
    let now = NOW;
    const store = new MemoryFirestore();
    const tickets = authority(store, () => now);
    for (let index = 0; index < __testing__.UPLOADS_PER_DEVICE_TEN_MINUTES; index += 1) {
      const value = challenge(index + 1, "a".repeat(64), now);
      seedChallenge(store, value);
      await tickets.issueUpload(uploadRequest(value));
    }
    now += __testing__.TEN_MINUTES_MS;
    const next = challenge(99, "a".repeat(64), now);
    seedChallenge(store, next);
    await expect(tickets.issueUpload(uploadRequest(next))).resolves.toBeTruthy();
    const burstDocs = [...store.docs.values()].filter((record) => record.action === "upload_device_10m");
    expect(burstDocs).toHaveLength(2);
    expect(burstDocs.map((record) => record.count).sort()).toEqual([1, __testing__.UPLOADS_PER_DEVICE_TEN_MINUTES]);
  });

  it("returns one live enrollment ticket idempotently and enforces concurrent per-user quota", async () => {
    const store = new MemoryFirestore();
    const tickets = authority(store);
    const input = enrollmentRequest(1);
    const first = await tickets.issueEnrollment(input);
    expect(await tickets.issueEnrollment(input)).toEqual(first);
    await expect(tickets.issueEnrollment({ ...input, ticketSecretHashSha256: "f".repeat(64) })).rejects.toSatisfy(
      (error: unknown) => errorCode(error) === "already-exists",
    );
    const outcomes = await Promise.allSettled([
      tickets.issueEnrollment(enrollmentRequest(2)),
      tickets.issueEnrollment(enrollmentRequest(3)),
    ]);
    expect(outcomes.filter((outcome) => outcome.status === "fulfilled")).toHaveLength(1);
    expect(outcomes.filter((outcome) => outcome.status === "rejected")).toHaveLength(1);
  });

  it("does not partially persist ticket or quota state when the transaction fails", async () => {
    const store = new MemoryFirestore();
    const value = challenge(1);
    seedChallenge(store, value);
    const before = new Map(store.docs);
    store.failNextTransaction = true;
    await expect(authority(store).issueUpload(uploadRequest(value))).rejects.toThrow(/injected commit failure/u);
    expect(store.docs).toEqual(before);
  });
});
