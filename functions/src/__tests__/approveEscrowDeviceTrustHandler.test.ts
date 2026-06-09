/**
 * Handler-level coverage for `approveEscrowDeviceTrust` (B1 + B2).
 *
 * Proves end-to-end through the real callable handler (`.run(request)`):
 *  - B1: a forged/garbage trust-chain signature is REJECTED (permission-denied),
 *        a GENUINE libsignal XEd25519 signature is ACCEPTED and the device is
 *        promoted to trustState:"trusted", and both the non-bootstrap (distinct
 *        approver) and bootstrap (self-approval) shapes verify.
 *  - B2: a bootstrap self-approval WITHOUT a single-use nonce is REJECTED when
 *        App Check is enforced, and ACCEPTED once a valid nonce is supplied.
 *
 * The valid signatures are ground-truth vectors emitted by the REAL libsignal
 * library (Vendor/libsignal/rust/core) over the exact canonical bytes the server
 * reconstructs from Firestore state, so this is triangulated cross-language proof
 * that the server reconstruction byte-matches the client signer.
 */

import { describe, expect, it, beforeEach, vi } from "vitest";

// ---------------------------------------------------------------------------
// In-memory Firestore double. Supports the handler's access patterns:
//   db.doc(path).get(), db.collection(path).where().where().limit(),
//   db.runTransaction(fn), tx.get(docRef | queryRef), tx.set(ref, data, opts).
// ---------------------------------------------------------------------------
const { store, dbMock, FieldValueMock, FakeTimestamp } = vi.hoisted(() => {
  const store = new Map<string, Record<string, unknown>>();

  class FakeTimestamp {
    constructor(public readonly ms: number) {}
    static fromMillis(ms: number): FakeTimestamp {
      return new FakeTimestamp(ms);
    }
    toMillis(): number {
      return this.ms;
    }
  }
  const FieldValueMock = {
    serverTimestamp: () => ({ __serverTimestamp: true }),
  };

  const snapshotFor = (path: string) => {
    const data = store.get(path);
    return {
      exists: data !== undefined,
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
    limit(_n: number) {
      return this;
    },
    run() {
      const docs = [...store.entries()]
        .filter(
          ([path]) =>
            path.startsWith(`${collectionPath}/`) && path.slice(collectionPath.length + 1).indexOf("/") === -1,
        )
        .filter(([, data]) =>
          filters.every((f) => {
            const v = data[f.field];
            if (f.op === "==") return v === f.value;
            if (f.op === "in") return Array.isArray(f.value) && (f.value as unknown[]).includes(v);
            return false;
          }),
        )
        .map(([path, data]) => ({
          ...snapshotFor(path),
          id: path.split("/").pop()!,
          ref: makeDocRef(path),
          _data: data,
        }));
      return { empty: docs.length === 0, size: docs.length, docs };
    },
  });

  const makeDocRef = (path: string) => ({
    __isDoc: true as const,
    path,
    async get() {
      return snapshotFor(path);
    },
    async set(data: Record<string, unknown>) {
      store.set(path, { ...data });
    },
  });

  const dbMock = {
    doc: (path: string) => makeDocRef(path),
    collection: (path: string) => makeQuery(path, []),
    async runTransaction<T>(fn: (tx: unknown) => Promise<T>): Promise<T> {
      const tx = {
        async get(refOrQuery: { __isDoc?: true; __isQuery?: true; path?: string } & Record<string, unknown>) {
          if (refOrQuery.__isQuery) {
            return (refOrQuery as unknown as { run: () => unknown }).run();
          }
          return snapshotFor(refOrQuery.path!);
        },
        set(ref: { path: string }, data: Record<string, unknown>, _opts?: unknown) {
          const existing = store.get(ref.path) ?? {};
          store.set(ref.path, { ...existing, ...data });
        },
        update(ref: { path: string }, patch: Record<string, unknown>) {
          const existing = store.get(ref.path);
          if (!existing) throw new Error(`update on missing doc ${ref.path}`);
          store.set(ref.path, { ...existing, ...patch });
        },
      };
      return fn(tx);
    },
  };

  return { store, dbMock, FieldValueMock, FakeTimestamp };
});

