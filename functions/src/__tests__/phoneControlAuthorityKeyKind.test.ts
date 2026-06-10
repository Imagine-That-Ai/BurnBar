/**
 * F2 — hardware-bind the phone-control signing key (server side).
 *
 * Drives the REAL `publishPhoneControlAuthority` and `revokeEscrowDeviceTrust`
 * handlers through `.run(request)` against an in-memory Firestore double, proving:
 *  - a legacy Ed25519 controller publishes unchanged (peerNodeId derived from the
 *    32-byte raw key, schemaVersion 2, signingKeyKind "ed25519");
 *  - a Secure-Enclave P-256 controller publishes when keyKind="se-p256" with a
 *    valid x9.63 key whose peerNodeId derives from sha256(x963) (schemaVersion 3);
 *  - a peerNodeId that does not match the published key is rejected;
 *  - revoke atomically deletes the device's controller record + agent-grant
 *    authority and emits a revocation receipt audit event + receiptId.
 */

import { describe, expect, it, beforeEach, vi } from "vitest";
import { createECDH, createHash, randomBytes } from "node:crypto";

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
    return { exists: data !== undefined, get: (f: string) => data?.[f], data: () => data, ref: makeDocRef(path), id: path.split("/").pop()! };
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
      const existing = opts?.merge ? store.get(path) ?? {} : {};
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
    batch() {
      const ops: Array<() => void> = [];
      return {
        set: (ref: { path: string }, data: Record<string, unknown>) =>
          ops.push(() => store.set(ref.path, { ...(store.get(ref.path) ?? {}), ...data })),
        delete: (ref: { path: string }) => ops.push(() => store.delete(ref.path)),
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
// Signal session cleanup is exercised elsewhere; stub to isolate the F2 paths.
vi.mock("../signalDirectoryRuntime.js", () => ({ revokeSignalSessionsForDevice: vi.fn(async () => 0) }));

import { publishPhoneControlAuthority, publishAgentGrantAuthority, revokeEscrowDeviceTrust } from "../callables/computerUseSecurity.js";
import { APP_CHECK_ATTESTATION_CLAIM_KEY } from "../appCheckAttestation.js";

const APP_ID = "1:123:ios:abc";
const UID = "uidF2";
const DEVICE = "phone-1";
const CONN = "conn-1";

function req(data: Record<string, unknown>) {
  return {
    auth: { uid: UID, token: { [APP_CHECK_ATTESTATION_CLAIM_KEY]: { v: 1, appId: APP_ID, boundAtMillis: Date.now() } } },
    app: { appId: APP_ID },
    data,
    rawRequest: { headers: {} },
  } as never;
}

function seedTrustedDeviceAndPairing() {
  store.clear();
  store.set(`users/${UID}/escrow_devices/${DEVICE}`, { platform: "iOS", trustState: "trusted", keyVersion: 1 });
  store.set(`users/${UID}/iroh_pairing/${CONN}`, { id: CONN });
}

function ed25519Key(): { base64: string; peerNodeId: string } {
  const bytes = randomBytes(32);
  return { base64: bytes.toString("base64"), peerNodeId: `ios-phone-${bytes.subarray(0, 12).toString("hex")}` };
}

function seP256Key(): { base64: string; peerNodeId: string } {
  const ecdh = createECDH("prime256v1");
  ecdh.generateKeys();
  const x963 = ecdh.getPublicKey(); // 0x04 || X || Y, on-curve
  const digest = createHash("sha256").update(x963).digest("hex").slice(0, 24);
  return { base64: x963.toString("base64"), peerNodeId: `ios-se-${digest}` };
}

describe("F2 publishPhoneControlAuthority keyKind", () => {
  beforeEach(seedTrustedDeviceAndPairing);

  it("publishes a legacy Ed25519 controller unchanged", async () => {
    const key = ed25519Key();
    const res = await (publishPhoneControlAuthority as never as { run: (r: never) => Promise<{ ok: boolean; peerNodeId: string }> }).run(
      req({ deviceId: DEVICE, connectionId: CONN, peerNodeId: key.peerNodeId, publicKeyBase64: key.base64, publishedAtMillis: Date.now() }),
    );
    expect(res.ok).toBe(true);
    const rec = store.get(`users/${UID}/iroh_pairing/${CONN}/controllers/${key.peerNodeId}`);
    expect(rec?.signingKeyKind).toBe("ed25519");
    expect(rec?.schemaVersion).toBe(2);
    expect(rec?.publicKeyBase64).toBe(key.base64);
  });

  it("publishes a Secure-Enclave P-256 controller", async () => {
    const key = seP256Key();
    const res = await (publishPhoneControlAuthority as never as { run: (r: never) => Promise<{ ok: boolean }> }).run(
      req({ deviceId: DEVICE, connectionId: CONN, peerNodeId: key.peerNodeId, publicKeyBase64: key.base64, keyKind: "se-p256", publishedAtMillis: Date.now() }),
    );
    expect(res.ok).toBe(true);
    const rec = store.get(`users/${UID}/iroh_pairing/${CONN}/controllers/${key.peerNodeId}`);
    expect(rec?.signingKeyKind).toBe("se-p256");
    expect(rec?.schemaVersion).toBe(3);
  });

  it("rejects a peerNodeId that does not match the published key", async () => {
    const key = seP256Key();
    await expect(
      (publishPhoneControlAuthority as never as { run: (r: never) => Promise<unknown> }).run(
        req({ deviceId: DEVICE, connectionId: CONN, peerNodeId: "ios-se-deadbeefdeadbeefdeadbeef", publicKeyBase64: key.base64, keyKind: "se-p256", publishedAtMillis: Date.now() }),
      ),
    ).rejects.toThrow(/peerNodeId does not match/);
  });

  it("rejects an se-p256 publish carrying an Ed25519-length key", async () => {
    const bytes = randomBytes(32);
    await expect(
      (publishPhoneControlAuthority as never as { run: (r: never) => Promise<unknown> }).run(
        req({ deviceId: DEVICE, connectionId: CONN, peerNodeId: "ios-se-x", publicKeyBase64: bytes.toString("base64"), keyKind: "se-p256", publishedAtMillis: Date.now() }),
      ),
    ).rejects.toThrow();
  });
});

describe("F2 revokeEscrowDeviceTrust atomic clear + receipt", () => {
  beforeEach(async () => {
    seedTrustedDeviceAndPairing();
    // Publish a controller + grant authority for the device, then revoke it.
    const key = ed25519Key();
    await (publishPhoneControlAuthority as never as { run: (r: never) => Promise<unknown> }).run(
      req({ deviceId: DEVICE, connectionId: CONN, peerNodeId: key.peerNodeId, publicKeyBase64: key.base64, publishedAtMillis: Date.now() }),
    );
    await (publishAgentGrantAuthority as never as { run: (r: never) => Promise<unknown> }).run(
      req({ deviceId: DEVICE, peerNodeId: key.peerNodeId, publicKeyBase64: key.base64 }),
    );
    (globalThis as Record<string, unknown>).__f2PeerNodeId = key.peerNodeId;
  });

  it("deletes the controller record, clears the grant authority, and emits a receipt", async () => {
    const peerNodeId = (globalThis as Record<string, unknown>).__f2PeerNodeId as string;
    expect(store.has(`users/${UID}/iroh_pairing/${CONN}/controllers/${peerNodeId}`)).toBe(true);
    expect(store.has(`users/${UID}/agent_grant_authorities/${DEVICE}`)).toBe(true);

    const res = await (revokeEscrowDeviceTrust as never as {
      run: (r: never) => Promise<{ ok: boolean; revokedControllerPeerNodeIds: string[]; clearedAgentGrantAuthority: boolean; receiptId: string }>;
    }).run(req({ deviceId: DEVICE }));

    expect(res.ok).toBe(true);
    expect(res.revokedControllerPeerNodeIds).toContain(peerNodeId);
    expect(res.clearedAgentGrantAuthority).toBe(true);
    expect(res.receiptId).toMatch(/^revoke_/);

    // Atomic clear: the controller record and grant authority are gone.
    expect(store.has(`users/${UID}/iroh_pairing/${CONN}/controllers/${peerNodeId}`)).toBe(false);
    expect(store.has(`users/${UID}/agent_grant_authorities/${DEVICE}`)).toBe(false);
    // Device itself is flipped to revoked.
    expect(store.get(`users/${UID}/escrow_devices/${DEVICE}`)?.trustState).toBe("revoked");

    // A revocation receipt audit event was written.
    const receipts = [...store.entries()].filter(
      ([path, data]) => path.startsWith(`users/${UID}/computer_use_audit_events/`) && data.message === "phone_control_peer_revoked_receipt",
    );
    expect(receipts).toHaveLength(1);
    expect(receipts[0][1].receiptId).toBe(res.receiptId);
    expect(receipts[0][1].revokedControllerPeerNodeIds).toContain(peerNodeId);
  });
});
