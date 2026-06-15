/**
 * BOLA negative coverage — src/__tests__/bola/deviceLinks.bola.test.ts
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
  "adoptProviderAccountForDevice": [
    "adoptProviderAccountForDevice rejects cross-user object access"
  ],
  "revokeProviderAccountDeviceLink": [
    "revokeProviderAccountDeviceLink rejects cross-user object access"
  ]
} as const;

describe("BOLA — deviceLinks", () => {
  it("adoptProviderAccountForDevice rejects cross-user object access", async () => {
    const mod = await import("../../callables/deviceLinks.js");
    const exported = mod.adoptProviderAccountForDevice;
    if (!exported) throw new Error("missing export adoptProviderAccountForDevice");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("revokeProviderAccountDeviceLink rejects cross-user object access", async () => {
    const mod = await import("../../callables/deviceLinks.js");
    const exported = mod.revokeProviderAccountDeviceLink;
    if (!exported) throw new Error("missing export revokeProviderAccountDeviceLink");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });
});
