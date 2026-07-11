import { beforeEach, describe, expect, it, vi } from "vitest";

const { getTombstone } = vi.hoisted(() => ({ getTombstone: vi.fn() }));

vi.mock("../adminRuntime.js", () => ({
  db: { doc: () => ({ get: getTombstone }) },
}));
vi.mock("../accountErasureConstants.js", () => ({
  ACCOUNT_ERASURE_TOMBSTONE_COLLECTION: "account_erasure_tombstones",
}));

import { assertAccountErasureAllowsCallable } from "../accountErasureBarrier.js";

describe("account erasure callable barrier", () => {
  beforeEach(() => vi.clearAllMocks());

  it("rejects every ordinary callable for a tombstoned account", async () => {
    getTombstone.mockResolvedValue({ exists: true });
    await expect(assertAccountErasureAllowsCallable("uid-1", "connectProviderAccount")).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });

  it("allows the recovery callable without consulting the barrier", async () => {
    await expect(assertAccountErasureAllowsCallable("uid-1", "deleteUserCloudData")).resolves.toBeUndefined();
    expect(getTombstone).not.toHaveBeenCalled();
  });

  it("allows ordinary callables only when no tombstone exists", async () => {
    getTombstone.mockResolvedValue({ exists: false });
    await expect(assertAccountErasureAllowsCallable("uid-1", "exportUserData")).resolves.toBeUndefined();
  });
});
