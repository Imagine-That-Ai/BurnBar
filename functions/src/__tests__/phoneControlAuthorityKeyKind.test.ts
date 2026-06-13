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
 *    authority, revokes active CloudVault wrappers, creates a survivor-owned
 *    rotation requirement, and emits a revocation receipt audit event + receiptId.
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
      // Reads happen live against the store; writes are buffered and applied
      // on success, mirroring Firestore transaction semantics closely enough
      // for the single-attempt handlers under test.
      const writes: Array<() => void> = [];
      const transaction = {
        async get(refOrQuery: { path?: string; __isQuery?: boolean; get?: () => Promise<unknown> }) {
          if (refOrQuery.__isQuery && refOrQuery.get) {
            return refOrQuery.get();
          }
          return snapshotFor(refOrQuery.path ?? "");
        },
        getAll(...refs: Array<{ path: string }>) {
          return Promise.resolve(refs.map((ref) => snapshotFor(ref.path)));
        },
        set(ref: { path: string }, data: Record<string, unknown>, opts?: { merge?: boolean }) {
          writes.push(() => {
            const existing = opts?.merge ? (store.get(ref.path) ?? {}) : {};
            store.set(ref.path, { ...existing, ...data });
          });
          return transaction;
        },
        create(ref: { path: string }, data: Record<string, unknown>) {
          if (store.has(ref.path)) {
            throw new Error(`ALREADY_EXISTS: ${ref.path}`);
          }
          writes.push(() => store.set(ref.path, { ...data }));
          return transaction;
        },
        update(ref: { path: string }, data: Record<string, unknown>) {
          writes.push(() => store.set(ref.path, { ...(store.get(ref.path) ?? {}), ...data }));
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

import {
  publishPhoneControlAuthority,
  publishAgentGrantAuthority,
  revokeEscrowDeviceTrust,
} from "../callables/computerUseSecurity.js";
import { rotateCloudVaultKey } from "../callables/cloudVaultRotation.js";
import { APP_CHECK_ATTESTATION_CLAIM_KEY } from "../appCheckAttestation.js";

const APP_ID = "1:123:ios:abc";
const UID = "uidF2";
const DEVICE = "phone-1";
const CONN = "conn-1";

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

/**
 * Single typed seam for driving the real callables through `.run(request)`.
 * Funnelling every invocation through this helper keeps the unavoidable
 * mock-request widening to exactly one cast instead of one per call site.
 */
function invokeCallable<TRes = unknown>(callable: unknown, data: Record<string, unknown>): Promise<TRes> {
  const runnable = callable as { run: (request: unknown) => Promise<TRes> };
  return runnable.run(req(data));
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
    const res = await invokeCallable<{ ok: boolean; peerNodeId: string }>(publishPhoneControlAuthority, {
      deviceId: DEVICE,
      connectionId: CONN,
      peerNodeId: key.peerNodeId,
      publicKeyBase64: key.base64,
      publishedAtMillis: Date.now(),
    });
    expect(res.ok).toBe(true);
    const rec = store.get(`users/${UID}/iroh_pairing/${CONN}/controllers/${key.peerNodeId}`);
    expect(rec?.signingKeyKind).toBe("ed25519");
    expect(rec?.schemaVersion).toBe(2);
    expect(rec?.publicKeyBase64).toBe(key.base64);
  });

  it("publishes a Secure-Enclave P-256 controller", async () => {
    const key = seP256Key();
    const res = await invokeCallable<{ ok: boolean }>(publishPhoneControlAuthority, {
      deviceId: DEVICE,
      connectionId: CONN,
      peerNodeId: key.peerNodeId,
      publicKeyBase64: key.base64,
      keyKind: "se-p256",
      publishedAtMillis: Date.now(),
    });
    expect(res.ok).toBe(true);
    const rec = store.get(`users/${UID}/iroh_pairing/${CONN}/controllers/${key.peerNodeId}`);
    expect(rec?.signingKeyKind).toBe("se-p256");
    expect(rec?.schemaVersion).toBe(3);
  });

  it("rejects a peerNodeId that does not match the published key", async () => {
    const key = seP256Key();
    await expect(
      invokeCallable(publishPhoneControlAuthority, {
        deviceId: DEVICE,
        connectionId: CONN,
        peerNodeId: "ios-se-deadbeefdeadbeefdeadbeef",
        publicKeyBase64: key.base64,
        keyKind: "se-p256",
        publishedAtMillis: Date.now(),
      }),
    ).rejects.toThrow(/peerNodeId does not match/);
  });

  it("rejects an se-p256 publish carrying an Ed25519-length key", async () => {
    const bytes = randomBytes(32);
    await expect(
      invokeCallable(publishPhoneControlAuthority, {
        deviceId: DEVICE,
        connectionId: CONN,
        peerNodeId: "ios-se-x",
        publicKeyBase64: bytes.toString("base64"),
        keyKind: "se-p256",
        publishedAtMillis: Date.now(),
      }),
    ).rejects.toThrow();
  });
});

