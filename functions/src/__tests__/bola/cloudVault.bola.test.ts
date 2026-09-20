/**
 * BOLA negative coverage — src/__tests__/bola/cloudVault.bola.test.ts
 * Generated scaffold; implements cross-user denial at callable trust boundary.
 */

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
vi.mock("../../appCheckAttestation.js", async () => {
  const actual = await vi.importActual<typeof import("../../appCheckAttestation.js")>("../../appCheckAttestation.js");
  return {
    ...actual,
    enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
  };
});
export const BOLA_MANIFEST = {
  rotateCloudVaultKey: ["rotateCloudVaultKey rejects cross-user object access"],
} as const;

describe("BOLA — cloudVault", () => {
  it("rotateCloudVaultKey rejects cross-user object access", async () => {
    const mod = await import("../../callables/cloudVaultRotation.js");
    const exported = mod.rotateCloudVaultKey;
    if (!exported) throw new Error("missing export rotateCloudVaultKey");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "rotateCloudVaultKey",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });
});
