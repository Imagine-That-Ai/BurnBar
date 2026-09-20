/**
 * BOLA negative coverage — src/__tests__/bola/computerUse.bola.test.ts
 * Generated scaffold; implements cross-user denial at callable trust boundary.
 */

import { createHash } from "node:crypto";

import { describe, it, vi } from "vitest";
import { callableRunner, pathKeyedFirestore, tier2CallableProof } from "./callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map());
vi.mock("../../adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));
vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(bolaStore),
  };
});

vi.mock("../../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
  assertAppCheck: vi.fn(),
}));
vi.mock("../../callables/highRiskOwnerAction.js", () => ({
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));
vi.mock("../../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../../callables/shared.js")>("../../callables/shared.js");
  return {
    ...actual,
    assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined),
  };
});
vi.mock("../../appCheckAttestation.js", async () => {
  const actual = await vi.importActual<typeof import("../../appCheckAttestation.js")>("../../appCheckAttestation.js");
  return {
    ...actual,
    enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
  };
});
export const BOLA_MANIFEST = {
  registerEscrowDevice: ["registerEscrowDevice rejects cross-user object access"],
  approveEscrowDeviceTrust: ["approveEscrowDeviceTrust rejects cross-user object access"],
  revokeEscrowDeviceTrust: ["revokeEscrowDeviceTrust rejects cross-user object access"],
  publishIrohPairingPublicKey: ["publishIrohPairingPublicKey rejects cross-user object access"],
  publishIrohPairingRecord: ["publishIrohPairingRecord rejects cross-user object access"],
  revokeIrohPairingRecord: ["revokeIrohPairingRecord rejects cross-user object access"],
  publishPhoneControlAuthority: ["publishPhoneControlAuthority rejects cross-user object access"],
  publishRelaySenderKey: ["publishRelaySenderKey rejects cross-user object access"],
  publishAgentGrantAuthority: ["publishAgentGrantAuthority rejects cross-user object access"],
  queueAgentCapabilityGrantRequest: ["queueAgentCapabilityGrantRequest rejects cross-user object access"],
  respondMissionApproval: ["respondMissionApproval rejects cross-user object access"],
  issueTrustedSignalIdentityRepairChallenge: [
    "issueTrustedSignalIdentityRepairChallenge rejects cross-user object access",
  ],
  repairTrustedSignalIdentity: ["repairTrustedSignalIdentity rejects cross-user object access"],
} as const;

describe("BOLA — computerUse", () => {
  it("registerEscrowDevice rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.registerEscrowDevice;
    if (!exported) throw new Error("missing export registerEscrowDevice");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "registerEscrowDevice",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("approveEscrowDeviceTrust rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.approveEscrowDeviceTrust;
    if (!exported) throw new Error("missing export approveEscrowDeviceTrust");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "approveEscrowDeviceTrust",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("revokeEscrowDeviceTrust rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.revokeEscrowDeviceTrust;
    if (!exported) throw new Error("missing export revokeEscrowDeviceTrust");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "revokeEscrowDeviceTrust",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });

  it("publishIrohPairingPublicKey rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.publishIrohPairingPublicKey;
    if (!exported) throw new Error("missing export publishIrohPairingPublicKey");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "publishIrohPairingPublicKey",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("publishIrohPairingRecord rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.publishIrohPairingRecord;
    if (!exported) throw new Error("missing export publishIrohPairingRecord");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "publishIrohPairingRecord",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("revokeIrohPairingRecord rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.revokeIrohPairingRecord;
    if (!exported) throw new Error("missing export revokeIrohPairingRecord");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "revokeIrohPairingRecord",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("publishPhoneControlAuthority rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.publishPhoneControlAuthority;
    if (!exported) throw new Error("missing export publishPhoneControlAuthority");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "publishPhoneControlAuthority",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("publishRelaySenderKey rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.publishRelaySenderKey;
    if (!exported) throw new Error("missing export publishRelaySenderKey");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "publishRelaySenderKey",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("publishAgentGrantAuthority rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.publishAgentGrantAuthority;
    if (!exported) throw new Error("missing export publishAgentGrantAuthority");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "publishAgentGrantAuthority",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("queueAgentCapabilityGrantRequest rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.queueAgentCapabilityGrantRequest;
    if (!exported) throw new Error("missing export queueAgentCapabilityGrantRequest");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "queueAgentCapabilityGrantRequest",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("respondMissionApproval rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.respondMissionApproval;
    if (!exported) throw new Error("missing export respondMissionApproval");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "respondMissionApproval",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("issueTrustedSignalIdentityRepairChallenge rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalIdentityRepair.js");
    const run = callableRunner(mod.issueTrustedSignalIdentityRepairChallenge);

    await tier2CallableProof(bolaStore, {
      exportedName: "issueTrustedSignalIdentityRepairChallenge",
      run,
      payload: { deviceId: "bob-device" },
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("repairTrustedSignalIdentity rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalIdentityRepair.js");
    const run = callableRunner(mod.repairTrustedSignalIdentity);
    const signalPublicKey = Buffer.concat([Buffer.from([0x05]), Buffer.alloc(32, 0x42)]);

    await tier2CallableProof(bolaStore, {
      exportedName: "repairTrustedSignalIdentity",
      run,
      payload: {
        deviceId: "bob-device",
        challengeId: "bob-challenge",
        challengePlaintextBase64: Buffer.alloc(32, 0x24).toString("base64"),
        identityKeyId: "bob-device_1",
        publicKeyData: signalPublicKey.toString("base64"),
        publicKeyFingerprint: createHash("sha256").update(signalPublicKey).digest("base64"),
        keyVersion: 1,
        nonce: "bola-test-nonce",
      },
      expectedCode: "failed-precondition",
      expectedOutcome: "throws",
    });
  });
});
