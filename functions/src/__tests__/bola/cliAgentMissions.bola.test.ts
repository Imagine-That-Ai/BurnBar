/**
 * BOLA negative coverage — cli_agent_mission_requests object ownership.
 */

import { describe, it, vi } from "vitest";
import { cloudVaultAADContext } from "../../callables/shared/validators.js";
import { ALICE_UID, callableRunner, pathKeyedFirestore, tier2CallableProof } from "./callableBolaHarness.js";

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

const VAULT = `v1_${"ab".repeat(16)}`;

function createGroupProbe(): Record<string, unknown> {
  const sealedPayload = {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    vaultKeyID: VAULT,
    sealedBoxBase64: Buffer.from("sealed-box").toString("base64"),
    aad: cloudVaultAADContext(ALICE_UID, "mission_groups", "bob-group", "sealedPayload"),
  };
  return {
    groupId: "bob-group",
    deviceId: "bob-device",
    nonce: "bola-test-nonce",
    actionProof: { nonce: "bola-action-proof", signature: "YQ==" },
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: VAULT,
    sealedPayload,
    childMissionIDs: ["child-1"],
    runtimeTokens: ["codex"],
    parallelismLimit: 1,
    missionKind: "diligence",
    mergeStrategy: "pick_one",
    phase: "queued",
    schemaVersion: 1,
    source: "ios-hermes-square",
  };
}

export const BOLA_MANIFEST = {
  createCliAgentMission: ["createCliAgentMission rejects cross-user object access"],
  createCliAgentMissionGroup: ["createCliAgentMissionGroup rejects cross-user object access"],
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
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("createCliAgentMissionGroup rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliAgentMissions.js");
    const run = callableRunner(mod.createCliAgentMissionGroup);
    await tier2CallableProof(bolaStore, {
      exportedName: "createCliAgentMissionGroup",
      run,
      payload: createGroupProbe(),
      expectedOutcome: "no-side-effect",
    });
  });

  it("cancelCliAgentMission rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliAgentMissions.js");
    const run = callableRunner(mod.cancelCliAgentMission);
    await tier2CallableProof(bolaStore, {
      exportedName: "cancelCliAgentMission",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("claimCliAgentMission rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliAgentMissions.js");
    const run = callableRunner(mod.claimCliAgentMission);
    await tier2CallableProof(bolaStore, {
      exportedName: "claimCliAgentMission",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("appendCliAgentMissionEvent rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliAgentMissions.js");
    const run = callableRunner(mod.appendCliAgentMissionEvent);
    await tier2CallableProof(bolaStore, {
      exportedName: "appendCliAgentMissionEvent",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("updateCliAgentMissionStatus rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliAgentMissions.js");
    const run = callableRunner(mod.updateCliAgentMissionStatus);
    await tier2CallableProof(bolaStore, {
      exportedName: "updateCliAgentMissionStatus",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });
});
