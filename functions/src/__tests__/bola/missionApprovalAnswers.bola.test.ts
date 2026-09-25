/**
 * BOLA negative coverage — mission approval ceiling / redeem ownership.
 */

import { describe, it, vi } from "vitest";
import { callableRunner, pathKeyedFirestore, tier2CallableProof } from "./callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map());
vi.mock("../../../../packages/functions-shared/src/adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));
vi.mock("../../../../packages/functions-shared/src/auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
}));
vi.mock("../../../../packages/functions-shared/src/callables/highRiskOwnerAction.js", () => ({
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));
vi.mock("../../../../packages/functions-shared/src/shared/entitlements.js", async () => {
  const actual = await vi.importActual<typeof import("../../../../packages/functions-shared/src/shared/entitlements.js")>("../../../../packages/functions-shared/src/shared/entitlements.js");
  return { ...actual, assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined) };
});
vi.mock("../../../../packages/functions-shared/src/appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
}));
vi.mock("../../../../packages/functions-shared/src/callables/computerUseSecurityFirestore.js", () => ({
  requireTrustedDeviceActionProof: vi.fn(async () => ({ deviceId: "dev", platform: "iOS" })),
  appendComputerUseAuditEvent: vi.fn(async () => undefined),
}));
vi.mock("../../../../packages/functions-shared/src/callables/publicRateLimit.js", () => ({
  recordCallableApprovalFailure: vi.fn(async () => undefined),
  assertCallableApprovalNotLocked: vi.fn(async () => undefined),
}));

export const BOLA_MANIFEST = {
  publishMissionApprovalCeiling: ["publishMissionApprovalCeiling rejects cross-user object access"],
  redeemMissionApprovalAnswer: ["redeemMissionApprovalAnswer rejects cross-user object access"],
} as const;

describe("BOLA — missionApprovalAnswers", () => {
  it("publishMissionApprovalCeiling rejects cross-user object access", async () => {
    const mod = await import("../../../../functions-sync/src/domains/missions/missionApprovalAnswers.js");
    const run = callableRunner(mod.publishMissionApprovalCeiling);
    await tier2CallableProof(bolaStore, {
      exportedName: "publishMissionApprovalCeiling",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("redeemMissionApprovalAnswer rejects cross-user object access", async () => {
    const mod = await import("../../../../functions-sync/src/domains/missions/missionApprovalAnswers.js");
    const run = callableRunner(mod.redeemMissionApprovalAnswer);
    await tier2CallableProof(bolaStore, {
      exportedName: "redeemMissionApprovalAnswer",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });
});
