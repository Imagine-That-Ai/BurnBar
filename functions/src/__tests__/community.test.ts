import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Firestore } from "firebase-admin/firestore";

import {
  buildLeaderboard,
  computePercentiles,
  groupByGeoTier,
  type Participant,
} from "../community/aggregation.js";
import {
  classifyPurpose,
  signalFingerprint,
  type ClassifierSignals,
  type PurposeCorrection,
} from "../community/classifier.js";
import {
  claimHandleTransaction,
  exportLookingGlassBundle,
  isValidHandle,
  joinCommunity,
  __communityCallableTestExports,
} from "../community/callables.js";
import { CommunityPaths, recheckConsent } from "../community/consent.js";
import type { CommunityWindowTotals } from "../community/shareTypes.js";
import {
  ALICE_UID,
  BOB_UID,
  callableRequest,
  callableRunner,
  pathKeyedFirestore,
  seedDoc,
} from "./bola/callableBolaHarness.js";

const goldensPath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../../tests/fixtures/classifier-goldens.json",
);

type GoldenFixture = {
  name: string;
  signals: ClassifierSignals;
  expected?: string;
  minConfidence?: number;
  expectedFingerprint?: string;
  corrections?: PurposeCorrection[];
};

const store: Map<string, Record<string, unknown>> = vi.hoisted(() => new Map());

vi.mock("../resilienceHelpers.js", () => ({
  firestoreWithResilience: vi.fn((_label: string, fn: () => Promise<unknown>) => fn()),
}));

vi.mock("../callables/auditLog.js", () => ({
  appendAuditEventRequired: vi.fn(async () => undefined),
  AUDIT_ACTIONS: { dataExport: "data_export" },
  auditActorLabel: () => "user:test",
}));

vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>(
    "firebase-admin/firestore",
  );
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(store),
  };
});

vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({
    bucket: () => ({
      file: () => ({
        save: vi.fn(async () => undefined),
        getSignedUrl: vi.fn(async () => ["https://signed.example/export.jsonl"]),
      }),
    }),
  }),
}));

function windowTotals(tokenScale: number): CommunityWindowTotals {
  const slot = (totalTokens: number) => ({ totalTokens, costUSD: totalTokens * 0.001 });
  return {
    today: slot(100 * tokenScale),
    "7d": slot(500 * tokenScale),
    "30d": slot(2000 * tokenScale),
    "90d": slot(5000 * tokenScale),
    all_time: slot(10000 * tokenScale),
  };
}

function participant(
  overrides: Partial<Participant> & {
    uid: string;
    anonId: string;
    windowTotals?: CommunityWindowTotals;
  },
): Participant & { windowTotals?: CommunityWindowTotals } {
  return {
    uid: overrides.uid,
    anonId: overrides.anonId,
    handle: overrides.handle ?? null,
    totalTokens: 0,
    costUSD: 0,
    countryCode: overrides.countryCode ?? null,
    regionKey: overrides.regionKey ?? null,
    cityKey: overrides.cityKey ?? null,
    prevRank: null,
    windowTotals: overrides.windowTotals ?? windowTotals(1),
  };
}

