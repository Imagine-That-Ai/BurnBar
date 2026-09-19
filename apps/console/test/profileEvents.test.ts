/**
 * Event-query contract for the mineable /profile explorer: constraint shape
 * (where + orderBy + pagination, iOS fetchUsagePage parity), event
 * normalization, and the pure aggregate math (hour × weekday, token mix,
 * day summary). Firestore itself is never touched — no live scans.
 */
import { describe, expect, it, vi } from "vitest";

const whereCalls: unknown[][] = [];
const orderByCalls: unknown[][] = [];
const limitCalls: unknown[][] = [];
let startAfterCalls = 0;

vi.mock("firebase/firestore", () => ({
  collection: (...args: unknown[]) => ({ __collection: args }),
  query: (...args: unknown[]) => ({ __query: args }),
  where: (...args: unknown[]) => {
    whereCalls.push(args);
    return { __where: args };
  },
  orderBy: (...args: unknown[]) => {
    orderByCalls.push(args);
    return { __orderBy: args };
  },
  limit: (...args: unknown[]) => {
    limitCalls.push(args);
    return { __limit: args };
  },
  startAfter: (...args: unknown[]) => {
    startAfterCalls++;
    return { __startAfter: args };
  },
  getDocs: async () => ({ docs: [] }),
}));

import {
  PROFILE_EVENTS_PAGE_SIZE,
  buildProfileEventConstraints,
  classifyProfileEventError,
  eventTimeToIso,
  matchEventFacets,
  normalizeProfileEvent,
  profileEventErrorCopy,
} from "../lib/profile/profileEvents";
import {
  eventsOnDay,
  hourWeekdayGrid,
  rankShares,
  summarizeDay,
  tokenMix,
} from "../lib/profile/profileAggregates";
import type { ProfileUsageEvent } from "../lib/profile/profileEvents";

function ev(partial: Partial<ProfileUsageEvent> & { id: string }): ProfileUsageEvent {
  return {
    provider: "Claude Code",
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    reasoningTokens: 0,
    totalTokens: 0,
    costUsd: 0,
    startedAt: null,
    hourUtc: null,
    durationSeconds: null,
    ...partial,
  };
}

describe("buildProfileEventConstraints", () => {
  it("orders by startTime desc with the page-size limit and no filters", () => {
    whereCalls.length = 0;
    orderByCalls.length = 0;
    limitCalls.length = 0;
    buildProfileEventConstraints({
      facets: { providers: [], models: [], devices: [], harnesses: [], accounts: [] },
      range: { fromDay: null, toDay: null },
    });
    expect(whereCalls).toEqual([]);
    expect(orderByCalls).toEqual([["startTime", "desc"]]);
    expect(limitCalls).toEqual([[PROFILE_EVENTS_PAGE_SIZE]]);
    expect(PROFILE_EVENTS_PAGE_SIZE).toBe(100);
  });

  it("applies at most one server equality plus the bounded range", () => {
    whereCalls.length = 0;
    buildProfileEventConstraints({
      facets: {
        providers: ["claude-code"],
        models: ["gpt-5.3"],
        devices: ["mac"],
        harnesses: ["claude-code"],
        accounts: ["acct-1"],
      },
      range: { fromDay: "2026-08-01", toDay: "2026-08-16" },
    });
    // Model wins the priority order; providers NEVER constrain server-side
    // (display/canonical split), the rest filter client-side.
    expect(whereCalls).toContainEqual(["model", "==", "gpt-5.3"]);
    expect(whereCalls).not.toContainEqual(["provider", "==", "claude-code"]);
    expect(whereCalls.filter((c) => c[1] === "==")).toHaveLength(1);
    expect(whereCalls).toContainEqual([
      "startTime",
      ">=",
      new Date("2026-08-01T00:00:00Z"),
    ]);
    expect(whereCalls).toContainEqual([
      "startTime",
      "<=",
      new Date("2026-08-16T23:59:59.999Z"),
    ]);
  });

  it("never truncates multi-value groups server-side; cursor appends", () => {
    whereCalls.length = 0;
    startAfterCalls = 0;
    buildProfileEventConstraints(
      {
        facets: {
          providers: ["a", "b"],
          models: ["m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8", "m9", "m10", "m11"],
          devices: [],
          harnesses: [],
          accounts: [],
        },
        range: { fromDay: null, toDay: null },
      },
      { __cursor: true } as never,
    );
    // No `in`, no truncation — all eleven models filter client-side.
    expect(whereCalls).toEqual([]);
    expect(startAfterCalls).toBe(1);
  });

  it("skips the server equality for synthetic unattributed account keys", () => {
    whereCalls.length = 0;
    buildProfileEventConstraints({
      facets: { providers: [], models: [], devices: [], harnesses: [], accounts: ["codex:unattributed"] },
      range: { fromDay: "2026-08-01", toDay: "2026-08-16" },
    });
    expect(whereCalls.filter((c) => c[1] === "==")).toHaveLength(0);
  });
});

