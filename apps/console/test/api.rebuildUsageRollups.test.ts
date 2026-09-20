import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  callable: vi.fn(),
  functions: vi.fn(),
  httpsCallable: vi.fn(),
}));

vi.mock("../lib/firebaseClient", () => ({
  functions: mocks.functions,
}));

vi.mock("firebase/functions", () => ({
  httpsCallable: mocks.httpsCallable,
}));

import { REBUILD_USAGE_ROLLUPS_TIMEOUT_MS, rebuildUsageRollups } from "../lib/api";

describe("rebuildUsageRollups client envelope", () => {
  beforeEach(() => {
    mocks.callable.mockReset();
    mocks.callable.mockResolvedValue({ data: { success: true } });
    mocks.functions.mockReset();
    mocks.functions.mockReturnValue({ app: "test-functions" });
    mocks.httpsCallable.mockReset();
    mocks.httpsCallable.mockReturnValue(mocks.callable);
  });

  it("uses a 540s timeout so the JS SDK default 70s cannot abort a full rebuild", async () => {
    expect(REBUILD_USAGE_ROLLUPS_TIMEOUT_MS).toBe(540_000);
    await expect(rebuildUsageRollups(true)).resolves.toEqual({ success: true });
    expect(mocks.httpsCallable).toHaveBeenCalledWith(
      { app: "test-functions" },
      "rebuildUsageRollups",
      { timeout: 540_000 },
    );
    expect(mocks.callable).toHaveBeenCalledWith({ force: true });
  });

  it("still sends force:false on a routine refresh", async () => {
    await rebuildUsageRollups();
    expect(mocks.callable).toHaveBeenCalledWith({ force: false });
  });
});
