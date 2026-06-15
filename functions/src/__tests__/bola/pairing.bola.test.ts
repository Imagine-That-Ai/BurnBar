/**
 * BOLA negative coverage — src/__tests__/bola/pairing.bola.test.ts
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
  "startCliLink": [
    "startCliLink rejects cross-user object access"
  ],
  "pollCliLink": [
    "pollCliLink rejects cross-user object access"
  ],
  "completeCliLink": [
    "completeCliLink rejects cross-user object access"
  ],
  "createHermesPairing": [
    "createHermesPairing rejects cross-user object access"
  ],
  "completeHermesPairing": [
    "completeHermesPairing rejects cross-user object access"
  ],
  "createPiAgentPairing": [
    "createPiAgentPairing rejects cross-user object access"
  ],
  "completePiAgentPairing": [
    "completePiAgentPairing rejects cross-user object access"
  ]
} as const;

describe("BOLA — pairing", () => {
  it("startCliLink rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliLink.js");
    const exported = mod.startCliLink;
    if (!exported) throw new Error("missing export startCliLink");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("pollCliLink rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliLink.js");
    const exported = mod.pollCliLink;
    if (!exported) throw new Error("missing export pollCliLink");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("completeCliLink rejects cross-user object access", async () => {
    const mod = await import("../../callables/cliLink.js");
    const exported = mod.completeCliLink;
    if (!exported) throw new Error("missing export completeCliLink");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("createHermesPairing rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermes.js");
    const exported = mod.createHermesPairing;
    if (!exported) throw new Error("missing export createHermesPairing");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("completeHermesPairing rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermes.js");
    const exported = mod.completeHermesPairing;
    if (!exported) throw new Error("missing export completeHermesPairing");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("createPiAgentPairing rejects cross-user object access", async () => {
    const mod = await import("../../callables/piAgent.js");
    const exported = mod.createPiAgentPairing;
    if (!exported) throw new Error("missing export createPiAgentPairing");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("completePiAgentPairing rejects cross-user object access", async () => {
    const mod = await import("../../callables/piAgent.js");
    const exported = mod.completePiAgentPairing;
    if (!exported) throw new Error("missing export completePiAgentPairing");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });
});
