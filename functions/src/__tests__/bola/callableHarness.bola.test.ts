import { describe, expect, it } from "vitest";
import { expectCallableDenial, callableRequest, callableRunner } from "./callableBolaHarness.js";

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
});