describe("matchEventFacets", () => {
  const base = ev({
    id: "x",
    provider: "Claude Code",
    providerID: "claude-code",
    model: "m-1",
    harnessId: "h-1",
    deviceId: "mac",
  });
  const empty = { providers: [], models: [], devices: [], harnesses: [], accounts: [] };

  it("matches everything when no facet is active", () => {
    expect(matchEventFacets(base, empty)).toBe(true);
  });

  it("matches providers by display name OR canonical id", () => {
    expect(matchEventFacets(base, { ...empty, providers: ["claude-code"] })).toBe(true);
    expect(matchEventFacets(base, { ...empty, providers: ["Claude Code"] })).toBe(true);
    expect(matchEventFacets(base, { ...empty, providers: ["codex"] })).toBe(false);
  });

  it("matches synthetic unattributed accounts against missing account ids", () => {
    const unattributed = ev({ id: "u", provider: "X", providerID: "codex" });
    expect(
      matchEventFacets(unattributed, { ...empty, accounts: ["codex:unattributed"] }),
    ).toBe(true);
    expect(matchEventFacets(base, { ...empty, accounts: ["codex:unattributed"] })).toBe(false);
    const linked = ev({ id: "l", provider: "X", providerID: "codex", accountId: "acct-9" });
    expect(matchEventFacets(linked, { ...empty, accounts: ["acct-9"] })).toBe(true);
  });

  it("ands groups and ors values", () => {
    expect(
      matchEventFacets(base, { ...empty, models: ["m-1", "m-2"], devices: ["mac"] }),
    ).toBe(true);
    expect(matchEventFacets(base, { ...empty, models: ["m-2"] })).toBe(false);
    expect(matchEventFacets(base, { ...empty, devices: ["other"] })).toBe(false);
  });
});

describe("classifyProfileEventError", () => {
  it("maps failures onto stable kinds with member copy", () => {
    expect(classifyProfileEventError(new Error("failed-precondition: requires an index"))).toBe("index");
    expect(classifyProfileEventError(new Error("permission-denied"))).toBe("denied");
    expect(classifyProfileEventError(new Error("boom"))).toBe("network");
    expect(profileEventErrorCopy("index")).toMatch(/warming up/);
    expect(profileEventErrorCopy("denied")).toMatch(/Sign in again/);
    expect(profileEventErrorCopy("network")).toMatch(/connection/);
  });
});

describe("eventTimeToIso", () => {
  it("coerces Date, ISO strings, and {seconds} shapes", () => {
    expect(eventTimeToIso(new Date("2026-08-16T07:00:00.000Z"))).toBe("2026-08-16T07:00:00.000Z");
    expect(eventTimeToIso("2026-08-16T07:00:00.000Z")).toBe("2026-08-16T07:00:00.000Z");
    expect(eventTimeToIso({ seconds: 1_756_000_000 })).toBe(
      new Date(1_756_000_000 * 1000).toISOString(),
    );
    expect(eventTimeToIso({ toDate: () => new Date("2026-08-16T07:00:00.000Z") })).toBe(
      "2026-08-16T07:00:00.000Z",
    );
    expect(eventTimeToIso(null)).toBeNull();
    expect(eventTimeToIso("garbage")).toBeNull();
  });
});

