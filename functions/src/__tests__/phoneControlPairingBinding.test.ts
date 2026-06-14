/**
 * M-037 — phone-control authority must bind to the pairing's OWN phone, never
 * the whole account's trusted-phone set.
 *
 * Before this fix, `publishIrohPairingRecord` (Mac-published) materialized
 * `authorizedControllerDeviceIds` as EVERY trusted phone-platform escrow device,
 * so any trusted phone B could call `publishPhoneControlAuthority` and register
 * itself as a controller for a pairing that phone A owns — hijacking control of
 * phone A's Mac. The pairing is the Mac's connection root and carries no
 * inherent phone identity, so the controller binding is now established on first
 * claim by the phone that actually dials the pairing, and only that phone may
 * publish/refresh it afterward.
 *
 * These tests drive the REAL `publishIrohPairingRecord`, `publishPhoneControlAuthority`,
 * and `revokeEscrowDeviceTrust` handlers through `.run(request)` against an
 * in-memory Firestore double, proving:
 *   - a fresh Mac publish does NOT authorize any phone (empty allowlist);
 *   - a Mac heartbeat re-publish PRESERVES an already-claimed binding;
 *   - the first phone to publish claims the pairing as its sole controller;
 *   - a different trusted phone B is REJECTED and writes no controller record;
 *   - the claiming phone A can refresh its own authority on its pairing;
 *   - revoking phone A scrubs it from the allowlist so the pairing is re-claimable.
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
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: vi.fn(), logWarn: vi.fn() };
});
vi.mock("../signalDirectoryRuntime.js", () => ({ revokeSignalSessionsForDevice: vi.fn(async () => 0) }));

import {
  publishIrohPairingRecord,
  publishPhoneControlAuthority,
  revokeEscrowDeviceTrust,
} from "../callables/computerUseSecurity.js";
import { APP_CHECK_ATTESTATION_CLAIM_KEY } from "../appCheckAttestation.js";

const APP_ID = "1:123:ios:abc";
const UID = "uidM037";
const CONN = "conn-1";
const MAC = "mac-1";

function req(data: Record<string, unknown>) {
  return {
    auth: {
      uid: UID,
      token: { [APP_CHECK_ATTESTATION_CLAIM_KEY]: { v: 1, appId: APP_ID, boundAtMillis: Date.now() } },
    },
    app: { appId: APP_ID },
    data,
    rawRequest: { headers: {} },
  };
}

function invokeCallable<TRes = unknown>(callable: unknown, data: Record<string, unknown>): Promise<TRes> {
  const runnable = callable as { run: (request: unknown) => Promise<TRes> };
  return runnable.run(req(data));
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

describe("M-037 phone-control authority binds to the pairing's own phone", () => {
  beforeEach(() => {
    store.clear();
    store.set(`users/${UID}/escrow_devices/${MAC}`, { platform: "macOS", trustState: "trusted", keyVersion: 1 });
    store.set(`users/${UID}/escrow_devices/phone-a`, { platform: "iOS", trustState: "trusted", keyVersion: 1 });
    store.set(`users/${UID}/escrow_devices/phone-b`, { platform: "iOS", trustState: "trusted", keyVersion: 1 });
  });

  it("a fresh Mac publish authorizes NO phone (empty allowlist)", async () => {
    await publishMacPairing();
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual([]);
  });

  it("a Mac heartbeat re-publish preserves an already-claimed binding, never widening it", async () => {
    await publishMacPairing();
    await publishPhoneAuthority("phone-a", ed25519Key()); // phone A claims it
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual(["phone-a"]);

    // Mac republishes (boot/heartbeat). The binding must survive and NOT grow to
    // include phone B even though phone B is also a trusted phone.
    await publishMacPairing();
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual(["phone-a"]);
  });

  it("the first phone to publish claims the pairing as its sole controller", async () => {
    await publishMacPairing();
    const key = ed25519Key();
    const res = await publishPhoneAuthority("phone-a", key);

    expect(res.ok).toBe(true);
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual(["phone-a"]);
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}/controllers/${key.peerNodeId}`)?.deviceId).toBe("phone-a");
  });

  it("trusted phone B CANNOT publish controller authority for phone A's pairing", async () => {
    await publishMacPairing();
    await publishPhoneAuthority("phone-a", ed25519Key()); // phone A claims it first

    const keyB = ed25519Key();
    await expect(publishPhoneAuthority("phone-b", keyB)).rejects.toThrow(/not authorized/i);

    // Phone B wrote no controller record and was not appended to the allowlist.
    expect(store.has(`users/${UID}/iroh_pairing/${CONN}/controllers/${keyB.peerNodeId}`)).toBe(false);
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual(["phone-a"]);
  });

  it("the claiming phone A can still refresh its own authority (legit same-pairing flow)", async () => {
    await publishMacPairing();
    await publishPhoneAuthority("phone-a", ed25519Key());

    const rotatedKey = ed25519Key();
    const res = await publishPhoneAuthority("phone-a", rotatedKey);

    expect(res.ok).toBe(true);
    expect(store.has(`users/${UID}/iroh_pairing/${CONN}/controllers/${rotatedKey.peerNodeId}`)).toBe(true);
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual(["phone-a"]);
  });

  it("revoking the claiming phone scrubs it from the allowlist so the pairing is re-claimable", async () => {
    await publishMacPairing();
    await publishPhoneAuthority("phone-a", ed25519Key());
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual(["phone-a"]);

    await invokeCallable(revokeEscrowDeviceTrust, { deviceId: "phone-a" });

    // Allowlist is cleared, freeing the pairing for a replacement phone.
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual([]);

    // A replacement phone B can now claim the freed pairing.
    const keyB = ed25519Key();
    const res = await publishPhoneAuthority("phone-b", keyB);
    expect(res.ok).toBe(true);
    expect(store.get(`users/${UID}/iroh_pairing/${CONN}`)?.authorizedControllerDeviceIds).toEqual(["phone-b"]);
  });
});
