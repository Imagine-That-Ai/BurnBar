/* eslint-disable max-lines -- reason: extensive unit test cases exceeding 600 lines */
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
import { createECDH, createHash, randomBytes, generateKeyPairSync, sign as cryptoSign } from "node:crypto";

const { store, dbMock, FieldValueMock, FakeTimestamp } = vi.hoisted(() => {
  // The store is a Map for path→data. We also hang a __hook on the store
  // object so query/transaction mocks can see hook mutations at call time
  // without relying on module-level variables (which are not in scope
  // inside vi.hoisted callbacks due to ESM hoisting order).
  const store = Object.assign(new Map<string, Record<string, unknown>>(), {
    __hook: null as (() => void) | null,
  });

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
      if (store.__hook && collectionPath.endsWith("/escrow_grants")) {
        const hook = store.__hook;
        store.__hook = null;
        hook();
      }
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
      // beforeTransactionHook is used by tests to simulate concurrent writes
      // (F-RR04-005 TOCTOU) or to mutate state between pre-tx and tx reads.
      // Stored on the store object to avoid vi.hoisted module-scope issues.
      if (store.__hook) store.__hook();
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

// setBeforeTransactionHook: sets a function to run at the START of the next
// escrow_grants query or runTransaction call (simulates concurrent writes in
// the TOCTOU race window).
// Stored on store.__hook so it's visible to the hoisted mock without module-
// level variable hoisting issues.
function setBeforeTransactionHook(fn: (() => void) | null) {
  store.__hook = fn;
}
beforeEach(() => {
  store.__hook = null;
  requireTrustedDeviceActionProof.mockClear();
  requireTrustedDeviceActionProof.mockResolvedValue({
    deviceId: "mac-1",
    platform: "macOS",
    signalIdentityKeyId: "mac-1_1",
  });
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
vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return {
    ...actual,
    assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined),
  };
});
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: vi.fn(), logWarn: vi.fn() };
});
// Signal session cleanup is exercised elsewhere; stub to isolate the F2 paths.
vi.mock("../signalDirectoryRuntime.js", () => ({ revokeSignalSessionsForDevice: vi.fn(async () => 0) }));
const { requireTrustedDeviceActionProof } = vi.hoisted(() => ({
  requireTrustedDeviceActionProof: vi.fn(async () => ({
    deviceId: "mac-1",
    platform: "macOS",
    signalIdentityKeyId: "mac-1_1",
  })),
}));
vi.mock("../callables/computerUseSecurityFirestore.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/computerUseSecurityFirestore.js")>(
    "../callables/computerUseSecurityFirestore.js",
  );
  return {
    ...actual,
    requireTrustedDeviceActionProof,
  };
});
vi.mock("../callables/computerUseSecurity.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/computerUseSecurity.js")>(
    "../callables/computerUseSecurity.js",
  );
  return {
    ...actual,
    __testing__: { ...actual.__testing__, requireTrustedDeviceActionProof },
    requireTrustedDeviceActionProof,
  };
});

import {
  __testing__,
  publishPhoneControlAuthority,
  publishRelaySenderKey,
  publishAgentGrantAuthority,
  queueAgentCapabilityGrantRequest,
  revokeEscrowDeviceTrust,
} from "../callables/computerUseSecurity.js";
import { rotateCloudVaultKey } from "../callables/cloudVaultRotation.js";
import { APP_CHECK_ATTESTATION_CLAIM_KEY, appCheckAttestationDigestHex } from "../appCheckAttestation.js";

// Cocoa reference epoch helpers (matching computerUseSecurity.ts)
const COCOA_EPOCH_OFFSET = 978307200; // seconds between Unix epoch and Cocoa reference date
const cocoaNow = () => Math.floor(Date.now() / 1000) - COCOA_EPOCH_OFFSET;

/**
 * Build a minimal valid queueAgentCapabilityGrantRequest payload.
 * Defaults to preset="low" (workspace_read only — no mac_approval_required).
 * Pass overrides to use a risky preset like "workspace" for F-RR04-004 tests.
 */