describe("F2 revokeEscrowDeviceTrust atomic clear + receipt", () => {
  let publishedPeerNodeId = "";

  beforeEach(async () => {
    seedTrustedDeviceAndPairing();
    store.set(`users/${UID}/escrow_devices/mac-1`, { platform: "macOS", trustState: "trusted", keyVersion: 1 });
    store.set(`users/${UID}/cloud_vault_state/current`, {
      uid: UID,
      status: "active",
      vaultKeyID: `v1_${"a".repeat(32)}`,
      vaultGeneration: 7,
    });
    store.set(`users/${UID}/cloud_vault_key_wrappers/wrap-phone`, {
      uid: UID,
      targetDeviceId: DEVICE,
      sourceDeviceId: "mac-1",
      status: "active",
      vaultKeyID: `v1_${"a".repeat(32)}`,
    });
    // Publish a controller + grant authority for the device, then revoke it.
    const key = ed25519Key();
    await invokeCallable(publishPhoneControlAuthority, {
      deviceId: DEVICE,
      connectionId: CONN,
      peerNodeId: key.peerNodeId,
      publicKeyBase64: key.base64,
      publishedAtMillis: Date.now(),
    });
    await invokeCallable(publishAgentGrantAuthority, {
      deviceId: DEVICE,
      peerNodeId: key.peerNodeId,
      publicKeyBase64: key.base64,
    });
    publishedPeerNodeId = key.peerNodeId;
  });

  it("deletes the controller record, clears the grant authority, and emits a receipt", async () => {
    const peerNodeId = publishedPeerNodeId;
    expect(store.has(`users/${UID}/iroh_pairing/${CONN}/controllers/${peerNodeId}`)).toBe(true);
    expect(store.has(`users/${UID}/agent_grant_authorities/${DEVICE}`)).toBe(true);

    const res = await invokeCallable<{
      ok: boolean;
      revokedControllerPeerNodeIds: string[];
      clearedAgentGrantAuthority: boolean;
      revokedCloudVaultWrappers: number;
      cloudVaultRotationRequired: boolean;
      cloudVaultRotationRequirementId: string;
      receiptId: string;
    }>(revokeEscrowDeviceTrust, { deviceId: DEVICE });

    expect(res.ok).toBe(true);
    expect(res.revokedControllerPeerNodeIds).toContain(peerNodeId);
    expect(res.clearedAgentGrantAuthority).toBe(true);
    expect(res.revokedCloudVaultWrappers).toBe(1);
    expect(res.cloudVaultRotationRequired).toBe(true);
    expect(res.cloudVaultRotationRequirementId).toBe(res.receiptId);
    expect(res.receiptId).toMatch(/^revoke_/);

    // Atomic clear: the controller record and grant authority are gone.
    expect(store.has(`users/${UID}/iroh_pairing/${CONN}/controllers/${peerNodeId}`)).toBe(false);
    expect(store.has(`users/${UID}/agent_grant_authorities/${DEVICE}`)).toBe(false);
    // Device itself is flipped to revoked.
    expect(store.get(`users/${UID}/escrow_devices/${DEVICE}`)?.trustState).toBe("revoked");
    expect(store.get(`users/${UID}/cloud_vault_key_wrappers/wrap-phone`)?.status).toBe("revoked");

    const requirement = store.get(`users/${UID}/cloud_vault_rotation_requirements/${res.receiptId}`);
    expect(requirement?.status).toBe("pending");
    expect(requirement?.reason).toBe("device_revoked");
    expect(requirement?.revokedDeviceId).toBe(DEVICE);
    expect(requirement?.currentVaultGeneration).toBe(7);
    expect(requirement?.survivorDeviceIds).toEqual(["mac-1"]);
    expect(requirement?.rotateCallable).toBe("rotateCloudVaultKey");
    expect(requirement?.nextRotationReason).toBe("revocation_rewrap");

    // A revocation receipt audit event was written.
    const receipts = [...store.entries()].filter(
      ([path, data]) =>
        path.startsWith(`users/${UID}/computer_use_audit_events/`) &&
        data.message === "phone_control_peer_revoked_receipt",
    );
    expect(receipts).toHaveLength(1);
    expect(receipts[0][1].receiptId).toBe(res.receiptId);
    expect(receipts[0][1].revokedControllerPeerNodeIds).toContain(peerNodeId);
    expect(receipts[0][1].revokedCloudVaultWrappers).toBe(1);
    expect(receipts[0][1].cloudVaultRotationRequired).toBe(true);
    expect(receipts[0][1].cloudVaultRotationRequirementId).toBe(res.receiptId);
  });
});

