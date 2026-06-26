import { describe, expect, it } from "vitest";
import { expectCallableDenial, callableRequest, callableRunner, tier2CallableProof } from "./callableBolaHarness.js";

describe("callableBolaHarness sanity", () => {
  it("expectCallableDenial fails when handler succeeds", async () => {
    const succeeding = { run: async () => ({ ok: true }) };
    let failed = false;
    try {
      await expectCallableDenial(callableRunner(succeeding), callableRequest("u", {}), "not-found");
    } catch (error) {
      failed = error instanceof Error && error.message.includes("expected callable to reject");
    }
    expect(failed).toBe(true);
  });

  it("tier2CallableProof fails successful calls when throws is expected", async () => {
    const store = new Map<string, Record<string, unknown>>();
    const succeeding = { run: async () => ({ ok: true }) };

    await expect(
      tier2CallableProof(store, {
        exportedName: "getEncryptedProjectMemorySnapshot",
        run: callableRunner(succeeding),
        expectedOutcome: "throws",
        expectedCode: "not-found",
      }),
    ).rejects.toThrow(/expected callable to reject/);
  });
});
