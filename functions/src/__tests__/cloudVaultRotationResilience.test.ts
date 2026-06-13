/**
 * RR-5 — CloudVault rotation resilience (server side of a client-pickup design).
 *
 * Proves the three server-side seams that close the "rotation requirement sits
 * pending forever" gap when the revoking device is offline or the revoke was
 * initiated from a device that never runs the rewrap:
 *
 *  1. `listPendingCloudVaultRotationRequirements` returns ONLY the pending
 *     requirements for which the calling trusted device is a listed survivor
 *     (so any surviving device can discover and complete rotation).
 *  2. `rotateCloudVaultKey` accepts completion by a NON-revoker survivor (the
 *     gate is "any trusted survivor that includes its own wrapper", never "the
 *     revoking device").
 *  3. `sweepStalePendingCloudVaultRotations` flags requirements pending past the
 *     staleness window with a structured warning AND best-effort nudges each
 *     surviving device with a silent `fcm_outbound` data push.
 */

import { describe, expect, it, beforeEach, vi } from "vitest";

// ---------------------------------------------------------------------------
// In-memory Firestore double. Supports the access patterns under test:
//   db.doc(path).get()/set()/create(), db.collection(path).where().get(),
//   db.collectionGroup(name).where().where().orderBy().limit().get(),
//   db.runTransaction(fn), tx.get/set/create, FieldValue.increment/serverTimestamp.
// ---------------------------------------------------------------------------
const { store, dbMock, FieldValueMock, FakeTimestamp } = vi.hoisted(() => {
  const store = new Map<string, Record<string, unknown>>();

  class FakeTimestamp {
    constructor(public readonly ms: number) {}
    static now(): FakeTimestamp {
      return new FakeTimestamp(Date.now());
    }
    toMillis(): number {
      return this.ms;
    }
  }
  const FieldValueMock = {
    serverTimestamp: () => ({ __serverTimestamp: true }),
    increment: (n: number) => ({ __increment: n }),
  };

  const applyPatch = (path: string, data: Record<string, unknown>, merge: boolean) => {
    const existing = merge ? (store.get(path) ?? {}) : {};
    const next: Record<string, unknown> = { ...existing };
    for (const [k, v] of Object.entries(data)) {
      if (v && typeof v === "object" && "__increment" in (v as Record<string, unknown>)) {
        const prev = typeof next[k] === "number" ? (next[k] as number) : 0;
        next[k] = prev + (v as { __increment: number }).__increment;
      } else {
        next[k] = v;
      }
    }
    store.set(path, next);
  };

  const snapshotFor = (path: string) => {
    const data = store.get(path);
    return {
      exists: data !== undefined,
      id: path.split("/").pop()!,
      ref: makeDocRef(path),
      get: (field: string) => data?.[field],
      data: () => data,
    };
  };

  type Filter = { field: string; op: string; value: unknown };
  const matches = (data: Record<string, unknown>, filters: Filter[]) =>
    filters.every((f) => {
      const v = data[f.field];
      if (f.op === "==") return v === f.value;
      if (f.op === "<=") return typeof v === "number" && typeof f.value === "number" && v <= f.value;
      if (f.op === "in") return Array.isArray(f.value) && (f.value as unknown[]).includes(v);
      return false;
    });

  // A direct sub-collection query: paths exactly one segment under collectionPath.
  const makeQuery = (collectionPath: string, filters: Filter[]) => ({
    __isQuery: true as const,
    collectionPath,
    filters,
    // A CollectionReference also addresses child docs by id.
    doc(id: string) {
      return makeDocRef(`${collectionPath}/${id}`);
    },
    where(field: string, op: string, value: unknown) {
      return makeQuery(collectionPath, [...filters, { field, op, value }]);
    },
    limit(_n: number) {
      return this;
    },
    orderBy(_f: string, _d?: string) {
      return this;
    },
    async get() {
      const docs = [...store.entries()]
        .filter(
          ([path]) =>
            path.startsWith(`${collectionPath}/`) && path.slice(collectionPath.length + 1).indexOf("/") === -1,
        )
        .filter(([, data]) => matches(data, filters))
        .map(([path]) => snapshotFor(path));
      return { empty: docs.length === 0, size: docs.length, docs };
    },
  });

  // Collection-group query: any doc whose parent collection segment === name.
  const makeGroupQuery = (group: string, filters: Filter[]) => ({
    where(field: string, op: string, value: unknown) {
      return makeGroupQuery(group, [...filters, { field, op, value }]);
    },
    orderBy(_f: string, _d?: string) {
      return this;
    },
    limit(_n: number) {
      return this;
    },
    async get() {
      const docs = [...store.entries()]
        .filter(([path]) => {
          const parts = path.split("/");
          // .../<group>/<docId> with docId the last segment.
          return parts.length >= 2 && parts[parts.length - 2] === group;
        })
        .filter(([, data]) => matches(data, filters))
        .map(([path]) => snapshotFor(path));
      return { docs };
    },
  });

  function makeDocRef(path: string) {
    return {
      __isDoc: true as const,
      path,
      async get() {
        return snapshotFor(path);
      },
      async set(data: Record<string, unknown>, opts?: { merge?: boolean }) {
        applyPatch(path, data, opts?.merge === true);
      },
      async create(data: Record<string, unknown>) {
        if (store.has(path)) {
          const err: Error & { code?: number } = new Error("already-exists");
          err.code = 6;
          throw err;
        }
        store.set(path, { ...data });
      },
    };
  }

  const dbMock = {
    doc: (path: string) => makeDocRef(path),
    collection: (path: string) => makeQuery(path, []),
    collectionGroup: (name: string) => makeGroupQuery(name, []),
    async runTransaction<T>(fn: (tx: unknown) => Promise<T>): Promise<T> {
      const tx = {
        async get(refOrQuery: { __isDoc?: true; __isQuery?: true; path?: string } & Record<string, unknown>) {
          if (refOrQuery.__isQuery) {
            return (refOrQuery as unknown as { get: () => unknown }).get();
          }
          return snapshotFor(refOrQuery.path!);
        },
        set(ref: { path: string }, data: Record<string, unknown>, opts?: { merge?: boolean }) {
          applyPatch(ref.path, data, opts?.merge === true);
        },
        create(ref: { path: string }, data: Record<string, unknown>) {
          store.set(ref.path, { ...data });
        },
      };
      return fn(tx);
    },
    batch() {
      const ops: Array<() => void> = [];
      return {
        set(ref: { path: string }, data: Record<string, unknown>, opts?: { merge?: boolean }) {
          ops.push(() => applyPatch(ref.path, data, opts?.merge === true));
        },
        async commit() {
          for (const op of ops) op();
        },
      };
    },
  };

  return { store, dbMock, FieldValueMock, FakeTimestamp };
});

