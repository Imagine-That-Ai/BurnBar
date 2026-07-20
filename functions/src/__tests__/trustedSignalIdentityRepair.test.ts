import { createDecipheriv, createECDH, createHash, hkdfSync, randomBytes } from "node:crypto";

import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CallableRequest } from "firebase-functions/v2/https";

const { store, dbMock, FieldValueMock, FakeTimestamp } = vi.hoisted(() => {
  const store = new Map<string, Record<string, unknown>>();

  class FakeTimestamp {
    constructor(readonly millis: number) {}
    static fromMillis(millis: number): FakeTimestamp {
      return new FakeTimestamp(millis);
    }
    toMillis(): number {
      return this.millis;
    }
  }

  const deleteSentinel = { __delete: true };
  const FieldValueMock = {
    serverTimestamp: () => ({ __serverTimestamp: true }),
    delete: () => deleteSentinel,
  };

  const mergeFields = (existing: Record<string, unknown>, data: Record<string, unknown>) => {
    const merged = { ...existing };
    for (const [key, value] of Object.entries(data)) {
      if (value === deleteSentinel) delete merged[key];
      else merged[key] = value;
    }
    return merged;
  };

  const snapshotFor = (path: string) => {
    const data = store.get(path);
    return {
      exists: data !== undefined,
      data: () => data,
      get: (field: string) => data?.[field],
    };
  };

  const docRef = (path: string) => ({
    path,
    async get() {
      return snapshotFor(path);
    },
    async create(data: Record<string, unknown>) {
      if (store.has(path)) throw new Error(`document already exists: ${path}`);
      store.set(path, { ...data });
    },
  });

  const dbMock = {
    doc: (path: string) => docRef(path),
    async runTransaction<T>(operation: (transaction: unknown) => Promise<T>): Promise<T> {
      const transaction = {
        async get(ref: { path: string }) {
          return snapshotFor(ref.path);
        },
        create(ref: { path: string }, data: Record<string, unknown>) {
          if (store.has(ref.path)) throw new Error(`document already exists: ${ref.path}`);
          store.set(ref.path, { ...data });
        },
        set(ref: { path: string }, data: Record<string, unknown>) {
          store.set(ref.path, mergeFields(store.get(ref.path) ?? {}, data));
        },
        update(ref: { path: string }, data: Record<string, unknown>) {
          const existing = store.get(ref.path);
          if (!existing) throw new Error(`update on missing document: ${ref.path}`);
          store.set(ref.path, { ...existing, ...data });
        },
      };
      return operation(transaction);
    },
  };

  return { store, dbMock, FieldValueMock, FakeTimestamp };
});

vi.mock("../adminRuntime.js", () => ({ db: dbMock, auth: {} }));
vi.mock("firebase-admin/firestore", () => ({ FieldValue: FieldValueMock, Timestamp: FakeTimestamp }));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));
vi.mock("../appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
}));
vi.mock("../config.js", () => ({
  getConfig: () => ({ enforceAppCheck: true }),
}));
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: vi.fn() };
});

import {
  issueTrustedSignalIdentityRepairChallenge,
  repairTrustedSignalIdentity,
  signalIdentityRepairChallengeAAD,
} from "../callables/signalIdentityRepair.js";

const UID = "legacy-user";
const DEVICE_ID = "legacy-ipad";
const KEY_VERSION = 1;

function request<T>(uid: string, data: T): CallableRequest<T> {
  return {
    auth: { uid, token: {} },
    app: { appId: "1:test:ios:app" },
    data,
    rawRequest: { headers: {} },
    acceptsStreaming: false,
  } as unknown as CallableRequest<T>;
}

function seedTrustedLegacyDevice(uid = UID, deviceId = DEVICE_ID) {
  const keypair = createECDH("prime256v1");
  keypair.generateKeys();
  const publicKey = keypair.getPublicKey(undefined, "uncompressed");
  const fingerprint = createHash("sha256").update(publicKey).digest("base64");
  store.set(`users/${uid}/escrow_devices/${deviceId}`, {
    deviceId,
    platform: "iPadOS",
    trustState: "trusted",
    keyVersion: KEY_VERSION,
    publicKeyFingerprint: fingerprint,
  });
  store.set(`users/${uid}/escrow_public_keys/${deviceId}_${KEY_VERSION}`, {
    deviceId,
    platform: "iPadOS",
    keyVersion: KEY_VERSION,
    publicKeyFingerprint: fingerprint,
    publicKeyData: publicKey.toString("base64"),
    algorithm: "ECIES-P256-AESGCM",
  });
  return keypair;
}

