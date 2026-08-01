/**
 * M-037 follow-up — phone-control authority must bind each controller to the
 * pairing through an explicit self-registration, never by materializing the
 * whole account's trusted-phone set.
 *
 * Before this fix, `publishIrohPairingRecord` (Mac-published) materialized
 * `authorizedControllerDeviceIds` as EVERY trusted phone-platform escrow device,
 * so any trusted phone B could call `publishPhoneControlAuthority` and register
 * itself as a controller without participating in the controller-key proof
 * flow. The pairing is the Mac's shared connection root, so multiple trusted
 * phones may now independently append themselves only when each publishes its
 * own derived authority key. One phone cannot replace another phone's binding,
 * and revocation removes only the revoked phone.
 *
 * These tests drive the REAL `publishIrohPairingRecord`, `publishPhoneControlAuthority`,
 * and `revokeEscrowDeviceTrust` handlers through `.run(request)` against an
 * in-memory Firestore double, proving:
 *   - a fresh Mac publish does NOT authorize any phone (empty allowlist);
 *   - a Mac heartbeat re-publish PRESERVES every explicitly registered binding;
 *   - each trusted phone appends itself without replacing existing controllers;
 *   - a phone cannot reuse an authority peer already bound to another device;
 *   - each phone can refresh its own authority;
 *   - revoking phone A scrubs only A while phone B remains authorized.
 */

import { describe, expect, it, beforeEach, vi } from "vitest";
import { randomBytes } from "node:crypto";

const { store, dbMock, FieldValueMock, FakeTimestamp } = vi.hoisted(() => {
  const store = new Map<string, Record<string, unknown>>();

  class FakeTimestamp {
    constructor(public readonly ms: number) {}
    static now(): FakeTimestamp {
      return new FakeTimestamp(1_700_000_000_000);
    }
    static fromMillis(ms: number): FakeTimestamp {
      return new FakeTimestamp(ms);
    }
    toMillis(): number {
      return this.ms;
    }
  }
  const FieldValueMock = { serverTimestamp: () => ({ __serverTimestamp: true }) };

  const snapshotFor = (path: string) => {
    const data = store.get(path);
    return {
      exists: data !== undefined,
      get: (f: string) => data?.[f],
      data: () => data,
      ref: makeDocRef(path),
      id: path.split("/").pop() ?? path,
    };
  };

  type Filter = { field: string; op: string; value: unknown };
  const directChildren = (collectionPath: string) =>
    [...store.entries()].filter(
      ([path]) => path.startsWith(`${collectionPath}/`) && path.slice(collectionPath.length + 1).indexOf("/") === -1,
    );

  const makeQuery = (collectionPath: string, filters: Filter[]) => ({
    __isQuery: true as const,
    collectionPath,
    filters,
    where(field: string, op: string, value: unknown) {
      return makeQuery(collectionPath, [...filters, { field, op, value }]);
    },
    async get() {
      const docs = directChildren(collectionPath)
        .filter(([, data]) => filters.every((f) => (f.op === "==" ? data[f.field] === f.value : true)))
        .map(([path]) => snapshotFor(path));
      return { empty: docs.length === 0, size: docs.length, docs };
    },
    async add(data: Record<string, unknown>) {
      const id = `auto_${randomBytes(8).toString("hex")}`;
      store.set(`${collectionPath}/${id}`, { ...data });
      return { id };
    },
  });

  const makeDocRef = (path: string): Record<string, unknown> => ({
    __isDoc: true as const,
    path,
    async get() {
      return snapshotFor(path);
    },
    async set(data: Record<string, unknown>, opts?: { merge?: boolean }) {
      const existing = opts?.merge ? (store.get(path) ?? {}) : {};
      store.set(path, { ...existing, ...data });
    },
    async delete() {
      store.delete(path);
    },
    collection(name: string) {
      return makeQuery(`${path}/${name}`, []);
    },
  });

  const dbMock = {
    doc: (path: string) => makeDocRef(path),
    collection: (path: string) => makeQuery(path, []),
    async runTransaction<T>(fn: (transaction: unknown) => Promise<T>): Promise<T> {
      const writes: Array<() => void> = [];
      const transaction = {
        async get(refOrQuery: { path?: string; __isQuery?: boolean; get?: () => Promise<unknown> }) {
          if (refOrQuery.__isQuery && refOrQuery.get) {
            return refOrQuery.get();
          }
          return snapshotFor(refOrQuery.path ?? "");
        },
        set(ref: { path: string }, data: Record<string, unknown>, opts?: { merge?: boolean }) {
          writes.push(() => {
            const existing = opts?.merge ? (store.get(ref.path) ?? {}) : {};
            store.set(ref.path, { ...existing, ...data });
          });
          return transaction;
        },
        delete(ref: { path: string }) {
          writes.push(() => store.delete(ref.path));
          return transaction;
        },
      };
      const result = await fn(transaction);
      writes.forEach((write) => write());
      return result;
    },
    batch() {
      const ops: Array<() => void> = [];
      return {
        set(ref: { path: string }, data: Record<string, unknown>, opts?: { merge?: boolean }) {
          ops.push(() => {
            const existing = opts?.merge ? (store.get(ref.path) ?? {}) : {};
            store.set(ref.path, { ...existing, ...data });
          });
        },
        delete(ref: { path: string }) {
          ops.push(() => store.delete(ref.path));
        },
        async commit() {
          ops.forEach((op) => op());
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
const { configMock } = vi.hoisted(() => ({ configMock: { enforceAppCheck: true, requireHighRiskNonce: false } }));
vi.mock("../config.js", () => ({ getConfig: () => configMock }));
vi.mock("../callables/shared/entitlements.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared/entitlements.js")>(
    "../callables/shared/entitlements.js",
  );
  return {
    ...actual,
    assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined),
  };
});
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: vi.fn(), logWarn: vi.fn() };
});
vi.mock("../signalDirectoryRuntime.js", () => ({ revokeSignalSessionsForDevice: vi.fn(async () => 0) }));

