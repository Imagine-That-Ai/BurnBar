/**
 * BOLA negative coverage — cli_agent_mission_requests / mission_groups object ownership.
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

export const BOLA_MANIFEST = {
  createCliAgentMission: ["createCliAgentMission rejects cross-user object access"],
  createCliAgentMissionGroup: ["createCliAgentMissionGroup rejects cross-user object access"],
  cancelCliAgentMission: ["cancelCliAgentMission rejects cross-user object access"],
  claimCliAgentMission: ["claimCliAgentMission rejects cross-user object access"],
  appendCliAgentMissionEvent: ["appendCliAgentMissionEvent rejects cross-user object access"],
  updateCliAgentMissionStatus: ["updateCliAgentMissionStatus rejects cross-user object access"],
} as const;

const VAULT = `v1_${"ab".repeat(16)}`;

function sealed(collection: string, docId: string, field = "sealedPayload") {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    vaultKeyID: VAULT,
    sealedBoxBase64: Buffer.from("sealed-box").toString("base64"),
    aad: cloudVaultAADContext(ALICE_UID, collection, docId, field),
  };
}

function createMissionProbe(): Record<string, unknown> {
  return {
    requestId: "bob-request",
    remoteCommandID: "bob-remote-cmd",
    deviceId: "bob-device",
    nonce: "bola-test-nonce",
    actionProof: { nonce: "bola-action-proof", signature: "YQ==" },
    publicFields: { missionKind: "chat", requestedRuntime: "codex", source: "ios", schemaVersion: 2 },
    sealedPayload: sealed("cli_agent_mission_requests", "bob-request"),
    initialEvent: sealed("cli_agent_mission_requests/events", "bob-request/000001"),
  };
}

function createGroupProbe(): Record<string, unknown> {
  return {
    groupId: "bob-group",
    deviceId: "bob-device",
    nonce: "bola-test-nonce",
    actionProof: { nonce: "bola-action-proof", signature: "YQ==" },
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: VAULT,
    sealedPayload: sealed("mission_groups", "bob-group"),
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

function missionSubjectProbe(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    requestId: "bob-request",
    deviceId: "bob-device",
    nonce: "bola-test-nonce",
    actionProof: { nonce: "bola-action-proof", signature: "YQ==" },
    ...extra,
  };
}

describe("BOLA — cliAgentMissions", () => {
  it("createCliAgentMission rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliAgentMissions.js");
    const run = callableRunner(mod.createCliAgentMission);
    await tier2CallableProof(bolaStore, {
      exportedName: "createCliAgentMission",
      run,
      payload: createMissionProbe(),
      expectedOutcome: "no-side-effect",
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
      payload: missionSubjectProbe({
        sealedStatePayload: sealed("cli_agent_mission_requests", "bob-request", "sealedStatePayload"),
      }),
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
      payload: missionSubjectProbe({
        nextStatus: "accepted",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        sealedStatePayload: sealed("cli_agent_mission_requests", "bob-request", "sealedStatePayload"),
      }),
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
      payload: missionSubjectProbe({
        hostWriteNonce: "bola-host-write-nonce",
        eventId: "000002",
        sealedEvent: sealed("cli_agent_mission_requests/events", "bob-request/000002"),
        publicEventShape: {
          sequence: 2,
          kind: "status",
          phase: "running",
          runtime: "codex",
          source: "mac",
        },
      }),
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
      payload: missionSubjectProbe({
        status: "starting",
        hostWriteNonce: "bola-host-write-nonce",
        sealedStatePayload: sealed("cli_agent_mission_requests", "bob-request", "sealedStatePayload"),
      }),
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });
});