vi.mock("../adminRuntime.js", () => ({ db: dbMock, auth: {} }));
vi.mock("firebase-admin/firestore", () => ({
  FieldValue: FieldValueMock,
  Timestamp: FakeTimestamp,
  getFirestore: () => dbMock,
}));

// Auth / App Check / nonce assertions are exercised elsewhere; stub to no-ops so
// the survivor-eligibility + rotation logic under test is what drives behavior.
vi.mock("../auth.js", () => ({
  assertAuth: vi.fn(),
  assertAppCheck: vi.fn(),
  assertOwnership: vi.fn(),
  enforceAuthAndAppCheck: vi.fn(),
}));
vi.mock("../appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
}));

const { configMock } = vi.hoisted(() => ({ configMock: { enforceAppCheck: true, requireHighRiskNonce: false } }));
vi.mock("../config.js", () => ({ getConfig: () => configMock }));

const { logWarnMock, logInfoMock } = vi.hoisted(() => ({ logWarnMock: vi.fn(), logInfoMock: vi.fn() }));
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: logInfoMock, logWarn: logWarnMock };
});
vi.mock("../scheduledOps.js", () => ({ runScheduledJob: async (_n: string, fn: () => Promise<unknown>) => fn() }));

import {
  listPendingCloudVaultRotationRequirements,
  sweepStalePendingCloudVaultRotations,
} from "../cloudVaultRotationResilience.js";

const UID = "uidRR5";
const HOUR_MS = 60 * 60 * 1000;

function callRequest(uid: string, data: Record<string, unknown>) {
  return { auth: { uid }, app: { appId: "1:1:ios:x" }, data, rawRequest: { headers: {} } } as never;
}

function seedTrustedDevice(deviceId: string, platform = "iOS") {
  store.set(`users/${UID}/escrow_devices/${deviceId}`, { trustState: "trusted", platform, keyVersion: 1 });
}

function seedRequirement(
  id: string,
  overrides: Partial<{
    status: string;
    survivorDeviceIds: string[];
    revokedDeviceId: string;
    currentVaultKeyID: string;
    currentVaultGeneration: number;
    createdAtMillis: number;
    lastNudgedAtMillis: number;
  }> = {},
) {
  store.set(`users/${UID}/cloud_vault_rotation_requirements/${id}`, {
    requirementId: id,
    uid: UID,
    status: overrides.status ?? "pending",
    reason: "device_revoked",
    revokedDeviceId: overrides.revokedDeviceId ?? "phone-revoked",
    currentVaultKeyID: overrides.currentVaultKeyID ?? "v1_" + "a".repeat(32),
    currentVaultGeneration: overrides.currentVaultGeneration ?? 1,
    survivorDeviceIds: overrides.survivorDeviceIds ?? ["mac-survivor", "phone-survivor"],
    rotateCallable: "rotateCloudVaultKey",
    nextRotationReason: "revocation_rewrap",
    createdAtMillis: overrides.createdAtMillis ?? Date.now(),
    ...(overrides.lastNudgedAtMillis !== undefined ? { lastNudgedAtMillis: overrides.lastNudgedAtMillis } : {}),
    schemaVersion: 1,
  });
}

