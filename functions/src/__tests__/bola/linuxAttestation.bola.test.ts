import { createHash } from "node:crypto";

import { describe, expect, it, vi } from "vitest";

import {
  ALICE_UID,
  BOB_UID,
  callableRequest,
  callableRunner,
  expectTenantPathsUnchanged,
  pathKeyedFirestore,
  seedDoc,
  snapshotTenantPaths,
} from "./callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map<string, Record<string, unknown>>());
vi.mock("../../adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore), auth: {} }));
vi.mock("../../callables/highRiskOwnerAction.js", () => ({
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));

export const BOLA_MANIFEST = {
  revokeLinuxAttestationEnrollment: ["revokeLinuxAttestationEnrollment rejects cross-user object access"],
} as const;

const DEVICE_ID = `ak-sha256:${"a".repeat(64)}`;

function enrollmentPath(uid: string): string {
  const id = createHash("sha256").update([uid, DEVICE_ID].join("\n")).digest("hex");
  return `linux_attestation_enrollments/${id}`;
}

describe("BOLA - Linux attestation administration", () => {
  it("revokeLinuxAttestationEnrollment rejects cross-user object access", async () => {
    bolaStore.clear();
    seedDoc(bolaStore, enrollmentPath(BOB_UID), {
      uid: BOB_UID,
      deviceId: DEVICE_ID,
      agentId: "bob-agent",
      akTpmBase64: "Ym9iLWFr",
      ekTpmBase64: "Ym9iLWVr",
      ekCertificateBase64: "Ym9iLWNlcnQ=",
      tpmEkPem: "bob-ek-pem",
      active: true,
    });
    const bobBefore = snapshotTenantPaths(bolaStore, BOB_UID);

    const mod = await import("../../callables/linuxAttestationAdmin.js");
    const run = callableRunner(mod.revokeLinuxAttestationEnrollment);
    await run(callableRequest(ALICE_UID, {
      deviceId: DEVICE_ID,
      reason: "suspected_compromise",
      trustedDeviceId: "alice-phone",
      nonce: "alice-nonce",
      actionProof: { signature: "alice-proof" },
    }));

    expectTenantPathsUnchanged(bolaStore, bobBefore);
    expect(bolaStore.get(enrollmentPath(BOB_UID))?.active).toBe(true);
    expect(bolaStore.get(enrollmentPath(ALICE_UID))).toEqual(expect.objectContaining({
      uid: ALICE_UID,
      deviceId: DEVICE_ID,
      active: false,
    }));
  });
});
