/**
 * RR-5 — `rotateCloudVaultKey` must accept rewrap completion by ANY surviving
 * trusted device, not only the device that initiated the revocation.
 *
 * The revoke writer records `survivorDeviceIds` + a pending requirement; the
 * rotation gate is "the caller is a trusted device that includes its own
 * survivor wrapper, and the requested survivor set matches the requirement".
 * Crucially it must NOT gate on the caller being the revoking device — that is
 * exactly the lock-up RR-5 fixes (revoke from Android / offline revoker leaves
 * the requirement pending forever). This proves a NON-revoker survivor drives
 * the rotation to `queued` against the revocation requirement.
 */

import { describe, expect, it, beforeEach, vi } from "vitest";
import type { CallableRequest } from "firebase-functions/v2/https";

const { store, dbMock, FieldValueMock, FakeTimestamp } = vi.hoisted(() => {
  const store = new Map<string, Record<string, unknown>>();

  class FakeTimestamp {
    constructor(public readonly ms: number) {}
    static now(): FakeTimestamp {
      return new FakeTimestamp(Date.now());
    }
    static serverTimestamp(): unknown {
      return { __serverTimestamp: true };
    }
    toMillis(): number {
      return this.ms;
    }
  }
  const FieldValueMock = { serverTimestamp: () => ({ __serverTimestamp: true }) };

  const applyPatch = (path: string, data: Record<string, unknown>, merge: boolean) => {
    const existing = merge ? (store.get(path) ?? {}) : {};
    store.set(path, { ...existing, ...data });
  };

  const snapshotFor = (path: string) => {
    const data = store.get(path);
    return {
      exists: data !== undefined,
      id: path.split("/").pop() ?? "",
      ref: makeDocRef(path),
      get: (field: string) => data?.[field],
      data: () => data,
    };
  };

  type Filter = { field: string; op: string; value: unknown };
  const makeQuery = (collectionPath: string, filters: Filter[]) => ({
    __isQuery: true as const,
    collectionPath,
    filters,
    where(field: string, op: string, value: unknown) {
      return makeQuery(collectionPath, [...filters, { field, op, value }]);
    },
    async get() {
      const docs = [...store.entries()]
        .filter(
          ([path]) =>
            path.startsWith(`${collectionPath}/`) && path.slice(collectionPath.length + 1).indexOf("/") === -1,
        )
        .filter(([, data]) => filters.every((f) => (f.op === "==" ? data[f.field] === f.value : false)))
        .map(([path]) => snapshotFor(path));
      return { empty: docs.length === 0, size: docs.length, docs };
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
    };
  }

  const dbMock = {
    doc: (path: string) => makeDocRef(path),
    collection: (path: string) => makeQuery(path, []),
    async runTransaction<T>(fn: (tx: unknown) => Promise<T>): Promise<T> {
      const tx = {
        async get(refOrQuery: { __isDoc?: true; __isQuery?: true; path?: string; get(): Promise<unknown> }) {
          if (refOrQuery.__isQuery) return refOrQuery.get();
          if (!refOrQuery.path) throw new Error("transaction get requires a document path");
          return snapshotFor(refOrQuery.path);
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
vi.mock("firebase-admin/firestore", () => ({ FieldValue: FieldValueMock, Timestamp: FakeTimestamp }));
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
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: vi.fn(), logWarn: vi.fn() };
});

import { rotateCloudVaultKey } from "../callables/cloudVaultRotation.js";

const UID = "uidRotate";
const CURRENT_KEY = "v1_" + "a".repeat(32);
const NEW_KEY = "v1_" + "b".repeat(32);
const REVOKER = "phone-revoker";
const SURVIVOR_A = "mac-survivor";
const SURVIVOR_B = "phone-survivor";

function callRequest<T extends Record<string, unknown>>(uid: string, data: T): CallableRequest<T> {
  return {
    auth: { uid, token: Object.create(null), rawToken: "test-token" },
    app: { appId: "1:1:ios:x", token: Object.create(null) },
    data,
    rawRequest: Object.assign(Object.create(null), { headers: {} }),
    acceptsStreaming: false,
  };
}

function seedTrusted(deviceId: string) {
  store.set(`users/${UID}/escrow_devices/${deviceId}`, { trustState: "trusted", platform: "iOS", keyVersion: 1 });
}

function survivorWrapper(targetDeviceId: string, sourceDeviceId: string) {
  return {
    targetDeviceId,
    sourceDeviceId,
    publicKeyFingerprint: "fpr-" + targetDeviceId,
    keyVersion: 1,
    wrappedVaultKey: Buffer.from(`wrapped-for-${targetDeviceId}`).toString("base64"),
  };
}

beforeEach(() => {
  store.clear();
});

describe("rotateCloudVaultKey — accepts a non-revoker survivor", () => {
  it("a surviving device that did NOT initiate the revoke can complete the rewrap", async () => {
    // Two trusted survivors remain; the revoking device is gone.
    seedTrusted(SURVIVOR_A);
    seedTrusted(SURVIVOR_B);
    store.set(`users/${UID}/cloud_vault_state/current`, {
      uid: UID,
      vaultKeyID: CURRENT_KEY,
      vaultGeneration: 1,
      status: "active",
    });
    const requirementId = "revoke_req_1";
    store.set(`users/${UID}/cloud_vault_rotation_requirements/${requirementId}`, {
      requirementId,
      uid: UID,
      status: "pending",
      reason: "device_revoked",
      revokedDeviceId: REVOKER,
      currentVaultKeyID: CURRENT_KEY,
      currentVaultGeneration: 1,
      // Sorted survivor set, exactly as the revoke writer records it.
      survivorDeviceIds: [SURVIVOR_A, SURVIVOR_B].sort(),
      rotateCallable: "rotateCloudVaultKey",
      nextRotationReason: "revocation_rewrap",
      schemaVersion: 1,
    });

    // SURVIVOR_B (NOT the revoker) drives the rotation, wrapping the next key to
    // both surviving devices and including its own wrapper.
    const result = (await rotateCloudVaultKey.run(
      callRequest(UID, {
        callerDeviceId: SURVIVOR_B,
        currentVaultKeyID: CURRENT_KEY,
        newVaultKeyID: NEW_KEY,
        expectedVaultGeneration: 2,
        reason: "revocation_rewrap",
        rotationRequirementId: requirementId,
        survivorWrappers: [survivorWrapper(SURVIVOR_A, SURVIVOR_B), survivorWrapper(SURVIVOR_B, SURVIVOR_B)],
      }),
    )) as { ok: boolean; status: string; vaultGeneration: number };

    expect(result).toMatchObject({ ok: true, status: "queued", vaultGeneration: 2 });
    // State advanced to the new key, rotated by the non-revoker survivor.
    const state = store.get(`users/${UID}/cloud_vault_state/current`);
    expect(state?.vaultKeyID).toBe(NEW_KEY);
    expect(state?.vaultGeneration).toBe(2);
    expect(state?.rotatedByDeviceId).toBe(SURVIVOR_B);
    // The revocation requirement is no longer pending.
    expect(store.get(`users/${UID}/cloud_vault_rotation_requirements/${requirementId}`)?.status).toBe("queued");
  });
});
