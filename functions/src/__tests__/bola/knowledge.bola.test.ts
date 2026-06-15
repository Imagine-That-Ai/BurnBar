/**
 * BOLA negative coverage — src/__tests__/bola/knowledge.bola.test.ts
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
  "commitKnowledgeBatch": [
    "commitKnowledgeBatch rejects cross-user object access"
  ],
  "configureKnowledgeSource": [
    "configureKnowledgeSource rejects cross-user object access"
  ],
  "deleteKnowledgeSource": [
    "deleteKnowledgeSource rejects cross-user object access"
  ],
  "connectKnowledgeRepo": [
    "connectKnowledgeRepo rejects cross-user object access"
  ],
  "disconnectKnowledgeRepo": [
    "disconnectKnowledgeRepo rejects cross-user object access"
  ]
} as const;

describe("BOLA — knowledge", () => {
  it("commitKnowledgeBatch rejects cross-user object access", async () => {
    const mod = await import("../../callables/knowledgeMemory.js");
    const exported = mod.commitKnowledgeBatch;
    if (!exported) throw new Error("missing export commitKnowledgeBatch");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("configureKnowledgeSource rejects cross-user object access", async () => {
    const mod = await import("../../callables/knowledgeMemory.js");
    const exported = mod.configureKnowledgeSource;
    if (!exported) throw new Error("missing export configureKnowledgeSource");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("deleteKnowledgeSource rejects cross-user object access", async () => {
    const mod = await import("../../callables/knowledgeMemory.js");
    const exported = mod.deleteKnowledgeSource;
    if (!exported) throw new Error("missing export deleteKnowledgeSource");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("connectKnowledgeRepo rejects cross-user object access", async () => {
    const mod = await import("../../callables/knowledgeSync.js");
    const exported = mod.connectKnowledgeRepo;
    if (!exported) throw new Error("missing export connectKnowledgeRepo");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("disconnectKnowledgeRepo rejects cross-user object access", async () => {
    const mod = await import("../../callables/knowledgeSync.js");
    const exported = mod.disconnectKnowledgeRepo;
    if (!exported) throw new Error("missing export disconnectKnowledgeRepo");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });
});
