/**
 * BOLA negative coverage — src/__tests__/bola/deviceLinks.bola.test.ts
 * Generated scaffold; implements cross-user denial at callable trust boundary.
 */

import { describe, it, vi, expect } from "vitest";
import { ALICE_UID, BOB_UID, callableRequest, callableRunner, pathKeyedFirestore, seedDoc, tier2CallableProof, snapshotTenantPaths, expectTenantPathsUnchanged } from "./callableBolaHarness.js";

import { deviceLinkPath } from "../../../../packages/functions-shared/src/domains/device-links/index.js";

process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map());
vi.mock("../../../../packages/functions-shared/src/adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));
vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(bolaStore),
  };
});

vi.mock("../../../../packages/functions-shared/src/auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
  assertAppCheck: vi.fn(),
}));
vi.mock("../../../../packages/functions-shared/src/callables/highRiskOwnerAction.js", () => ({
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));
vi.mock("../../../../packages/functions-shared/src/appCheckAttestation.js", async () => {
  const actual = await vi.importActual<typeof import("../../../../packages/functions-shared/src/appCheckAttestation.js")>("../../../../packages/functions-shared/src/appCheckAttestation.js");
  return {
    ...actual,
    enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
  };
});
export const BOLA_MANIFEST = {
  adoptProviderAccountForDevice: ["adoptProviderAccountForDevice rejects cross-user object access"],
  revokeProviderAccountDeviceLink: ["revokeProviderAccountDeviceLink rejects cross-user object access"],
} as const;

describe("BOLA — deviceLinks", () => {
  it("adoptProviderAccountForDevice rejects cross-user object access", async () => {
    const mod = await import("../../../../functions-identity/src/domains/devices/deviceLinks.js");
    const exported = mod.adoptProviderAccountForDevice;
    if (!exported) throw new Error("missing export adoptProviderAccountForDevice");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "adoptProviderAccountForDevice",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });

  it("revokeProviderAccountDeviceLink rejects cross-user object access", async () => {
    bolaStore.clear();
    const bobLinkPath = deviceLinkPath(BOB_UID, "bob-account", "bob-device");
    seedDoc(bolaStore, bobLinkPath, { status: "active", schemaVersion: 1 });
    const bobBefore = snapshotTenantPaths(bolaStore, BOB_UID);

    const mod = await import("../../../../functions-identity/src/domains/devices/deviceLinks.js");
    const run = callableRunner(mod.revokeProviderAccountDeviceLink);
    await run(
      callableRequest(ALICE_UID, {
        accountID: "bob-account",
        deviceID: "bob-device",
      }),
    );

    // Catalog expectedOutcome: no-side-effect — auth.uid scopes writes; Bob's link must stay intact.
    expectTenantPathsUnchanged(bolaStore, bobBefore);
    expect(bolaStore.get(bobLinkPath)?.status).toBe("active");
  });
});