function queuedGrantData(opts: {
  peerNodeId: string;
  signGrant: (payload: Buffer) => Buffer;
  preset?: string;
  capabilities?: string[];
  trustMode?: string;
  deliveryMode?: string;
}) {
  const preset = opts.preset ?? "low";
  const capabilities = opts.capabilities ?? ["workspace_read"];
  const trustMode = opts.trustMode ?? "manual";
  const deliveryMode = opts.deliveryMode ?? "queued";
  const now = cocoaNow();
  const grantRequest = {
    requestId: `grant-test-${Math.random().toString(36).slice(2)}`,
    runtime: "claude",
    threadId: "thread-test-1",
    preset,
    capabilities,
    trustMode,
    deliveryMode,
    requestedAt: now,
    expiresAt: now + 120,
    grantDurationSeconds: 120,
    sourceDeviceId: DEVICE,
    clientIntentId: "intent-test-1",
    localAuthenticationSatisfied: false,
  };
  const intentHashHex = __testing__.agentGrantRequestHashHex(grantRequest);
  const payload = __testing__.agentGrantAuthoritySignablePayload(intentHashHex.toLowerCase(), 1, now);
  const signature = opts.signGrant(payload);
  return {
    ...grantRequest,
    authority: {
      peerNodeId: opts.peerNodeId,
      counter: 1,
      timestamp: now,
      intentHashBlake3: intentHashHex,
      signatureEd25519: signature.toString("base64"),
    },
  };
}

const APP_ID = "1:123:ios:abc";
const APP_CHECK_BOUND_AT_MILLIS = Date.now();
const UID = "uidF2";
const DEVICE = "phone-1";
const CONN = "conn-1";
const RELAY_ACTION_PROOF = { signature: "relay-sender-key-proof" };
let relayNonceCounter = 0;

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

function relaySenderKey(): { base64: string; keyId: string; peerNodeId: string } {
  const ecdh = createECDH("prime256v1");
  ecdh.generateKeys();
  const x963 = ecdh.getPublicKey();
  const digest = createHash("sha256").update(x963).digest("hex");
  return {
    base64: x963.toString("base64"),
    keyId: `relay-v3-${digest.slice(0, 24)}`,
    peerNodeId: `ios-se-${digest.slice(0, 24)}`,
  };
}

function seedSignalIdentity(deviceId = DEVICE, version = 1, fingerprint = "sha256:signal-identity") {
  store.set(`users/${UID}/signal_identity_public_keys/${deviceId}_${version}`, {
    deviceId,
    identityKeyId: `${deviceId}_${version}`,
    publicKeyFingerprint: fingerprint,
    keyVersion: version,
  });
}

function seedHighRiskNonce(nonce: string) {
  store.set(`users/${UID}/high_risk_action_nonces/${nonce}`, {
    nonce,
    createdAtMillis: Date.now(),
    expiresAtMillis: Date.now() + 60_000,
    consumedAt: null,
  });
}