describe("F2 rotateCloudVaultKey requirement handoff", () => {
  const MAC = "mac-1";
  const CURRENT_KEY = `v1_${"a".repeat(32)}`;
  const NEXT_KEY = `v1_${"b".repeat(32)}`;
  const REQUIREMENT_ID = "revoke_receipt_1";

  beforeEach(() => {
    store.clear();
    store.set(`users/${UID}/escrow_devices/${MAC}`, { platform: "macOS", trustState: "trusted", keyVersion: 1 });
    store.set(`users/${UID}/escrow_devices/${DEVICE}`, { platform: "iOS", trustState: "revoked", keyVersion: 1 });
    store.set(`users/${UID}/cloud_vault_state/current`, {
      uid: UID,
      status: "active",
      vaultKeyID: CURRENT_KEY,
      vaultGeneration: 7,
    });
    store.set(`users/${UID}/cloud_vault_key_wrappers/wrap-phone-old`, {
      uid: UID,
      targetDeviceId: DEVICE,
      sourceDeviceId: MAC,
      status: "active",
      vaultKeyID: CURRENT_KEY,
    });
    store.set(`users/${UID}/cloud_vault_key_wrappers/wrap-mac-old`, {
      uid: UID,
      targetDeviceId: MAC,
      sourceDeviceId: DEVICE,
      status: "active",
      vaultKeyID: CURRENT_KEY,
    });
    store.set(`users/${UID}/cloud_vault_rotation_requirements/${REQUIREMENT_ID}`, {
      status: "pending",
      rotateCallable: "rotateCloudVaultKey",
      currentVaultKeyID: CURRENT_KEY,
      currentVaultGeneration: 7,
      survivorDeviceIds: [MAC],
    });
  });

  function survivorWrapper(targetDeviceId = MAC): Record<string, unknown> {
    return {
      wrapperId: `wrap-${targetDeviceId}-next`,
      targetDeviceId,
      sourceDeviceId: MAC,
      publicKeyFingerprint: "sha256:mac",
      keyVersion: 2,
      vaultKeyID: NEXT_KEY,
      wrappedVaultKey: Buffer.from("next-vault-key").toString("base64"),
    };
  }

  function rotationRequest(overrides: Record<string, unknown> = {}): Record<string, unknown> {
    return {
      callerDeviceId: MAC,
      currentVaultKeyID: CURRENT_KEY,
      newVaultKeyID: NEXT_KEY,
      expectedVaultGeneration: 8,
      reason: "revocation_rewrap",
      rotationRequirementId: REQUIREMENT_ID,
      survivorWrappers: [survivorWrapper()],
      ...overrides,
    };
  }

  it("queues a matching revocation rotation requirement and revokes old wrappers", async () => {
    const res = await invokeCallable<{
      ok: boolean;
      jobId: string;
      newVaultKeyID: string;
      vaultGeneration: number;
      status: string;
    }>(rotateCloudVaultKey, rotationRequest());

    expect(res.ok).toBe(true);
    expect(res.status).toBe("queued");
    expect(res.newVaultKeyID).toBe(NEXT_KEY);
    expect(res.vaultGeneration).toBe(8);

    const state = store.get(`users/${UID}/cloud_vault_state/current`);
    expect(state?.vaultKeyID).toBe(NEXT_KEY);
    expect(state?.previousVaultKeyID).toBe(CURRENT_KEY);
    expect(state?.vaultGeneration).toBe(8);
    expect(state?.rotationJobId).toBe(res.jobId);

    const requirement = store.get(`users/${UID}/cloud_vault_rotation_requirements/${REQUIREMENT_ID}`);
    expect(requirement?.status).toBe("queued");
    expect(requirement?.rotationJobId).toBe(res.jobId);

    const nextWrapper = store.get(`users/${UID}/cloud_vault_key_wrappers/wrap-${MAC}-next`);
    expect(nextWrapper?.status).toBe("active");
    expect(nextWrapper?.vaultKeyID).toBe(NEXT_KEY);
    expect(nextWrapper?.rotationJobId).toBe(res.jobId);

    expect(store.get(`users/${UID}/cloud_vault_key_wrappers/wrap-phone-old`)?.status).toBe("revoked");
    expect(store.get(`users/${UID}/cloud_vault_key_wrappers/wrap-mac-old`)?.status).toBe("revoked");

    const job = store.get(`users/${UID}/cloud_vault_rotation_jobs/${res.jobId}`);
    expect(job?.reason).toBe("revocation_rewrap");
    expect(job?.survivorDeviceIds).toEqual([MAC]);
    expect(job?.revokedDeviceIds).toEqual([DEVICE]);
  });

  it("rejects a stale or mismatched rotation requirement", async () => {
    store.set(`users/${UID}/cloud_vault_rotation_requirements/${REQUIREMENT_ID}`, {
      status: "pending",
      rotateCallable: "rotateCloudVaultKey",
      currentVaultKeyID: CURRENT_KEY,
      currentVaultGeneration: 6,
      survivorDeviceIds: [MAC],
    });

    await expect(invokeCallable(rotateCloudVaultKey, rotationRequest())).rejects.toThrow(
      /CloudVault rotation requirement does not match/,
    );
    expect(store.get(`users/${UID}/cloud_vault_state/current`)?.vaultKeyID).toBe(CURRENT_KEY);
    expect(store.get(`users/${UID}/cloud_vault_rotation_requirements/${REQUIREMENT_ID}`)?.status).toBe("pending");
  });
});