beforeEach(() => {
  store.clear();
  logWarnMock.mockClear();
  logInfoMock.mockClear();
});

describe("listPendingCloudVaultRotationRequirements — survivor eligibility", () => {
  it("returns only requirements where the caller is a listed survivor", async () => {
    seedTrustedDevice("mac-survivor");
    // Eligible: caller is a survivor.
    seedRequirement("req-eligible", { survivorDeviceIds: ["mac-survivor", "phone-survivor"] });
    // Ineligible: caller is NOT a survivor.
    seedRequirement("req-other", { survivorDeviceIds: ["ipad-other"] });
    // Already queued — not pending, must be excluded.
    seedRequirement("req-queued", { status: "queued", survivorDeviceIds: ["mac-survivor"] });

    const result = (await listPendingCloudVaultRotationRequirements.run(
      callRequest(UID, { callerDeviceId: "mac-survivor" }),
    )) as { ok: boolean; requirements: Array<{ requirementId: string }> };

    expect(result.ok).toBe(true);
    expect(result.requirements.map((r) => r.requirementId)).toEqual(["req-eligible"]);
  });

  it("rejects a caller whose device is not trusted", async () => {
    seedRequirement("req-eligible", { survivorDeviceIds: ["mac-survivor"] });
    // No trusted escrow device seeded for the caller.
    await expect(
      listPendingCloudVaultRotationRequirements.run(callRequest(UID, { callerDeviceId: "mac-survivor" })),
    ).rejects.toThrow(/trusted escrow device/i);
  });
});

describe("sweepStalePendingCloudVaultRotations — stale detection + nudge", () => {
  it("flags a requirement stale past the grace window and nudges surviving devices", async () => {
    const now = Date.now();
    seedRequirement("req-stale", {
      createdAtMillis: now - 2 * HOUR_MS, // older than the 1h grace window
      survivorDeviceIds: ["mac-survivor", "phone-survivor"],
    });
    store.set(`users/${UID}/devices/mac-survivor`, { fcmToken: "tok-mac", platform: "macOS" });
    store.set(`users/${UID}/devices/phone-survivor`, { fcm_token: "tok-phone", platform: "iOS" });

    const tally = await sweepStalePendingCloudVaultRotations({ now });

    expect(tally.flagged).toBe(1);
    expect(tally.nudged).toBe(1);
    // Structured warning metric emitted for ops visibility.
    expect(logWarnMock).toHaveBeenCalledWith(
      expect.objectContaining({ event: "cloud_vault.rotation_pending_stale", requirement_id: "req-stale" }),
    );
    // One silent fcm_outbound data push per survivor that has a token.
    const outbound = [...store.entries()].filter(([p]) => p.startsWith("fcm_outbound/"));
    expect(outbound).toHaveLength(2);
    for (const [, doc] of outbound) {
      expect(doc.status).toBe("pending");
      expect((doc.payload as Record<string, unknown>).type).toBe("cloud_vault_rotation_required");
      expect(doc.fcmToken === "tok-mac" || doc.fcmToken === "tok-phone").toBe(true);
    }
    // Requirement stamped with the nudge bookkeeping.
    expect(store.get(`users/${UID}/cloud_vault_rotation_requirements/req-stale`)?.nudgeAttemptCount).toBe(1);
  });

  it("does NOT flag a fresh requirement still inside the grace window", async () => {
    const now = Date.now();
    seedRequirement("req-fresh", { createdAtMillis: now - 5 * 60_000 }); // 5 minutes old
    store.set(`users/${UID}/devices/mac-survivor`, { fcmToken: "tok-mac" });

    const tally = await sweepStalePendingCloudVaultRotations({ now });

    expect(tally.flagged).toBe(0);
    expect([...store.keys()].some((p) => p.startsWith("fcm_outbound/"))).toBe(false);
  });

  it("flags but skips re-nudging a requirement nudged within the throttle window", async () => {
    const now = Date.now();
    seedRequirement("req-recent-nudge", {
      createdAtMillis: now - 3 * HOUR_MS,
      lastNudgedAtMillis: now - 10 * 60_000, // nudged 10 min ago, inside throttle
    });
    store.set(`users/${UID}/devices/mac-survivor`, { fcmToken: "tok-mac" });

    const tally = await sweepStalePendingCloudVaultRotations({ now });

    expect(tally.flagged).toBe(1);
    expect(tally.nudged).toBe(0);
    expect([...store.keys()].some((p) => p.startsWith("fcm_outbound/"))).toBe(false);
  });
});