function relaySenderKeyPublishRequest(
  key: { base64: string; keyId: string; peerNodeId: string },
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  const nonce =
    typeof overrides.nonce === "string" && overrides.nonce.length > 0
      ? overrides.nonce
      : `relay-sender-key-nonce-${++relayNonceCounter}`;
  seedHighRiskNonce(nonce);
  return {
    deviceId: DEVICE,
    peerNodeId: key.peerNodeId,
    keyId: key.keyId,
    publicKeyBase64: key.base64,
    relayKeyVersion: 3,
    publishedAtMillis: Date.now(),
    signalIdentityKeyId: `${DEVICE}_1`,
    signalIdentityKeyVersion: 1,
    signalIdentityPublicKeyFingerprint: "sha256:phone-identity",
    nonce,
    actionProof: RELAY_ACTION_PROOF,
    ...overrides,
  };
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
    expect(rec?.appCheckAttestationHashBlake3).toBe(appCheckAttestationDigestHex(APP_ID, APP_CHECK_BOUND_AT_MILLIS));
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
    expect(store.get(`users/${UID}/escrow_devices/${DEVICE}`)?.peerNodeId).toBe(key.peerNodeId);
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

  it("rejects a controller publish that conflicts with the trusted device peer binding", async () => {
    const key = seP256Key();
    store.set(`users/${UID}/escrow_devices/${DEVICE}`, {
      platform: "iOS",
      trustState: "trusted",
      keyVersion: 1,
      peerNodeId: "ios-se-existingpeerbinding",
    });

    await expect(
      invokeCallable(publishPhoneControlAuthority, {
        deviceId: DEVICE,
        connectionId: CONN,
        peerNodeId: key.peerNodeId,
        publicKeyBase64: key.base64,
        keyKind: "se-p256",
        publishedAtMillis: Date.now(),
      }),
    ).rejects.toThrow(/peer node/);
    expect(store.has(`users/${UID}/iroh_pairing/${CONN}/controllers/${key.peerNodeId}`)).toBe(false);
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

describe("publishAgentGrantAuthority attestation binding", () => {
  beforeEach(seedTrustedDeviceAndPairing);

  it("persists the server-derived App Check digest with the grant authority", async () => {
    const key = ed25519Key();
    const res = await invokeCallable<{ ok: boolean }>(publishAgentGrantAuthority, {
      deviceId: DEVICE,
      peerNodeId: key.peerNodeId,
      publicKeyBase64: key.base64,
    });

    expect(res.ok).toBe(true);
    expect(store.get(`users/${UID}/agent_grant_authorities/${DEVICE}`)?.appCheckAttestationHashBlake3).toBe(
      appCheckAttestationDigestHex(APP_ID, APP_CHECK_BOUND_AT_MILLIS),
    );
    expect(store.get(`users/${UID}/escrow_devices/${DEVICE}`)?.peerNodeId).toBe(key.peerNodeId);
  });

  it("rejects agent-grant authority that conflicts with the trusted device peer binding", async () => {
    const key = ed25519Key();
    store.set(`users/${UID}/escrow_devices/${DEVICE}`, {
      platform: "iOS",
      trustState: "trusted",
      keyVersion: 1,
      peerNodeId: "ios-phone-existingpeerbinding",
    });

    await expect(
      invokeCallable(publishAgentGrantAuthority, {
        deviceId: DEVICE,
        peerNodeId: key.peerNodeId,
        publicKeyBase64: key.base64,
      }),
    ).rejects.toThrow(/peer node/);
    expect(store.has(`users/${UID}/agent_grant_authorities/${DEVICE}`)).toBe(false);
  });
});

describe("publishRelaySenderKey trust binding", () => {
  beforeEach(seedTrustedDeviceAndPairing);

  it("publishes only when the relay sender key is bound to the trusted device's Signal identity", async () => {
    const key = relaySenderKey();
    const fingerprint = "sha256:phone-identity";
    store.set(`users/${UID}/escrow_devices/${DEVICE}`, {
      platform: "iOS",
      trustState: "trusted",
      keyVersion: 1,
      peerNodeId: key.peerNodeId,
    });
    seedSignalIdentity(DEVICE, 1, fingerprint);

    const request = relaySenderKeyPublishRequest(key, { signalIdentityPublicKeyFingerprint: fingerprint });
    const res = await invokeCallable<{ ok: boolean; deviceId: string; keyId: string }>(publishRelaySenderKey, request);

    expect(res.ok).toBe(true);
    expect(res.deviceId).toBe(DEVICE);
    expect(res.keyId).toBe(key.keyId);
    const stored = store.get(`users/${UID}/relay_sender_keys/${DEVICE}`);
    expect(stored?.publicKeyBase64).toBe(key.base64);
    expect(stored?.signalIdentityKeyId).toBe(`${DEVICE}_1`);
    expect(stored?.signalIdentityVerification).toBe("verified");
    expect(requireTrustedDeviceActionProof).toHaveBeenCalledWith(
      expect.objectContaining({
        uid: UID,
        deviceId: DEVICE,
        actionKind: "relay_sender_key_publish",
        subjectId: expect.stringMatching(/^[a-f0-9]{64}$/u),
        approve: true,
        nonce: request.nonce,
        proofRaw: RELAY_ACTION_PROOF,
        allowedPlatforms: new Set(["iOS", "iPadOS", "Android"]),
      }),
    );
  });

  it("rejects relay sender keys bound to another device identity", async () => {
    const key = relaySenderKey();
    seedSignalIdentity("other-phone", 1, "sha256:other");

    await expect(
      invokeCallable(publishRelaySenderKey, {
        ...relaySenderKeyPublishRequest(key),
        signalIdentityKeyId: "other-phone_1",
        signalIdentityPublicKeyFingerprint: "sha256:other",
      }),
    ).rejects.toThrow(/bind to this device/);
    expect(store.has(`users/${UID}/relay_sender_keys/${DEVICE}`)).toBe(false);
  });

  it("rejects relay sender keys whose identity fingerprint does not match the server record", async () => {
    const key = relaySenderKey();
    seedSignalIdentity(DEVICE, 1, "sha256:server");

    await expect(
      invokeCallable(publishRelaySenderKey, {
        ...relaySenderKeyPublishRequest(key),
        signalIdentityPublicKeyFingerprint: "sha256:client-forged",
      }),
    ).rejects.toThrow(/published Signal identity/);
    expect(store.has(`users/${UID}/relay_sender_keys/${DEVICE}`)).toBe(false);
  });

  it("rejects relay sender keys that do not match the trusted device peer binding", async () => {
    const key = relaySenderKey();
    seedSignalIdentity(DEVICE, 1, "sha256:phone-identity");
    store.set(`users/${UID}/escrow_devices/${DEVICE}`, {
      platform: "iOS",
      trustState: "trusted",
      keyVersion: 1,
      peerNodeId: "ios-se-differentpeerbinding",
    });

    await expect(invokeCallable(publishRelaySenderKey, relaySenderKeyPublishRequest(key))).rejects.toThrow(/peer node/);
    expect(store.has(`users/${UID}/relay_sender_keys/${DEVICE}`)).toBe(false);
  });

  it("rejects relay sender keys without a valid trusted-device action proof", async () => {
    const key = relaySenderKey();
    seedSignalIdentity(DEVICE, 1, "sha256:phone-identity");
    store.set(`users/${UID}/escrow_devices/${DEVICE}`, {
      platform: "iOS",
      trustState: "trusted",
      keyVersion: 1,
      peerNodeId: key.peerNodeId,
    });
    requireTrustedDeviceActionProof.mockRejectedValueOnce(new Error("trusted-device action proof rejected"));

    await expect(invokeCallable(publishRelaySenderKey, relaySenderKeyPublishRequest(key))).rejects.toThrow(
      /trusted-device action proof/,
    );
    expect(store.has(`users/${UID}/relay_sender_keys/${DEVICE}`)).toBe(false);
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
  const ROTATION_NONCE = "rotation-handoff-nonce";

  beforeEach(() => {
    store.clear();
    store.set(`users/${UID}/high_risk_action_nonces/${ROTATION_NONCE}`, {
      nonce: ROTATION_NONCE,
      createdAtMillis: Date.now(),
      expiresAtMillis: Date.now() + 60_000,
      consumedAt: null,
    });
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
      nonce: ROTATION_NONCE,
      actionProof: { signature: "rotation-handoff-proof" },
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
    expect(requireTrustedDeviceActionProof).toHaveBeenCalledWith(
      expect.objectContaining({
        uid: UID,
        deviceId: MAC,
        actionKind: "cloud_vault_key_rotation",
        subjectId: `${CURRENT_KEY}->${NEXT_KEY}@8`,
        approve: true,
        nonce: ROTATION_NONCE,
        proofRaw: { signature: "rotation-handoff-proof" },
      }),
    );
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

/** Generates a P-256 keypair in X9.63 format, matching the server's SE-P256 convention. */
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

  it("rejects a grant request from a revoked source device (trust re-check)", async () => {
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const jwk = publicKey.export({ format: "jwk" });
    const rawPub = Buffer.from(jwk.x ?? "", "base64url");
    const peerNodeId = `ios-phone-${rawPub.subarray(0, 12).toString("hex")}`;
    store.set(`users/${UID}/agent_grant_authorities/${DEVICE}`, {
      peerNodeId,
      publicKeyBase64: rawPub.toString("base64"),
    });
    // Set the device to revoked BEFORE the call. Both the pre-transaction
    // requireTrustedEscrowDevice check and the transaction-level freshSourceDevice
    // re-check will see this state and reject the request.
    // This proves the trust-check guard exists on this callable path.
    store.set(`users/${UID}/escrow_devices/${DEVICE}`, {
      platform: "iOS",
      trustState: "revoked",
      keyVersion: 1,
    });
    const data = queuedGrantData({
      peerNodeId,
      signGrant: (payload) => cryptoSign(null, payload, privateKey),
    });
    await expect(invokeCallable(queueAgentCapabilityGrantRequest, data)).rejects.toThrow(
      /trusted|no longer trusted|trust/i,
    );
    // Grant request must NOT have been written.
    expect(store.has(`users/${UID}/agent_capability_grant_requests/${data.requestId}`)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// F-RR04-004: deliveryMode=live must NOT bypass mac_approval_required.
//
// Before the fix, queuedAgentGrantDeliveryRequiresMacApproval() had a branch
// that short-circuited when deliveryMode="live", allowing risky capabilities
// through without Mac approval. The fix removes the bypass so all delivery
// modes go through the same queuedAgentGrantRequiresMacApproval gate.
// ---------------------------------------------------------------------------
describe("F-RR04-004 deliveryMode=live does not bypass mac_approval_required", () => {
  beforeEach(seedTrustedDeviceAndPairing);

  it("throws mac_approval_required for a risky capability with deliveryMode=live", async () => {
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const jwk = publicKey.export({ format: "jwk" });
    const rawPub = Buffer.from(jwk.x ?? "", "base64url");
    const peerNodeId = `ios-phone-${rawPub.subarray(0, 12).toString("hex")}`;
    store.set(`users/${UID}/agent_grant_authorities/${DEVICE}`, {
      peerNodeId,
      publicKeyBase64: rawPub.toString("base64"),
    });

    // Build a grant with:
    //   preset = "workspace" (shell + workspace_read + workspace_write)
    //   deliveryMode = "live"  (was previously exempt from mac_approval_required)
    // The callable validates capabilities === grantPresetCapabilities(preset), so
    // we must send the full workspace capability list to reach the gate.
    // shell is the capability that triggers mac_approval_required.
    const data = queuedGrantData({
      peerNodeId,
      signGrant: (payload) => cryptoSign(null, payload, privateKey),
      preset: "workspace",
      capabilities: ["shell", "workspace_read", "workspace_write"],
      trustMode: "manual",
      deliveryMode: "live",
    });

    // Must throw mac_approval_required regardless of deliveryMode.
    await expect(invokeCallable(queueAgentCapabilityGrantRequest, data)).rejects.toThrow(/mac_approval_required/i);
    // Grant request must NOT have been written.
    expect(store.has(`users/${UID}/agent_capability_grant_requests/${data.requestId}`)).toBe(false);
  });

  it("allows deliveryMode=live for a non-risky capability (no Mac approval needed)", async () => {
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const jwk = publicKey.export({ format: "jwk" });
    const rawPub = Buffer.from(jwk.x ?? "", "base64url");
    const peerNodeId = `ios-phone-${rawPub.subarray(0, 12).toString("hex")}`;
    store.set(`users/${UID}/agent_grant_authorities/${DEVICE}`, {
      peerNodeId,
      publicKeyBase64: rawPub.toString("base64"),
    });

    // preset="low" → workspace_read only → no mac_approval_required.
    const data = queuedGrantData({
      peerNodeId,
      signGrant: (payload) => cryptoSign(null, payload, privateKey),
      preset: "low",
      capabilities: ["workspace_read"],
      trustMode: "manual",
      deliveryMode: "live",
    });

    const res = await invokeCallable<{ ok: boolean }>(queueAgentCapabilityGrantRequest, data);
    expect(res.ok).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// F-RR04-005: revokeEscrowDeviceTrust grant-revocation race.
//
// The revocation callable must flip the parent device to trustState=revoked
// before it sweeps escrow_grants. Firestore rules then reject new active grant
// creates for the revoked target, while the post-flip sweep catches grants that
// raced in before the parent revoke write committed.
// ---------------------------------------------------------------------------
describe("F-RR04-005 revokeEscrowDeviceTrust grant-revocation race", () => {
  beforeEach(() => {
    seedTrustedDeviceAndPairing();
    store.set(`users/${UID}/escrow_devices/mac-1`, { platform: "macOS", trustState: "trusted", keyVersion: 1 });
  });

  it("revokes target and source grants created before the sweep query", async () => {
    // Seed: trusted device with pre-existing grants in both directions.
    store.set(`users/${UID}/escrow_grants/pre-existing-grant`, {
      sourceDeviceId: "mac-1",
      targetDeviceId: DEVICE,
      status: "granted",
    });
    store.set(`users/${UID}/escrow_grants/pre-existing-source-grant`, {
      sourceDeviceId: DEVICE,
      targetDeviceId: "mac-1",
      status: "granted",
    });

    // Inject a concurrent grant immediately before the escrow_grants sweep
    // query. The parent device has already been flipped to revoked at this
    // point, so a real client write is rule-denied; this admin-side simulation
    // proves the sweep still catches any grant that slipped in before rules saw
    // the revoke write.
    setBeforeTransactionHook(() => {
      store.set(`users/${UID}/escrow_grants/concurrent-grant`, {
        sourceDeviceId: "mac-1",
        targetDeviceId: DEVICE,
        status: "granted",
      });
      store.set(`users/${UID}/escrow_grants/concurrent-source-grant`, {
        sourceDeviceId: DEVICE,
        targetDeviceId: "mac-1",
        status: "granted",
      });
    });

    await invokeCallable(revokeEscrowDeviceTrust, {
      deviceId: DEVICE,
    });

    expect(store.get(`users/${UID}/escrow_grants/pre-existing-grant`)?.status).toBe("revoked");
    expect(store.get(`users/${UID}/escrow_grants/pre-existing-source-grant`)?.status).toBe("revoked");
    const concurrentGrantStatus = store.get(`users/${UID}/escrow_grants/concurrent-grant`)?.status;
    expect(concurrentGrantStatus).toBe("revoked");
    const concurrentSourceGrantStatus = store.get(`users/${UID}/escrow_grants/concurrent-source-grant`)?.status;
    expect(concurrentSourceGrantStatus).toBe("revoked");
  });
});