vi.mock("../adminRuntime.js", () => ({ db: dbMock, auth: {} }));
vi.mock("firebase-admin/firestore", () => ({ FieldValue: FieldValueMock, Timestamp: FakeTimestamp }));

// Auth / App Check assertions are no-ops; the nonce + signature logic under test
// is driven by config + Firestore state, exercised through the real handler.
vi.mock("../auth.js", () => ({
  assertAuth: vi.fn(),
  assertAppCheck: vi.fn(),
  assertOwnership: vi.fn(),
  enforceAuthAndAppCheck: vi.fn(),
}));

const { configMock } = vi.hoisted(() => ({
  configMock: { enforceAppCheck: true, requireHighRiskNonce: false },
}));
vi.mock("../config.js", () => ({ getConfig: () => configMock }));

// Real logging is noisy; stub to keep test output clean (behavior unaffected).
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return {
    ...actual,
    logInfo: vi.fn(),
    logWarn: vi.fn(),
    // Keep wrapCallableHandler real so `.run()` exercises the true handler.
  };
});

import { approveEscrowDeviceTrust } from "../callables/computerUseSecurity.js";
import { APP_CHECK_ATTESTATION_CLAIM_KEY, issueHighRiskNonceForUid } from "../appCheckAttestation.js";

const APP_ID = "1:123:ios:abc";

// --- Ground-truth libsignal vectors (see header). ---
// Non-bootstrap: approver "phone-a" signs over target "mac-1".
const NB = {
  uid: "uidNB",
  targetDeviceId: "mac-1",
  targetEscrowFingerprint: "escrowFprNB",
  targetSignalFpr: "ekIYxeF22KsfKRuwP+mnQ3RQH6Ya8QajU0Z63UJyYEU=",
  approverDeviceId: "phone-a",
  approverPubB64: "BaykVQP5aaLIlERxbsPf8vaNpuhqyMvd2U3b4LkN79B3",
  approverFpr: "Dvi1dkT5bl35zuubRFAP515TDSpvVY9ynqCUi5Kcs0s=",
  signatureB64: "zQjSXLLwuINbgGGwzkls6QIUnFTjveV+4GCW5D9JIB9K8EW/e+165uSK40vjqk4DyM++MVk2KO7tamD9jr55BQ==",
};
// Bootstrap self-approval: device "mac-boot" signs over itself.
const BOOT = {
  uid: "uidBoot",
  deviceId: "mac-boot",
  escrowFingerprint: "escrowFprBoot",
  pubB64: "BbxcYe/I3hSleHAsAcqqV33ow1gEf1/soYf8680k5NQo",
  fpr: "BMefpUEJV+tvZSq1jm2AyaDUJHXWG8NPBDrtdtDAL3k=",
  signatureB64: "3IW40fVG9jkGPaGI4Tsc7XmNR5GfUME8LQhDijY1AGMaz1BFnSN0hPJHEjf3Tt8lWOOq1qLyw3TAzuqlLckzAA==",
};

function callRequest(uid: string, data: Record<string, unknown>) {
  return {
    auth: {
      uid,
      // Fresh App Check attestation-bound claim so `assertAppAttestBoundClaims`
      // passes and the handler reaches the nonce + signature logic under test.
      token: {
        [APP_CHECK_ATTESTATION_CLAIM_KEY]: { v: 1, appId: APP_ID, boundAtMillis: Date.now() },
      },
    },
    app: { appId: APP_ID },
    data,
    rawRequest: { headers: {} },
  } as never;
}

