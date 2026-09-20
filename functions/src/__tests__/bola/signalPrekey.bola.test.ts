/**
 * BOLA negative coverage — src/__tests__/bola/signalPrekey.bola.test.ts
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
  publishSignalPrekeyBundle: ["publishSignalPrekeyBundle rejects cross-user object access"],
  claimSignalPrekeyBundle: ["claimSignalPrekeyBundle rejects cross-user object access"],
  recordSignalSession: ["recordSignalSession rejects cross-user object access"],
  recordSignalRotation: ["recordSignalRotation rejects cross-user object access"],
  signalPrekeyWatermark: ["signalPrekeyWatermark rejects cross-user object access"],
} as const;

describe("BOLA — signal", () => {
  it("publishSignalPrekeyBundle rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalPrekeyDirectory.js");
    const exported = mod.publishSignalPrekeyBundle;
    if (!exported) throw new Error("missing export publishSignalPrekeyBundle");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "publishSignalPrekeyBundle",
      run,
      expectedCode: "failed-precondition",
      expectedOutcome: "throws",
    });
  });

  it("claimSignalPrekeyBundle rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalPrekeyDirectory.js");
    const exported = mod.claimSignalPrekeyBundle;
    if (!exported) throw new Error("missing export claimSignalPrekeyBundle");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "claimSignalPrekeyBundle",
      run,
      expectedCode: "failed-precondition",
      expectedOutcome: "throws",
    });
  });

  it("recordSignalSession rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalPrekeyDirectory.js");
    const exported = mod.recordSignalSession;
    if (!exported) throw new Error("missing export recordSignalSession");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "recordSignalSession",
      run,
      expectedCode: "failed-precondition",
      expectedOutcome: "throws",
    });
  });

  it("recordSignalRotation rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalPrekeyDirectory.js");
    const exported = mod.recordSignalRotation;
    if (!exported) throw new Error("missing export recordSignalRotation");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "recordSignalRotation",
      run,
      expectedCode: "failed-precondition",
      expectedOutcome: "throws",
    });
  });

  it("signalPrekeyWatermark rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalPrekeyDirectory.js");
    const exported = mod.signalPrekeyWatermark;
    if (!exported) throw new Error("missing export signalPrekeyWatermark");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "signalPrekeyWatermark",
      run,
      expectedCode: "failed-precondition",
      expectedOutcome: "throws",
    });
  });
});