import {
  issuePhoneControlEnrollmentGrant,
  publishIrohPairingRecord,
  publishPhoneControlAuthority,
  revokeEscrowDeviceTrust,
} from "../callables/computerUseSecurity.js";
import { APP_CHECK_ATTESTATION_CLAIM_KEY, appCheckAttestationDigestHex } from "../appCheckAttestation.js";

const APP_ID = "1:123:ios:abc";
const APP_CHECK_BOUND_AT_MILLIS = Date.now();
const UID = "uidM037";
const CONN = "conn-1";
const MAC = "mac-1";

function req(data: Record<string, unknown>) {
  return {
    auth: {
      uid: UID,
      token: { [APP_CHECK_ATTESTATION_CLAIM_KEY]: { v: 1, appId: APP_ID, boundAtMillis: APP_CHECK_BOUND_AT_MILLIS } },
    },
    app: { appId: APP_ID },
    data,
    rawRequest: { headers: {} },
  };
}

function invokeCallable<TRes = unknown>(callable: unknown, data: Record<string, unknown>): Promise<TRes> {
  const run = callable && (typeof callable === "object" || typeof callable === "function") ? Reflect.get(callable, "run") : undefined;
  if (typeof run !== "function") {
    throw new Error("callable test target is missing run()");
  }
  return run.call(callable, req(data));
}

function ed25519Key(): { base64: string; peerNodeId: string } {
  const bytes = randomBytes(32);
  return { base64: bytes.toString("base64"), peerNodeId: `ios-phone-${bytes.subarray(0, 12).toString("hex")}` };
}

function publishMacPairing(deviceId = MAC) {
  return invokeCallable(publishIrohPairingRecord, {
    deviceId,
    connectionId: CONN,
    nodeId: "node-1",
    directAddresses: [],
    publishedAtMillis: Date.now(),
    protocolVersion: 1,
    signature: Buffer.alloc(64, 0x42).toString("base64"),
  });
}

function publishPhoneAuthority(deviceId: string, key: { base64: string; peerNodeId: string }) {
  return invokeCallable<{ ok: boolean }>(publishPhoneControlAuthority, {
    deviceId,
    connectionId: CONN,
    peerNodeId: key.peerNodeId,
    publicKeyBase64: key.base64,
    publishedAtMillis: Date.now(),
  });
}