// Seed Firestore for the NON-BOOTSTRAP scenario: an untrusted target "mac-1" and
// a distinct already-trusted approver "phone-a", plus both published Signal
// identity docs (approver's carries the real public key bytes).
function seedNonBootstrap() {
  store.clear();
  const { uid } = NB;
  store.set(`users/${uid}/escrow_devices/${NB.targetDeviceId}`, {
    platform: "macOS",
    trustState: "pending",
    publicKeyFingerprint: NB.targetEscrowFingerprint,
    keyVersion: 1,
  });
  store.set(`users/${uid}/escrow_devices/${NB.approverDeviceId}`, {
    platform: "iOS",
    trustState: "trusted",
    keyVersion: 1,
  });
  store.set(`users/${uid}/signal_identity_public_keys/${NB.targetDeviceId}_1`, {
    deviceId: NB.targetDeviceId,
    identityKeyId: `${NB.targetDeviceId}_1`,
    keyVersion: 1,
    publicKeyFingerprint: NB.targetSignalFpr,
    publicKeyData: "irrelevant-target-bytes",
  });
  store.set(`users/${uid}/signal_identity_public_keys/${NB.approverDeviceId}_1`, {
    deviceId: NB.approverDeviceId,
    identityKeyId: `${NB.approverDeviceId}_1`,
    keyVersion: 1,
    publicKeyFingerprint: NB.approverFpr,
    publicKeyData: NB.approverPubB64,
  });
}

function nbTrustChain(signature: string) {
  return {
    version: 1,
    algorithm: "signal-identity-xeddsa-v1",
    targetSignalIdentityKeyId: `${NB.targetDeviceId}_1`,
    targetSignalIdentityPublicKeyFingerprint: NB.targetSignalFpr,
    approverSignalIdentityKeyId: `${NB.approverDeviceId}_1`,
    approverSignalIdentityPublicKeyFingerprint: NB.approverFpr,
    signature,
  };
}

// Seed Firestore for the BOOTSTRAP scenario: the FIRST device "mac-boot", no
// other trusted native device exists, self-approving.
function seedBootstrap() {
  store.clear();
  const { uid } = BOOT;
  store.set(`users/${uid}/escrow_devices/${BOOT.deviceId}`, {
    platform: "macOS",
    trustState: "pending",
    publicKeyFingerprint: BOOT.escrowFingerprint,
    keyVersion: 1,
  });
  store.set(`users/${uid}/signal_identity_public_keys/${BOOT.deviceId}_1`, {
    deviceId: BOOT.deviceId,
    identityKeyId: `${BOOT.deviceId}_1`,
    keyVersion: 1,
    publicKeyFingerprint: BOOT.fpr,
    publicKeyData: BOOT.pubB64,
  });
}

function bootTrustChain(signature: string) {
  return {
    version: 1,
    algorithm: "signal-identity-xeddsa-v1",
    targetSignalIdentityKeyId: `${BOOT.deviceId}_1`,
    targetSignalIdentityPublicKeyFingerprint: BOOT.fpr,
    approverSignalIdentityKeyId: `${BOOT.deviceId}_1`,
    approverSignalIdentityPublicKeyFingerprint: BOOT.fpr,
    signature,
  };
}

const GARBAGE_SIGNATURE = Buffer.alloc(64, 0xab).toString("base64");

beforeEach(() => {
  configMock.enforceAppCheck = true;
  configMock.requireHighRiskNonce = false;
});

