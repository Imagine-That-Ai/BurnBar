import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Firestore } from "firebase-admin/firestore";

import { cleanupStaleLeaderboards, loadPreviousRanks, loadPreviousRanksForBoards } from "../community/aggregation.js";
import { CommunityPaths } from "../community/consent.js";
import { pathKeyedFirestore, seedDoc } from "./bola/callableBolaHarness.js";

vi.mock("../resilienceHelpers.js", () => ({
  firestoreWithResilience: vi.fn((_label: string, fn: () => Promise<unknown>) => fn()),
}));

const store = new Map<string, Record<string, unknown>>();

describe("loadPreviousRanks cohort doc id", () => {
  beforeEach(() => store.clear());

  it("reads ranks from the board matching window, tier, and geoKey", async () => {
    const geoKey = "US-CA-san-francisco";
    seedDoc(store, CommunityPaths.leaderboard("30d", "city", geoKey), {
      entries: [{ anonId: "cohort-anon", rank: 4, movement: "same" }],
      belowThreshold: false,
      cohortSize: 12,
      percentiles: { p50: 1, p75: 1, p90: 1, p99: 1 },
    });
    seedDoc(store, CommunityPaths.leaderboard("all_time", "world", "world"), {
      entries: [{ anonId: "cohort-anon", rank: 99, movement: "same" }],
      belowThreshold: false,
      cohortSize: 50,
      percentiles: { p50: 1, p75: 1, p90: 1, p99: 1 },
    });

    const db = pathKeyedFirestore(store) as unknown as Firestore;
    const prev = await loadPreviousRanks(db, "30d", "city", geoKey);

    expect(prev.get("cohort-anon")).toBe(4);
    expect(prev.get("cohort-anon")).not.toBe(99);
  });

  it("loads previous ranks for unique board descriptors", async () => {
    seedDoc(store, CommunityPaths.leaderboard("7d", "world", "world"), {
      entries: [{ anonId: "world-anon", rank: 2, movement: "same" }],
      belowThreshold: false,
      cohortSize: 12,
      percentiles: { p50: 1, p75: 1, p90: 1, p99: 1 },
    });
    seedDoc(store, CommunityPaths.leaderboard("7d", "country", "US"), {
      entries: [{ anonId: "country-anon", rank: 7, movement: "same" }],
      belowThreshold: false,
      cohortSize: 12,
      percentiles: { p50: 1, p75: 1, p90: 1, p99: 1 },
    });

    const db = pathKeyedFirestore(store) as unknown as Firestore;
    const prev = await loadPreviousRanksForBoards(db, [
      { window: "7d", tier: "world", geoKey: "world" },
      { window: "7d", tier: "world", geoKey: "world" },
      { window: "7d", tier: "country", geoKey: "US" },
    ]);

    expect(prev.size).toBe(2);
    expect(prev.get("7d|world|world")?.get("world-anon")).toBe(2);
    expect(prev.get("7d|country|US")?.get("country-anon")).toBe(7);
  });
});

describe("cleanupStaleLeaderboards", () => {
  beforeEach(() => store.clear());

  it("deletes only inactive boards older than the current run", async () => {
    const activePath = CommunityPaths.leaderboard("7d", "world", "world");
    const stalePath = CommunityPaths.leaderboard("7d", "country", "DE");
    const freshPath = CommunityPaths.leaderboard("7d", "country", "US");
    seedDoc(store, activePath, { updatedAt: "2026-07-09T00:00:00.000Z" });
    seedDoc(store, stalePath, { updatedAt: "2026-07-08T23:00:00.000Z" });
    seedDoc(store, freshPath, { updatedAt: "2026-07-09T00:30:00.000Z" });

    const db = pathKeyedFirestore(store) as unknown as Firestore;
    const deleted = await cleanupStaleLeaderboards(db, new Set([activePath]), new Date("2026-07-09T00:00:00.000Z"));

    expect(deleted).toBe(1);
    expect(store.has(activePath)).toBe(true);
    expect(store.has(stalePath)).toBe(false);
    expect(store.has(freshPath)).toBe(true);
  });
});