function issuePhoneEnrollmentGrant(
  controllerDeviceId: string,
  key: { peerNodeId: string },
  hostDeviceId = MAC,
) {
  return invokeCallable<{ ok: boolean; grantNonce: string; expiresAtMillis: number }>(
    issuePhoneControlEnrollmentGrant,
    {
      hostDeviceId,
      connectionId: CONN,
      controllerDeviceId,
      controllerPeerNodeId: key.peerNodeId,
    },
  );
}

describe("M-037 phone-control authority binds each trusted controller independently", () => {
  beforeEach(() => {
    store.clear();
    store.set(`users/${UID}/escrow_devices/${MAC}`, { platform: "macOS", trustState: "trusted", keyVersion: 1 });
    store.set(`users/${UID}/escrow_devices/phone-a`, { platform: "iOS", trustState: "trusted", keyVersion: 1 });
    store.set(`users/${UID}/escrow_devices/phone-b`, { platform: "Android", trustState: "trusted", keyVersion: 1 });
  });

  it("a fresh Mac publish authorizes NO phone (empty allowlist)", async () => {
    await publishMacPairing();
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual([]);
  });

  it("a Mac heartbeat re-publish preserves every explicitly registered controller", async () => {
    await publishMacPairing();
    const keyA = ed25519Key();
    const keyB = ed25519Key();
    await issuePhoneEnrollmentGrant("phone-a", keyA);
    await publishPhoneAuthority("phone-a", keyA);
    await issuePhoneEnrollmentGrant("phone-b", keyB);
    await publishPhoneAuthority("phone-b", keyB);
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual([
      "phone-a",
      "phone-b",
    ]);

    // Mac republishes (boot/heartbeat). Explicit bindings survive, but the host
    // still never auto-materializes unrelated trusted devices.
    await publishMacPairing();
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual([
      "phone-a",
      "phone-b",
    ]);
  });

  it("a new phone requires a fresh grant from the Mac that owns the pairing", async () => {
    await publishMacPairing();
    const key = ed25519Key();
    await expect(publishPhoneAuthority("phone-a", key)).rejects.toThrow(/fresh approval from this Mac/i);

    const grant = await issuePhoneEnrollmentGrant("phone-a", key);
    expect(grant.ok).toBe(true);
    expect(grant.grantNonce).toEqual(expect.any(String));
    expect(grant.expiresAtMillis).toBeGreaterThan(Date.now());
    const res = await publishPhoneAuthority("phone-a", key);

    expect(res.ok).toBe(true);
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual(["phone-a"]);
    const controller = store.get(`users/${UID}/iroh_pairing/${CONN}/controllers/${key.peerNodeId}`);
    expect(controller?.deviceId).toBe("phone-a");
    expect(controller?.appCheckAttestationHashBlake3).toBe(
      appCheckAttestationDigestHex(APP_ID, APP_CHECK_BOUND_AT_MILLIS),
    );
    expect(
      store.get(`users/${UID}/iroh_pairing/${CONN}/controller_enrollment_grants/phone-a`)?.status,
    ).toBe("consumed");
  });

  it("a different trusted Mac cannot issue a controller grant for another host's pairing", async () => {
    store.set(`users/${UID}/escrow_devices/mac-2`, {
      platform: "macOS",
      trustState: "trusted",
      keyVersion: 1,
    });
    await publishMacPairing();

    await expect(issuePhoneEnrollmentGrant("phone-a", ed25519Key(), "mac-2")).rejects.toThrow(
      /trusted host that published this iroh pairing/i,
    );
  });

  it("an expired enrollment grant cannot authorize a new phone", async () => {
    await publishMacPairing();
    const key = ed25519Key();
    await issuePhoneEnrollmentGrant("phone-a", key);
    const grantPath = `users/${UID}/iroh_pairing/${CONN}/controller_enrollment_grants/phone-a`;
    store.set(grantPath, {
      ...store.get(grantPath),
      expiresAtMillis: Date.now() - 1,
    });

    await expect(publishPhoneAuthority("phone-a", key)).rejects.toThrow(/fresh approval from this Mac/i);

    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual([]);
    expect(store.has(`users/${UID}/iroh_pairing/${CONN}/controllers/${key.peerNodeId}`)).toBe(false);
    expect(store.get(grantPath)?.status).toBe("pending");
  });

  it("a second trusted phone appends itself without replacing phone A", async () => {
    await publishMacPairing();
    const keyA = ed25519Key();
    await issuePhoneEnrollmentGrant("phone-a", keyA);
    await publishPhoneAuthority("phone-a", keyA);

    const keyB = ed25519Key();
    await issuePhoneEnrollmentGrant("phone-b", keyB);
    await expect(publishPhoneAuthority("phone-b", keyB)).resolves.toMatchObject({ ok: true });

    expect(store.get(`users/${UID}/iroh_pairing/${CONN}/controllers/${keyA.peerNodeId}`)?.deviceId).toBe("phone-a");
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}/controllers/${keyB.peerNodeId}`)?.deviceId).toBe("phone-b");
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual([
      "phone-a",
      "phone-b",
    ]);
  });

  it("rejects rebinding another device's authority peer", async () => {
    await publishMacPairing();
    const keyA = ed25519Key();
    await issuePhoneEnrollmentGrant("phone-a", keyA);
    await publishPhoneAuthority("phone-a", keyA);

    await issuePhoneEnrollmentGrant("phone-b", keyA);
    await expect(publishPhoneAuthority("phone-b", keyA)).rejects.toThrow(/already bound/i);
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}/controllers/${keyA.peerNodeId}`)?.deviceId).toBe("phone-a");
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual(["phone-a"]);
  });

  it("phone A can refresh its own authority without dropping phone B", async () => {
    await publishMacPairing();
    const originalKeyA = ed25519Key();
    const keyB = ed25519Key();
    await issuePhoneEnrollmentGrant("phone-a", originalKeyA);
    await publishPhoneAuthority("phone-a", originalKeyA);
    await issuePhoneEnrollmentGrant("phone-b", keyB);
    await publishPhoneAuthority("phone-b", keyB);

    await expect(publishPhoneAuthority("phone-a", originalKeyA)).resolves.toMatchObject({ ok: true });

    const rotatedKey = ed25519Key();
    const consumedGrantPath = `users/${UID}/iroh_pairing/${CONN}/controller_enrollment_grants/phone-a`;
    expect(store.get(consumedGrantPath)?.status).toBe("consumed");
    await expect(publishPhoneAuthority("phone-a", rotatedKey)).rejects.toThrow(/fresh approval from this Mac/i);
    expect(store.get(consumedGrantPath)?.status).toBe("consumed");
    expect(store.has(`users/${UID}/iroh_pairing/${CONN}/controllers/${rotatedKey.peerNodeId}`)).toBe(false);
    await issuePhoneEnrollmentGrant("phone-a", rotatedKey);
    const res = await publishPhoneAuthority("phone-a", rotatedKey);

    expect(res.ok).toBe(true);
    expect(store.has(`users/${UID}/iroh_pairing/${CONN}/controllers/${rotatedKey.peerNodeId}`)).toBe(true);
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual([
      "phone-a",
      "phone-b",
    ]);
  });

  it("revoking phone A removes only A while phone B remains authorized", async () => {
    await publishMacPairing();
    const keyA = ed25519Key();
    const keyB = ed25519Key();
    await issuePhoneEnrollmentGrant("phone-a", keyA);
    await publishPhoneAuthority("phone-a", keyA);
    await issuePhoneEnrollmentGrant("phone-b", keyB);
    await publishPhoneAuthority("phone-b", keyB);

    await invokeCallable(revokeEscrowDeviceTrust, { deviceId: "phone-a" });

    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual(["phone-b"]);
    expect(store.has(`users/${UID}/iroh_pairing/${CONN}/controllers/${keyA.peerNodeId}`)).toBe(false);
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}/controllers/${keyB.peerNodeId}`)?.deviceId).toBe("phone-b");

    await expect(publishPhoneAuthority("phone-b", keyB)).resolves.toMatchObject({ ok: true });
  });
});
