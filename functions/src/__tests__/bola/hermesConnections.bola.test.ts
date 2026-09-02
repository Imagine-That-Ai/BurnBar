/**
 * BOLA negative coverage — src/__tests__/bola/hermesConnections.bola.test.ts
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
  revokeHermesConnection: ["revokeHermesConnection rejects cross-user object access"],
  updateHermesConnectionStatus: ["updateHermesConnectionStatus rejects cross-user object access"],
} as const;

describe("BOLA — hermes", () => {
  it("revokeHermesConnection rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermes.js");
    const exported = mod.revokeHermesConnection;
    if (!exported) throw new Error("missing export revokeHermesConnection");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "revokeHermesConnection",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("updateHermesConnectionStatus rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermes.js");
    const exported = mod.updateHermesConnectionStatus;
    if (!exported) throw new Error("missing export updateHermesConnectionStatus");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "updateHermesConnectionStatus",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });
});