function decryptChallenge(
  ciphertextBase64: string,
  keypair: ReturnType<typeof createECDH>,
  uid: string,
  deviceId: string,
  challengeId: string,
): Buffer {
  const wire = Buffer.from(ciphertextBase64, "base64");
  const ephemeralPublicKey = wire.subarray(0, 65);
  const combined = wire.subarray(65);
  const nonce = combined.subarray(0, 12);
  const ciphertext = combined.subarray(12, combined.length - 16);
  const tag = combined.subarray(combined.length - 16);
  const sharedSecret = keypair.computeSecret(ephemeralPublicKey);
  const key = Buffer.from(
    hkdfSync("sha256", sharedSecret, Buffer.alloc(0), Buffer.from("OpenBurnBar-Escrow-v1", "utf8"), 32),
  );
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(signalIdentityRepairChallengeAAD(uid, deviceId, challengeId));
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

function signalIdentity() {
  const publicKey = Buffer.concat([Buffer.from([0x05]), randomBytes(32)]);
  return {
    identityKeyId: `${DEVICE_ID}_${KEY_VERSION}`,
    publicKeyData: publicKey.toString("base64"),
    publicKeyFingerprint: createHash("sha256").update(publicKey).digest("base64"),
    keyVersion: KEY_VERSION,
  };
}

async function issueChallenge(keypair: ReturnType<typeof createECDH>) {
  const issued = await issueTrustedSignalIdentityRepairChallenge.run(request(UID, { deviceId: DEVICE_ID }));
  const plaintext = decryptChallenge(issued.challengeCiphertextBase64, keypair, UID, DEVICE_ID, issued.challengeId);
  return { issued, plaintext };
}

describe("trusted legacy Signal identity repair", () => {
  beforeEach(() => {
    store.clear();
  });

  it("repairs the missing identity only after the legacy device decrypts its one-time challenge", async () => {
    const escrowKeypair = seedTrustedLegacyDevice();
    const { issued, plaintext } = await issueChallenge(escrowKeypair);
    const identity = signalIdentity();

    const result = await repairTrustedSignalIdentity.run(
      request(UID, {
        deviceId: DEVICE_ID,
        challengeId: issued.challengeId,
        challengePlaintextBase64: plaintext.toString("base64"),
        ...identity,
        nonce: "single-use-nonce",
      }),
    );

    expect(result).toMatchObject({
      ok: true,
      deviceId: DEVICE_ID,
      repaired: true,
      reapprovalRequired: true,
    });
    expect(store.get(`users/${UID}/signal_identity_public_keys/${identity.identityKeyId}`)).toMatchObject({
      deviceId: DEVICE_ID,
      platform: "iPadOS",
      ...identity,
      algorithm: "signal-hpke-identity-seal-v1",
    });
    expect(store.get(`users/${UID}/escrow_devices/${DEVICE_ID}`)).toMatchObject({
      trustState: "pending",
      targetSignalIdentityKeyId: identity.identityKeyId,
      targetSignalIdentityPublicKeyFingerprint: identity.publicKeyFingerprint,
      signalIdentityRepairAlgorithm: "escrow-possession-challenge-v1",
      signalIdentityReapprovalRequired: true,
    });
    expect(store.get(`users/${UID}/signal_identity_repair_challenges/${issued.challengeId}`)?.consumedAt).toBeDefined();
  });

  it("clears stale approval fields so a trusted Mac can sign the repaired identity", async () => {
    const escrowKeypair = seedTrustedLegacyDevice();
    store.set(`users/${UID}/escrow_devices/${DEVICE_ID}`, {
      ...store.get(`users/${UID}/escrow_devices/${DEVICE_ID}`),
      approvedAt: "old-approval",
      approvedByDeviceId: "trusted-mac",
      approvedBySignalIdentityKeyId: "old-signal-key",
      approvedBySignalIdentityPublicKeyFingerprint: "old-signal-fingerprint",
      trustChainVersion: 1,
      trustChainAlgorithm: "signal-xeddsa-sha256-v1",
      trustChainSignature: "old-signature",
    });
    const { issued, plaintext } = await issueChallenge(escrowKeypair);
    const identity = signalIdentity();

    await repairTrustedSignalIdentity.run(
      request(UID, {
        deviceId: DEVICE_ID,
        challengeId: issued.challengeId,
        challengePlaintextBase64: plaintext.toString("base64"),
        ...identity,
        nonce: "single-use-nonce",
      }),
    );

    const repairedDevice = store.get(`users/${UID}/escrow_devices/${DEVICE_ID}`);
    expect(repairedDevice).not.toHaveProperty("approvedAt");
    expect(repairedDevice).not.toHaveProperty("approvedByDeviceId");
    expect(repairedDevice).not.toHaveProperty("approvedBySignalIdentityKeyId");
    expect(repairedDevice).not.toHaveProperty("approvedBySignalIdentityPublicKeyFingerprint");
    expect(repairedDevice).not.toHaveProperty("trustChainVersion");
    expect(repairedDevice).not.toHaveProperty("trustChainAlgorithm");
    expect(repairedDevice).not.toHaveProperty("trustChainSignature");
  });

  it("rejects a replay of the consumed challenge", async () => {
    const escrowKeypair = seedTrustedLegacyDevice();
    const { issued, plaintext } = await issueChallenge(escrowKeypair);
    const payload = {
      deviceId: DEVICE_ID,
      challengeId: issued.challengeId,
      challengePlaintextBase64: plaintext.toString("base64"),
      ...signalIdentity(),
      nonce: "single-use-nonce",
    };

    await repairTrustedSignalIdentity.run(request(UID, payload));
    await expect(repairTrustedSignalIdentity.run(request(UID, payload))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });

  it("rejects a forged challenge plaintext and leaves the identity missing", async () => {
    const escrowKeypair = seedTrustedLegacyDevice();
    const { issued } = await issueChallenge(escrowKeypair);
    const identity = signalIdentity();

    await expect(
      repairTrustedSignalIdentity.run(
        request(UID, {
          deviceId: DEVICE_ID,
          challengeId: issued.challengeId,
          challengePlaintextBase64: randomBytes(32).toString("base64"),
          ...identity,
          nonce: "single-use-nonce",
        }),
      ),
    ).rejects.toMatchObject({ code: "permission-denied" });
    expect(store.has(`users/${UID}/signal_identity_public_keys/${identity.identityKeyId}`)).toBe(false);
  });

  it("does not issue a challenge for an untrusted device or another user's device", async () => {
    seedTrustedLegacyDevice();
    store.set(`users/${UID}/escrow_devices/${DEVICE_ID}`, {
      ...store.get(`users/${UID}/escrow_devices/${DEVICE_ID}`),
      trustState: "pending",
    });
    await expect(
      issueTrustedSignalIdentityRepairChallenge.run(request(UID, { deviceId: DEVICE_ID })),
    ).rejects.toMatchObject({ code: "permission-denied" });

    store.clear();
    seedTrustedLegacyDevice("victim", DEVICE_ID);
    await expect(
      issueTrustedSignalIdentityRepairChallenge.run(request("attacker", { deviceId: DEVICE_ID })),
    ).rejects.toMatchObject({ code: "permission-denied" });
  });

  it("never overwrites a conflicting existing identity", async () => {
    const escrowKeypair = seedTrustedLegacyDevice();
    const { issued, plaintext } = await issueChallenge(escrowKeypair);
    const identity = signalIdentity();
    const path = `users/${UID}/signal_identity_public_keys/${identity.identityKeyId}`;
    store.set(path, {
      deviceId: DEVICE_ID,
      platform: "iPadOS",
      ...identity,
      publicKeyData: Buffer.concat([Buffer.from([0x05]), randomBytes(32)]).toString("base64"),
      algorithm: "signal-hpke-identity-seal-v1",
    });
    const before = { ...store.get(path) };

    await expect(
      repairTrustedSignalIdentity.run(
        request(UID, {
          deviceId: DEVICE_ID,
          challengeId: issued.challengeId,
          challengePlaintextBase64: plaintext.toString("base64"),
          ...identity,
          nonce: "single-use-nonce",
        }),
      ),
    ).rejects.toMatchObject({ code: "already-exists" });
    expect(store.get(path)).toEqual(before);
  });

  it("rejects the repair if the trusted device changes after challenge issuance", async () => {
    const escrowKeypair = seedTrustedLegacyDevice();
    const { issued, plaintext } = await issueChallenge(escrowKeypair);
    store.set(`users/${UID}/escrow_devices/${DEVICE_ID}`, {
      ...store.get(`users/${UID}/escrow_devices/${DEVICE_ID}`),
      keyVersion: 2,
    });

    await expect(
      repairTrustedSignalIdentity.run(
        request(UID, {
          deviceId: DEVICE_ID,
          challengeId: issued.challengeId,
          challengePlaintextBase64: plaintext.toString("base64"),
          ...signalIdentity(),
          nonce: "single-use-nonce",
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
  });
});