// ---------------------------------------------------------------------------
// F2 — queued agent grants must verify SE-P256 authorities too (the queued
// lane was Ed25519-only, so an SE controller's grants were rejected even
// though publish accepted its key).
// ---------------------------------------------------------------------------
import { queueAgentCapabilityGrantRequest, __testing__ } from "../callables/computerUseSecurity.js";
import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";

const COCOA_OFFSET = 978307200; // 2001-01-01 epoch offset, mirrors the server.

function cocoaNow(): number {
  return Date.now() / 1000 - COCOA_OFFSET;
}

function p256Pair(): { x963: Buffer; privateKey: import("node:crypto").KeyObject; peerNodeId: string } {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" });
  // EC JWKs always carry x/y; the fallbacks only satisfy the optional typing.
  const x963 = Buffer.concat([
    Buffer.from([0x04]),
    Buffer.from(jwk.x ?? "", "base64url"),
    Buffer.from(jwk.y ?? "", "base64url"),
  ]);
  const digest = createHash("sha256").update(x963).digest("hex").slice(0, 24);
  return { x963, privateKey, peerNodeId: `ios-se-${digest}` };
}

function queuedGrantData(options: { peerNodeId: string; signGrant: (payload: Buffer) => Buffer }) {
  const now = cocoaNow();
  const grantRequest = {
    requestId: `grant-${Math.random().toString(36).slice(2)}`,
    runtime: "claude",
    threadId: "thread-1",
    preset: "low",
    capabilities: ["workspace_read"],
    trustMode: "manual",
    deliveryMode: "queued",
    requestedAt: now,
    expiresAt: now + 120,
    grantDurationSeconds: 120,
    sourceDeviceId: DEVICE,
    clientIntentId: "intent-queued-1",
    localAuthenticationSatisfied: false,
  };
  const intentHashHex = __testing__.agentGrantRequestHashHex(grantRequest);
  const payload = __testing__.agentGrantAuthoritySignablePayload(intentHashHex.toLowerCase(), 1, now);
  const signature = options.signGrant(payload);
  return {
    ...grantRequest,
    authority: {
      peerNodeId: options.peerNodeId,
      counter: 1,
      timestamp: now,
      intentHashBlake3: intentHashHex,
      signatureEd25519: signature.toString("base64"),
    },
  };
}

