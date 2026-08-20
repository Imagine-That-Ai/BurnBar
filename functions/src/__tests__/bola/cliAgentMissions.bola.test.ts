/**
 * BOLA negative coverage — cli_agent_mission_requests object ownership.
 */

import { describe, it, vi } from "vitest";
import { callableRunner, pathKeyedFirestore, tier2CallableProof } from "./callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map());
vi.mock("../../adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));
vi.mock("../../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
}));
vi.mock("../../callables/highRiskOwnerAction.js", () => ({
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));
vi.mock("../../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../../callables/shared.js")>("../../callables/shared.js");
  return { ...actual, assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined) };
});
vi.mock("../../appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
}));
vi.mock("../../callables/computerUseSecurityFirestore.js", () => ({
  requireTrustedDeviceActionProof: vi.fn(async () => ({
    deviceId: "dev",
    platform: "iOS",
    signalIdentityKeyId: "s",
  })),
}));
vi.mock("../../callables/publicRateLimit.js", () => ({
  checkMissionCreateRateLimit: vi.fn(async () => undefined),
  recordCallableApprovalFailure: vi.fn(async () => undefined),
  assertCallableApprovalNotLocked: vi.fn(async () => undefined),
}));

export const BOLA_MANIFEST = {
  createCliAgentMission: ["createCliAgentMission rejects cross-user object access"],
  cancelCliAgentMission: ["cancelCliAgentMission rejects cross-user object access"],
  claimCliAgentMission: ["claimCliAgentMission rejects cross-user object access"],
  appendCliAgentMissionEvent: ["appendCliAgentMissionEvent rejects cross-user object access"],
  updateCliAgentMissionStatus: ["updateCliAgentMissionStatus rejects cross-user object access"],
} as const;

describe("BOLA — cliAgentMissions", () => {
  it("createCliAgentMission rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliAgentMissions.js");
    const run = callableRunner(mod.createCliAgentMission);
    await tier2CallableProof(bolaStore, {
      exportedName: "createCliAgentMission",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });

  it("cancelCliAgentMission rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliAgentMissions.js");
    const run = callableRunner(mod.cancelCliAgentMission);
    await tier2CallableProof(bolaStore, {
      exportedName: "cancelCliAgentMission",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });

  it("claimCliAgentMission rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliAgentMissions.js");
    const run = callableRunner(mod.claimCliAgentMission);
    await tier2CallableProof(bolaStore, {
      exportedName: "claimCliAgentMission",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });

  it("appendCliAgentMissionEvent rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliAgentMissions.js");
    const run = callableRunner(mod.appendCliAgentMissionEvent);
    await tier2CallableProof(bolaStore, {
      exportedName: "appendCliAgentMissionEvent",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });

  it("updateCliAgentMissionStatus rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliAgentMissions.js");
    const run = callableRunner(mod.updateCliAgentMissionStatus);
    await tier2CallableProof(bolaStore, {
      exportedName: "updateCliAgentMissionStatus",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });
});
