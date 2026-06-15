/**
 * BOLA negative coverage — src/__tests__/bola/remoteMcp.bola.test.ts
 * Generated scaffold; implements cross-user denial at callable trust boundary.
 */
import { describe, expect, it, vi } from "vitest";
import { ALICE_UID, BOB_UID, callableRequest, callableRunner, pathKeyedFirestore, seedDoc, snapshotTenantPaths, expectTenantPathsUnchanged } from "./callableBolaHarness.js";

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
  revokeRemoteMcpClient: ["revokeRemoteMcpClient rejects cross-user object access"],
} as const;

describe("BOLA — remoteMcp", () => {
  it("revokeRemoteMcpClient rejects cross-user object access", async () => {
    bolaStore.clear();
    seedDoc(bolaStore, `users/${BOB_UID}/remote_mcp_clients/bob-client`, {
      active: true,
      schemaVersion: 1,
    });
    const bobBefore = snapshotTenantPaths(bolaStore, BOB_UID);

    const mod = await import("../../callables/remoteMcp.js");
    const run = callableRunner(mod.revokeRemoteMcpClient);
    await run(callableRequest(ALICE_UID, { clientId: "bob-client" }));

    // Catalog expectedOutcome: no-side-effect — revoke is scoped to request.auth.uid only.
    expectTenantPathsUnchanged(bolaStore, bobBefore);
    expect(bolaStore.get(`users/${BOB_UID}/remote_mcp_clients/bob-client`)?.active).toBe(true);
  });
});