describe("F2 queueAgentCapabilityGrantRequest keyKind", () => {
  beforeEach(seedTrustedDeviceAndPairing);

  it("accepts a queued grant signed by an SE-P256 authority", async () => {
    const { x963, privateKey, peerNodeId } = p256Pair();
    store.set(`users/${UID}/agent_grant_authorities/${DEVICE}`, {
      peerNodeId,
      publicKeyBase64: x963.toString("base64"),
      signingKeyKind: "se-p256",
    });
    const data = queuedGrantData({
      peerNodeId,
      signGrant: (payload) => cryptoSign("sha256", payload, { key: privateKey, dsaEncoding: "ieee-p1363" }),
    });
    const res = await invokeCallable<{ ok: boolean }>(queueAgentCapabilityGrantRequest, data);
    expect(res.ok).toBe(true);
  });

  it("rejects a queued grant whose SE-P256 signature does not verify", async () => {
    const { x963, peerNodeId } = p256Pair();
    const attacker = p256Pair();
    store.set(`users/${UID}/agent_grant_authorities/${DEVICE}`, {
      peerNodeId,
      publicKeyBase64: x963.toString("base64"),
      signingKeyKind: "se-p256",
    });
    const data = queuedGrantData({
      peerNodeId,
      signGrant: (payload) => cryptoSign("sha256", payload, { key: attacker.privateKey, dsaEncoding: "ieee-p1363" }),
    });
    await expect(invokeCallable(queueAgentCapabilityGrantRequest, data)).rejects.toThrow(/signature is invalid/i);
  });

  it("still accepts a legacy Ed25519 queued grant (no signingKeyKind on the doc)", async () => {
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const jwk = publicKey.export({ format: "jwk" });
    const rawPub = Buffer.from(jwk.x ?? "", "base64url");
    const peerNodeId = `ios-phone-${rawPub.subarray(0, 12).toString("hex")}`;
    store.set(`users/${UID}/agent_grant_authorities/${DEVICE}`, {
      peerNodeId,
      publicKeyBase64: rawPub.toString("base64"),
    });
    const data = queuedGrantData({
      peerNodeId,
      signGrant: (payload) => cryptoSign(null, payload, privateKey),
    });
    const res = await invokeCallable<{ ok: boolean }>(queueAgentCapabilityGrantRequest, data);
    expect(res.ok).toBe(true);
  });
});
