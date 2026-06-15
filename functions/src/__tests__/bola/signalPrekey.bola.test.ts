/**
 * BOLA negative coverage — src/__tests__/bola/signalPrekey.bola.test.ts
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
  "publishSignalPrekeyBundle": [
    "publishSignalPrekeyBundle rejects cross-user object access"
  ],
  "claimSignalPrekeyBundle": [
    "claimSignalPrekeyBundle rejects cross-user object access"
  ],
  "recordSignalSession": [
    "recordSignalSession rejects cross-user object access"
  ],
  "recordSignalRotation": [
    "recordSignalRotation rejects cross-user object access"
  ],
  "signalPrekeyWatermark": [
    "signalPrekeyWatermark rejects cross-user object access"
  ]
} as const;

describe("BOLA — signal", () => {
  it("publishSignalPrekeyBundle rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalPrekeyDirectory.js");
    const exported = mod.publishSignalPrekeyBundle;
    if (!exported) throw new Error("missing export publishSignalPrekeyBundle");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("claimSignalPrekeyBundle rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalPrekeyDirectory.js");
    const exported = mod.claimSignalPrekeyBundle;
    if (!exported) throw new Error("missing export claimSignalPrekeyBundle");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("recordSignalSession rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalPrekeyDirectory.js");
    const exported = mod.recordSignalSession;
    if (!exported) throw new Error("missing export recordSignalSession");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("recordSignalRotation rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalPrekeyDirectory.js");
    const exported = mod.recordSignalRotation;
    if (!exported) throw new Error("missing export recordSignalRotation");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("signalPrekeyWatermark rejects cross-user object access", async () => {
    const mod = await import("../../callables/signalPrekeyDirectory.js");
    const exported = mod.signalPrekeyWatermark;
    if (!exported) throw new Error("missing export signalPrekeyWatermark");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });
});
