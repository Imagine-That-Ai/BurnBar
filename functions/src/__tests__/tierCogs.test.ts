import { describe, expect, it } from "vitest";

import { tierCogsDailyDocPath } from "../tierCogs.js";

describe("tier COGS daily document routing", () => {
  it("uses a valid Firestore document path beneath the days collection", () => {
    const path = tierCogsDailyDocPath("2026-07-31");

    expect(path).toBe("ops/cogs_by_tier/days/2026-07-31");
    expect(path.split("/")).toHaveLength(4);
  });
});
