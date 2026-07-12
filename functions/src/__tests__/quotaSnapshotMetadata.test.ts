import { describe, expect, it } from "vitest";

import { quotaAccountRefreshMetadata } from "../quotaSnapshotMetadata.js";
import type { QuotaSnapshotDoc } from "../types.js";

function snapshot(window: string): QuotaSnapshotDoc {
  return {
    sourceKind: "provider",
    sourceId: "default",
    provider: "claude-code",
    fetchedAt: "2026-07-08T00:00:00.000Z",
    source: "default",
    confidence: "high",
    buckets: [{ name: "tokens", window, limit: 100, remaining: 90 }],
    schemaVersion: 1,
    updatedAt: "2026-07-08T00:00:00.000Z",
  };
}

describe("quotaAccountRefreshMetadata", () => {
  it("classifies monthly windows before suffix shorthand checks", () => {
    const metadata = quotaAccountRefreshMetadata(
      snapshot("month"),
      new Date("2026-07-08T00:00:00.000Z"),
    );

    expect(metadata.quotaWindowKind).toBe("monthly");
  });

  it("keeps explicit hour and day shorthands as rolling windows", () => {
    const hourly = quotaAccountRefreshMetadata(
      snapshot("5h"),
      new Date("2026-07-08T00:00:00.000Z"),
    );
    const daily = quotaAccountRefreshMetadata(
      snapshot("7d"),
      new Date("2026-07-08T00:00:00.000Z"),
    );

    expect(hourly.quotaWindowKind).toBe("rollingHours");
    expect(daily.quotaWindowKind).toBe("rollingDays");
  });
});