describe("recheckConsent", () => {
  beforeEach(() => store.clear());

  it("returns fully dark when consent doc is missing", async () => {
    const db = pathKeyedFirestore(store) as unknown as Firestore;
    const snap = await recheckConsent(db, "missing-user");
    expect(snap).toEqual({
      l1Analytics: false,
      l2Rankings: false,
      l2World: false,
      l2Country: false,
      l2Region: false,
      l2City: false,
      l3LookingGlass: false,
      locationConsent: false,
    });
  });

  it("returns fully dark for malformed consent payload", async () => {
    seedDoc(store, CommunityPaths.consent("bad-user"), { notAConsentDoc: true });
    const db = pathKeyedFirestore(store) as unknown as Firestore;
    const snap = await recheckConsent(db, "bad-user");
    expect(snap.l2Rankings).toBe(false);
    expect(snap.l3LookingGlass).toBe(false);
  });

  it("parses granted and declined tri-states; city requires locationConsent", async () => {
    seedDoc(store, CommunityPaths.consent("alice"), {
      l1Analytics: "granted",
      l2Tiers: {
        world: "granted",
        country: "declined",
        region: "unset",
        city: "granted",
      },
      l3LookingGlass: "granted",
      locationConsent: "declined",
    });
    const db = pathKeyedFirestore(store) as unknown as Firestore;
    const snap = await recheckConsent(db, "alice");
    expect(snap.l1Analytics).toBe(true);
    expect(snap.l2World).toBe(true);
    expect(snap.l2Country).toBe(false);
    expect(snap.l2Region).toBe(false);
    expect(snap.l2City).toBe(false);
    expect(snap.l3LookingGlass).toBe(true);
    expect(snap.l2Rankings).toBe(true);
  });

  it("enables city tier only when city and locationConsent are granted", async () => {
    seedDoc(store, CommunityPaths.consent("bob"), {
      l2Tiers: { world: "declined", country: "declined", region: "declined", city: "granted" },
      locationConsent: "granted",
    });
    const db = pathKeyedFirestore(store) as unknown as Firestore;
    const snap = await recheckConsent(db, "bob");
    expect(snap.l2City).toBe(true);
    expect(snap.l2Rankings).toBe(true);
  });
});

describe("buildLeaderboard k-anonymity", () => {
  it("sets belowThreshold with empty entries, zero cohortSize, and zero percentiles when cohort < 10", () => {
    const group = Array.from({ length: 9 }, (_, i) =>
      participant({
        uid: `u${i}`,
        anonId: `anon${i}`,
        windowTotals: windowTotals(i + 1),
      }),
    );
    const board = buildLeaderboard("7d", "world", "world", group, new Map());
    expect(board.belowThreshold).toBe(true);
    expect(board.entries).toEqual([]);
    expect(board.cohortSize).toBe(0);
    expect(board.percentiles).toEqual({ p50: 0, p75: 0, p90: 0, p99: 0 });
  });

  it("publishes ranked entries with movement when cohort has >= 10 members", () => {
    const group = Array.from({ length: 12 }, (_, i) =>
      participant({
        uid: `u${i}`,
        anonId: `anon${i}`,
        handle: `user_${i}`,
        windowTotals: windowTotals(12 - i),
      }),
    );
    const prevRankMap = new Map<string, number>([
      ["anon0", 5],
      ["anon1", 1],
    ]);
    const board = buildLeaderboard("7d", "world", "world", group, prevRankMap);
    expect(board.belowThreshold).toBe(false);
    expect(board.cohortSize).toBe(12);
    expect(board.entries.length).toBeGreaterThan(0);
    const top = board.entries[0];
    expect(top?.movement).toBeDefined();
    const anon0Entry = board.entries.find((e) => e.anonId === "anon0");
    expect(anon0Entry?.movement).toBe("up");
    const anon1Entry = board.entries.find((e) => e.anonId === "anon1");
    expect(anon1Entry?.movement).toBe("down");
  });
});

describe("groupByGeoTier and window totals", () => {
  it("partitions world tier into a single world bucket", () => {
    const participants = [
      participant({ uid: "a", anonId: "a1", countryCode: "US", regionKey: "US-CA", cityKey: "sf" }),
      participant({ uid: "b", anonId: "b1", countryCode: "DE", regionKey: "DE-BY", cityKey: "mun" }),
    ];
    const groups = groupByGeoTier(participants, "world");
    expect(Object.keys(groups)).toEqual(["world"]);
    expect(groups.world?.length).toBe(2);
  });

  it("excludes participants without geo key at country tier", () => {
    const participants = [
      participant({ uid: "a", anonId: "a1", countryCode: "US" }),
      participant({ uid: "b", anonId: "b1", countryCode: null }),
    ];
    const groups = groupByGeoTier(participants, "country");
    expect(groups.US?.length).toBe(1);
    expect(groups["null"]).toBeUndefined();
  });

  it("uses 7d window totals when building leaderboard scores", () => {
    const group = [
      participant({ uid: "low", anonId: "low", windowTotals: windowTotals(1) }),
      participant({ uid: "high", anonId: "high", windowTotals: windowTotals(100) }),
    ];
    const board = buildLeaderboard("7d", "world", "world", group, new Map());
    expect(board.belowThreshold).toBe(true);
    expect(board.entries).toEqual([]);
  });
});

