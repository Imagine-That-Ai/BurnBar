/**
 * F-MD08-006 — requireTrustedDeviceActionProof binds proof to the acting
 * device's targetSignalIdentityKeyId (not the Mac approver key).
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

const store = new Map<string, Record<string, unknown>>();

function snapFor(path: string) {
  return {
    exists: store.has(path),
    get: (field: string) => store.get(path)?.[field],
    data: () => store.get(path),
  };
}

vi.mock("../adminRuntime.js", () => ({
  db: {
    doc: (path: string) => ({
      get: async () => snapFor(path),
    }),
  },
  auth: {},
}));

import { __testing__ } from "../callables/computerUseSecurity.js";

const { requireTrustedDeviceActionProof } = __testing__;

const UID = "user-1";
const PHONE_DEVICE_ID = "phone-1";
const PHONE_IDENTITY_ID = "phone-1_1";
const PHONE_FINGERPRINT = "phone-fingerprint";
const MAC_IDENTITY_ID = "mac-1_1";
const NOW = 1_718_000_000_000;

function seedPhoneApprovedByMac() {
  store.set(`users/${UID}/escrow_devices/${PHONE_DEVICE_ID}`, {
    trustState: "trusted",
    platform: "ios",
    targetSignalIdentityKeyId: PHONE_IDENTITY_ID,
    targetSignalIdentityPublicKeyFingerprint: PHONE_FINGERPRINT,
    approvedBySignalIdentityKeyId: MAC_IDENTITY_ID,
    keyVersion: 1,
  });
  store.set(`users/${UID}/signal_identity_public_keys/${PHONE_IDENTITY_ID}`, {
    deviceId: PHONE_DEVICE_ID,
    identityKeyId: PHONE_IDENTITY_ID,
    publicKeyFingerprint: PHONE_FINGERPRINT,
    publicKeyData: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    keyVersion: 1,
  });
}

function proofFor(identityKeyId: string, fingerprint: string) {
  return {
    version: 1,
    algorithm: "signal-identity-xeddsa-v1",
    deviceSignalIdentityKeyId: identityKeyId,
    deviceSignalIdentityPublicKeyFingerprint: fingerprint,
    issuedAtMillis: NOW,
    signature: Buffer.alloc(64, 0x11).toString("base64"),
  };
}

describe("requireTrustedDeviceActionProof identity binding", () => {
  beforeEach(() => {
    store.clear();
    seedPhoneApprovedByMac();
  });

  it("rejects proofs bound to the Mac approver identity instead of the phone target", async () => {
    await expect(
      requireTrustedDeviceActionProof({
        uid: UID,
        deviceId: PHONE_DEVICE_ID,
        actionKind: "computer_use_mission_approval",
        subjectId: "mission-1",
        approve: true,
        nonce: "nonce-1",
        proofRaw: proofFor(MAC_IDENTITY_ID, PHONE_FINGERPRINT),
        allowedPlatforms: new Set(["ios", "android"]),
        nowMillis: NOW,
      }),
    ).rejects.toMatchObject({
      code: "permission-denied",
      message: "actionProof is not bound to the trusted device identity.",
    });
  });

  it("accepts proofs bound to the phone target identity before signature verification", async () => {
    await expect(
      requireTrustedDeviceActionProof({
        uid: UID,
        deviceId: PHONE_DEVICE_ID,
        actionKind: "computer_use_mission_approval",
        subjectId: "mission-1",
        approve: true,
        nonce: "nonce-1",
        proofRaw: proofFor(PHONE_IDENTITY_ID, PHONE_FINGERPRINT),
        allowedPlatforms: new Set(["ios", "android"]),
        nowMillis: NOW,
      }),
    ).rejects.toMatchObject({
      code: "permission-denied",
      message: "actionProof signature is invalid.",
    });
  });
});