describe("approveEscrowDeviceTrust — B1 signature verification", () => {
  it("REJECTS a forged/garbage trust-chain signature (non-bootstrap)", async () => {
    seedNonBootstrap();
    await expect(
      approveEscrowDeviceTrust.run(
        callRequest(NB.uid, {
          deviceId: NB.targetDeviceId,
          approverDeviceId: NB.approverDeviceId,
          trustChain: nbTrustChain(GARBAGE_SIGNATURE),
        }),
      ),
    ).rejects.toThrow(/trust-chain signature failed verification/i);
    // Device must NOT have been promoted.
    expect(store.get(`users/${NB.uid}/escrow_devices/${NB.targetDeviceId}`)?.trustState).toBe("pending");
  });

  it("ACCEPTS a genuine libsignal signature and promotes the device (non-bootstrap)", async () => {
    seedNonBootstrap();
    const result = (await approveEscrowDeviceTrust.run(
      callRequest(NB.uid, {
        deviceId: NB.targetDeviceId,
        approverDeviceId: NB.approverDeviceId,
        trustChain: nbTrustChain(NB.signatureB64),
      }),
    )) as { ok: boolean; trustState: string };
    expect(result).toMatchObject({ ok: true, trustState: "trusted" });
    const after = store.get(`users/${NB.uid}/escrow_devices/${NB.targetDeviceId}`);
    expect(after?.trustState).toBe("trusted");
    expect(after?.approvedByDeviceId).toBe(NB.approverDeviceId);
    expect(after?.trustChainSignature).toBe(NB.signatureB64);
  });

  it("REJECTS a genuine signature replayed against a tampered approverDeviceId binding", async () => {
    // The signature commits to approverDeviceId via the canonical bytes; pointing
    // the approval at a different (also-trusted) device must fail signature verify.
    seedNonBootstrap();
    store.set(`users/${NB.uid}/escrow_devices/imposter`, { platform: "iOS", trustState: "trusted", keyVersion: 1 });
    store.set(`users/${NB.uid}/signal_identity_public_keys/imposter_1`, {
      deviceId: "imposter",
      identityKeyId: "imposter_1",
      keyVersion: 1,
      publicKeyFingerprint: NB.approverFpr,
      publicKeyData: NB.approverPubB64,
    });
    await expect(
      approveEscrowDeviceTrust.run(
        callRequest(NB.uid, {
          deviceId: NB.targetDeviceId,
          approverDeviceId: "imposter",
          trustChain: {
            ...nbTrustChain(NB.signatureB64),
            approverSignalIdentityKeyId: "imposter_1",
          },
        }),
      ),
    ).rejects.toThrow(/trust-chain signature failed verification/i);
  });
});

describe("approveEscrowDeviceTrust — B2 bootstrap nonce hardening", () => {
  it("REJECTS bootstrap self-approval WITHOUT a nonce (flag off, App Check enforced)", async () => {
    seedBootstrap();
    configMock.requireHighRiskNonce = false; // global flag still off
    await expect(
      approveEscrowDeviceTrust.run(
        callRequest(BOOT.uid, {
          deviceId: BOOT.deviceId,
          trustChain: bootTrustChain(BOOT.signatureB64),
          // no nonce supplied
        }),
      ),
    ).rejects.toThrow(/bootstrap self-approval .* requires a fresh single-use nonce/i);
    expect(store.get(`users/${BOOT.uid}/escrow_devices/${BOOT.deviceId}`)?.trustState).toBe("pending");
  });

  it("ACCEPTS bootstrap self-approval WITH a valid single-use nonce + genuine signature", async () => {
    seedBootstrap();
    const { nonce } = await issueHighRiskNonceForUid(BOOT.uid, Date.now());
    const result = (await approveEscrowDeviceTrust.run(
      callRequest(BOOT.uid, {
        deviceId: BOOT.deviceId,
        trustChain: bootTrustChain(BOOT.signatureB64),
        nonce,
      }),
    )) as { ok: boolean; trustState: string };
    expect(result).toMatchObject({ ok: true, trustState: "trusted" });
    expect(store.get(`users/${BOOT.uid}/escrow_devices/${BOOT.deviceId}`)?.trustState).toBe("trusted");
  });

  it("REJECTS bootstrap self-approval with a valid nonce but a FORGED signature", async () => {
    seedBootstrap();
    const { nonce } = await issueHighRiskNonceForUid(BOOT.uid, Date.now());
    await expect(
      approveEscrowDeviceTrust.run(
        callRequest(BOOT.uid, {
          deviceId: BOOT.deviceId,
          trustChain: bootTrustChain(GARBAGE_SIGNATURE),
          nonce,
        }),
      ),
    ).rejects.toThrow(/trust-chain signature failed verification/i);
  });
});