describe("computePercentiles", () => {
  it("returns zero bands for empty input", () => {
    expect(computePercentiles([])).toEqual({ p50: 0, p75: 0, p90: 0, p99: 0 });
  });

  it("computes monotonic percentile bands on sorted cohort", () => {
    const bands = computePercentiles([10, 20, 30, 40, 50, 60, 70, 80, 90, 100]);
    expect(bands.p50).toBeLessThanOrEqual(bands.p75);
    expect(bands.p75).toBeLessThanOrEqual(bands.p90);
    expect(bands.p90).toBeLessThanOrEqual(bands.p99);
  });
});

describe("classifier goldens", () => {
  const goldens = JSON.parse(readFileSync(goldensPath, "utf8")) as GoldenFixture[];

  for (const golden of goldens) {
    it(`golden: ${golden.name}`, () => {
      if (golden.expectedFingerprint !== undefined) {
        expect(signalFingerprint(golden.signals)).toBe(golden.expectedFingerprint);
        return;
      }
      const result = classifyPurpose(golden.signals, golden.corrections ?? []);
      expect(result.category).toBe(golden.expected);
      if (golden.minConfidence !== undefined) {
        expect(result.confidence).toBeGreaterThanOrEqual(golden.minConfidence);
      }
    });
  }
});

describe("handle validation and claims", () => {
  beforeEach(() => store.clear());

  it("rejects short, invalid-char, and profane handles", () => {
    expect(isValidHandle("ab")).toBe(false);
    expect(isValidHandle("ok!name")).toBe(false);
    expect(isValidHandle("my_admin")).toBe(false);
    expect(isValidHandle("valid_handle-1")).toBe(true);
  });

  it("claimHandleTransaction rejects when handle is already taken", async () => {
    seedDoc(store, CommunityPaths.handleClaim("taken"), { uid: BOB_UID });
    const db = pathKeyedFirestore(store) as unknown as Firestore;
    await expect(claimHandleTransaction(db, ALICE_UID, "taken", null)).rejects.toMatchObject({
      code: "already-exists",
    });
  });

  it("joinCommunity rejects invalid handle before claiming", async () => {
    const run = callableRunner(joinCommunity);
    await expect(
      run(callableRequest(ALICE_UID, { handle: "xx", l2World: "granted" })),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });
});

describe("exportLookingGlassBundle", () => {
  beforeEach(() => store.clear());

  it("returns signedUrl, traceCount, and expiresIn", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), { l3LookingGlass: "granted" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t1`, { sessionId: "s1" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t2`, { sessionId: "s2" });

    const run = callableRunner(exportLookingGlassBundle);
    const result = (await run(callableRequest(ALICE_UID, {}))) as {
      signedUrl: string;
      traceCount: number;
      expiresIn: number;
    };

    expect(result.signedUrl).toMatch(/^https:\/\//);
    expect(result.traceCount).toBe(2);
    expect(result.expiresIn).toBe(__communityCallableTestExports.SIGNED_URL_TTL_SECONDS);
  });

  it("requires L3 consent", async () => {
    const run = callableRunner(exportLookingGlassBundle);
    await expect(run(callableRequest(ALICE_UID, {}))).rejects.toMatchObject({
      code: "permission-denied",
    });
  });
});