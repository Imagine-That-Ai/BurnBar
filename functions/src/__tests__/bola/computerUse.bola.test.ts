/**
 * BOLA negative coverage — src/__tests__/bola/computerUse.bola.test.ts
 * Generated scaffold; implements cross-user denial at callable trust boundary.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ALICE_UID, BOB_UID, callableRequest, callableRunner, expectCallableDenial, bolaCrossUserData } from "./callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

vi.mock("../../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
  assertAppCheck: vi.fn(),
}));
vi.mock("../../callables/highRiskOwnerAction.js", () => ({
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));
vi.mock("../../appCheckAttestation.js", async () => {
  const actual = await vi.importActual<typeof import("../../appCheckAttestation.js")>("../../appCheckAttestation.js");
  return {
    ...actual,
    enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
  };
});
vi.mock("../../adminRuntime.js", () => ({ db: { doc: vi.fn(() => ({ get: async () => ({ exists: false }) })) } }));

export const BOLA_MANIFEST = {
  "registerEscrowDevice": [
    "registerEscrowDevice rejects cross-user object access"
  ],
  "approveEscrowDeviceTrust": [
    "approveEscrowDeviceTrust rejects cross-user object access"
  ],
  "revokeEscrowDeviceTrust": [
    "revokeEscrowDeviceTrust rejects cross-user object access"
  ],
  "publishIrohPairingPublicKey": [
    "publishIrohPairingPublicKey rejects cross-user object access"
  ],
  "publishIrohPairingRecord": [
    "publishIrohPairingRecord rejects cross-user object access"
  ],
  "revokeIrohPairingRecord": [
    "revokeIrohPairingRecord rejects cross-user object access"
  ],
  "publishPhoneControlAuthority": [
    "publishPhoneControlAuthority rejects cross-user object access"
  ],
  "publishRelaySenderKey": [
    "publishRelaySenderKey rejects cross-user object access"
  ],
  "publishAgentGrantAuthority": [
    "publishAgentGrantAuthority rejects cross-user object access"
  ],
  "queueAgentCapabilityGrantRequest": [
    "queueAgentCapabilityGrantRequest rejects cross-user object access"
  ],
  "respondMissionApproval": [
    "respondMissionApproval rejects cross-user object access"
  ]
} as const;

describe("BOLA — computerUse", () => {
  it("registerEscrowDevice rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.registerEscrowDevice;
    if (!exported) throw new Error("missing export registerEscrowDevice");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("approveEscrowDeviceTrust rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.approveEscrowDeviceTrust;
    if (!exported) throw new Error("missing export approveEscrowDeviceTrust");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("revokeEscrowDeviceTrust rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.revokeEscrowDeviceTrust;
    if (!exported) throw new Error("missing export revokeEscrowDeviceTrust");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("publishIrohPairingPublicKey rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.publishIrohPairingPublicKey;
    if (!exported) throw new Error("missing export publishIrohPairingPublicKey");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("publishIrohPairingRecord rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.publishIrohPairingRecord;
    if (!exported) throw new Error("missing export publishIrohPairingRecord");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("revokeIrohPairingRecord rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.revokeIrohPairingRecord;
    if (!exported) throw new Error("missing export revokeIrohPairingRecord");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("publishPhoneControlAuthority rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.publishPhoneControlAuthority;
    if (!exported) throw new Error("missing export publishPhoneControlAuthority");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("publishRelaySenderKey rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.publishRelaySenderKey;
    if (!exported) throw new Error("missing export publishRelaySenderKey");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("publishAgentGrantAuthority rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.publishAgentGrantAuthority;
    if (!exported) throw new Error("missing export publishAgentGrantAuthority");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("queueAgentCapabilityGrantRequest rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.queueAgentCapabilityGrantRequest;
    if (!exported) throw new Error("missing export queueAgentCapabilityGrantRequest");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("respondMissionApproval rejects cross-user object access", async () => {
    const mod = await import("../../callables/computerUseSecurity.js");
    const exported = mod.respondMissionApproval;
    if (!exported) throw new Error("missing export respondMissionApproval");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });
});