describe("normalizeProfileEvent", () => {
  it("reads the canonical costUSD field first (Elder Wand spelling)", () => {
    const e = normalizeProfileEvent("doc-cost", {
      provider: "openburnbar",
      costUSD: 0.42,
      costUsd: 0.11,
      cost: 0.07,
      recordedAt: "2026-08-15T12:00:00.000Z",
    });
    expect(e.costUsd).toBe(0.42);
    expect(
      normalizeProfileEvent("doc-cost-legacy", { provider: "x", costUsd: 0.11 }).costUsd,
    ).toBe(0.11);
  });

  it("sums the token mix and derives the UTC hour", () => {
    const e = normalizeProfileEvent("doc-1", {
      provider: "Claude Code",
      providerID: "claude-code",
      model: "claude-opus-4.6",
      executionSourceID: "claude-code",
      executionSourceName: "Claude Code",
      providerAccountID: "acct-1",
      deviceId: "mac",
      sessionId: "s-1",
      inputTokens: 100,
      outputTokens: 50,
      cacheReadTokens: 25,
      cacheCreationTokens: 10,
      reasoningTokens: 5,
      costUsd: 0.12,
      startTime: { seconds: Date.UTC(2026, 7, 14, 7, 30) / 1000 },
      endTime: { seconds: Date.UTC(2026, 7, 14, 7, 31, 30) / 1000 },
    });
    expect(e.totalTokens).toBe(190);
    expect(e.hourUtc).toBe(7);
    expect(e.durationSeconds).toBe(90);
    expect(e.harnessId).toBe("claude-code");
    expect(e.startedAt).toBe("2026-08-14T07:30:00.000Z");
  });

  it("prefers totalTokens when present and never throws on garbage", () => {
    const e = normalizeProfileEvent("doc-2", {
      provider: "X",
      totalTokens: 42,
      startTime: "2026-08-16T00:00:00.000Z",
    });
    expect(e.totalTokens).toBe(42);
    expect(e.hourUtc).toBe(0);
    expect(normalizeProfileEvent("doc-3", null).provider).toBe("unknown");
    expect(normalizeProfileEvent("doc-4", "garbage").totalTokens).toBe(0);
  });

  it("falls back to recordedAt when startTime is absent", () => {
    const e = normalizeProfileEvent("doc-5", {
      provider: "X",
      recordedAt: "2026-08-15T12:00:00.000Z",
    });
    expect(e.startedAt).toBe("2026-08-15T12:00:00.000Z");
    expect(e.hourUtc).toBe(12);
  });
});

describe("profileAggregates", () => {
  const events = [
    ev({
      id: "a",
      model: "m-1",
      harnessId: "h-1",
      harnessName: "H1",
      inputTokens: 100,
      outputTokens: 50,
      totalTokens: 150,
      costUsd: 1,
      startedAt: "2026-08-14T07:10:00.000Z", // a Friday
      hourUtc: 7,
    }),
    ev({
      id: "b",
      model: "m-1",
      harnessId: "h-2",
      harnessName: "H2",
      outputTokens: 200,
      cacheReadTokens: 100,
      totalTokens: 300,
      costUsd: 2,
      startedAt: "2026-08-14T08:10:00.000Z",
      hourUtc: 8,
    }),
    ev({
      id: "c",
      model: "m-2",
      totalTokens: 50,
      costUsd: 0.5,
      startedAt: "2026-08-15T07:10:00.000Z", // a Saturday
      hourUtc: 7,
    }),
  ];

  it("hourWeekdayGrid buckets by UTC weekday+hour", () => {
    const grid = hourWeekdayGrid(events);
    expect(grid.cells).toHaveLength(7 * 24);
    const fri7 = grid.cells[5 * 24 + 7]!; // Friday = weekday 5
    expect(fri7).toMatchObject({ weekday: 5, hour: 7, events: 1, tokens: 150 });
    expect(grid.maxTokens).toBe(300);
    expect(grid.maxEvents).toBe(1);
  });

  it("tokenMix sums every segment", () => {
    expect(tokenMix(events)).toEqual({
      input: 100,
      output: 250,
      cacheRead: 100,
      cacheWrite: 0,
      reasoning: 0,
      total: 450,
    });
  });

  it("rankShares orders by tokens with event/cost rollups", () => {
    const byModel = rankShares(events, "model");
    expect(byModel.map((r) => r.key)).toEqual(["m-1", "m-2"]);
    expect(byModel[0]).toMatchObject({ tokens: 450, events: 2, cost: 3 });
    expect(rankShares(events, "harness").map((r) => r.key)).toContain("h-1");
  });

  it("rankShares groups providers by canonical id, not display name", () => {
    const mixed = [
      ev({ id: "p1", provider: "Claude Code", providerID: "claude-code", totalTokens: 100, costUsd: 1 }),
      ev({ id: "p2", provider: "claude-code", providerID: "claude-code", totalTokens: 50, costUsd: 0.5 }),
      ev({ id: "p3", provider: "Codex", totalTokens: 25, costUsd: 0.25 }),
    ];
    const byProvider = rankShares(mixed, "provider");
    expect(byProvider.map((r) => r.key)).toEqual(["claude-code", "Codex"]);
    expect(byProvider[0]).toMatchObject({ tokens: 150, events: 2, cost: 1.5 });
  });

  it("summarizeDay + eventsOnDay slice one day", () => {
    expect(eventsOnDay(events, "2026-08-14").map((e) => e.id)).toEqual(["a", "b"]);
    const day = summarizeDay("2026-08-14", events);
    expect(day).toMatchObject({ day: "2026-08-14", events: 2, tokens: 450, cost: 3 });
    expect(day.byModel[0]).toMatchObject({ key: "m-1", tokens: 450 });
  });
});
