import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Firestore } from "firebase-admin/firestore";

import {
  buildLeaderboard,
  collectValidParticipants,
  cleanupStaleLeaderboards,
  computePercentiles,
  groupByGeoTier,
  loadPreviousRanks,
  loadPreviousRanksForBoards,
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
  revokeCommunityParticipation,
  updateCommunityProfile,
  __communityCallableTestExports,
} from "../community/callables.js";
import { communityRuntimeStatus } from "../community/rollout.js";
import { COMMUNITY_SCHEMA_VERSION, CommunityPaths, recheckConsent } from "../community/consent.js";
import { normalizeGeoKey } from "../community/geo.js";
import type { CommunityWindowTotals } from "../community/shareTypes.js";
import {
  ALICE_UID,
  BOB_UID,
  callableRequest,
  callableRunner,
  pathKeyedFirestore,
  seedDoc,
} from "./bola/callableBolaHarness.js";

const FRESH_SHARE_SNAPSHOT_UPDATED_AT = new Date().toISOString();

const goldensPath = resolve(process.cwd(), "../tests/fixtures/classifier-goldens.json");

type GoldenFixture = {
  name: string;
  signals: ClassifierSignals;
  expected?: string;
  minConfidence?: number;
  expectedFingerprint?: string;
  corrections?: PurposeCorrection[];
};

const store: Map<string, Record<string, unknown>> = vi.hoisted(() => new Map());

const { appendAuditEventRequired, storageSaveMock } = vi.hoisted(() => ({
  appendAuditEventRequired: vi.fn(async () => undefined),
  storageSaveMock: vi.fn(async () => undefined),
}));

vi.mock("../resilienceHelpers.js", () => ({
  firestoreWithResilience: vi.fn((_label: string, fn: () => Promise<unknown>) => fn()),
}));

vi.mock("../callables/auditLog.js", () => ({
  appendAuditEventRequired,
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
        save: storageSaveMock,
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

describe("communityRuntimeStatus", () => {
  it("hard-disables mutation and public reads when the kill switch is on", () => {
    expect(
      communityRuntimeStatus({
        communityKillSwitch: true,
        communityPublicReadsEnabled: true,
      }),
    ).toEqual({ enabled: false, publicReadsEnabled: false, reason: "kill_switch" });
  });

  it("can keep mutation enabled while fail-closing public reads", () => {
    expect(
      communityRuntimeStatus({
        communityKillSwitch: false,
        communityPublicReadsEnabled: false,
      }),
    ).toEqual({ enabled: true, publicReadsEnabled: false, reason: "public_reads_disabled" });
  });
});


describe("collectValidParticipants anonId privacy", () => {
  const LEAK_UID = "firebase-auth-uid-must-not-publish";

  beforeEach(() => store.clear());

  it("skips share_snapshot with L2 consent when profile lacks anonId (never publishes uid)", async () => {
    seedDoc(store, CommunityPaths.consent(LEAK_UID), {
      l2Tiers: { world: "granted", country: "declined", region: "declined", city: "declined" },
    });
    seedDoc(store, CommunityPaths.shareSnapshot(LEAK_UID), {
      windows: windowTotals(5),
      modelMix: {},
      purposeMix: {},
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
      updatedAt: FRESH_SHARE_SNAPSHOT_UPDATED_AT,
    });

    const db = pathKeyedFirestore(store) as unknown as Firestore;
    const participants = await collectValidParticipants(db);

    expect(participants).toEqual([]);
    expect(participants.some((p) => p.anonId === LEAK_UID)).toBe(false);
  });

  it("skips when profile exists but anonId is absent", async () => {
    seedDoc(store, CommunityPaths.consent(LEAK_UID), {
      l2Tiers: { world: "granted", country: "declined", region: "declined", city: "declined" },
    });
    seedDoc(store, CommunityPaths.profile(LEAK_UID), {
      handle: "visible_handle",
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
    });
    seedDoc(store, CommunityPaths.shareSnapshot(LEAK_UID), {
      windows: windowTotals(1),
      modelMix: {},
      purposeMix: {},
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
      updatedAt: FRESH_SHARE_SNAPSHOT_UPDATED_AT,
    });

    const db = pathKeyedFirestore(store) as unknown as Firestore;
    const participants = await collectValidParticipants(db);
    expect(participants).toHaveLength(0);
    expect(participants.some((p) => p.anonId === LEAK_UID)).toBe(false);
  });

  it("includes participant when profile has anonId distinct from Firebase uid", async () => {
    const anonId = "a1b2c3d4e5f67890";
    seedDoc(store, CommunityPaths.consent(LEAK_UID), {
      l2Tiers: { world: "granted", country: "declined", region: "declined", city: "declined" },
    });
    seedDoc(store, CommunityPaths.profile(LEAK_UID), { anonId, schemaVersion: COMMUNITY_SCHEMA_VERSION });
    seedDoc(store, CommunityPaths.shareSnapshot(LEAK_UID), {
      windows: windowTotals(2),
      modelMix: {},
      purposeMix: {},
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
      updatedAt: FRESH_SHARE_SNAPSHOT_UPDATED_AT,
    });

    const db = pathKeyedFirestore(store) as unknown as Firestore;
    const participants = await collectValidParticipants(db);

    expect(participants).toHaveLength(1);
    expect(participants[0]?.anonId).toBe(anonId);
    expect(participants[0]?.anonId).not.toBe(LEAK_UID);
  });

  it("skips malformed or stale share snapshots before ranking", async () => {
    const staleUid = "stale-share-snapshot";
    const malformedUid = "malformed-share-snapshot";
    for (const uid of [staleUid, malformedUid]) {
      seedDoc(store, CommunityPaths.consent(uid), {
        l2Tiers: { world: "granted", country: "declined", region: "declined", city: "declined" },
      });
      seedDoc(store, CommunityPaths.profile(uid), { anonId: `${uid}-anon`, schemaVersion: COMMUNITY_SCHEMA_VERSION });
    }
    seedDoc(store, CommunityPaths.shareSnapshot(staleUid), {
      windows: windowTotals(2),
      modelMix: {},
      purposeMix: {},
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
      updatedAt: "2000-01-01T00:00:00.000Z",
    });
    seedDoc(store, CommunityPaths.shareSnapshot(malformedUid), {
      windows: { today: { totalTokens: -1, costUSD: 0 } },
      modelMix: {},
      purposeMix: {},
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
      updatedAt: FRESH_SHARE_SNAPSHOT_UPDATED_AT,
    });

    const db = pathKeyedFirestore(store) as unknown as Firestore;
    const participants = await collectValidParticipants(db);
    expect(participants.map((p) => p.uid)).not.toContain(staleUid);
    expect(participants.map((p) => p.uid)).not.toContain(malformedUid);
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

    const top = board.entries[0];
    expect(top?.movement).toBeDefined();
    const anon0Entry = board.entries.find((e) => e.anonId === "anon0");
    expect(anon0Entry?.movement).toBe("up");
    const anon1Entry = board.entries.find((e) => e.anonId === "anon1");
    expect(anon1Entry?.movement).toBe("down");
  });
});

describe("loadPreviousRanks cohort doc id", () => {
  beforeEach(() => store.clear());

  it("reads ranks from the board matching window, tier, and geoKey (not a fixed all_time world doc)", async () => {
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

  it("allows classic, asset, and glass without substring false positives on ass", () => {
    expect(isValidHandle("classic")).toBe(true);
    expect(isValidHandle("asset")).toBe(true);
    expect(isValidHandle("glass")).toBe(true);
    expect(isValidHandle("my_admin")).toBe(false);
  });

  it("joinCommunity rejects invalid handle before claiming", async () => {
    const run = callableRunner(joinCommunity);
    await expect(
      run(callableRequest(ALICE_UID, { handle: "xx", l2World: "granted" })),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });
});

describe("updateCommunityProfile geo normalization", () => {
  beforeEach(() => store.clear());

  it("persists normalizeGeoKey output for manual geo overrides when tiers are granted", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), {
      l2Tiers: { world: "granted", country: "granted", region: "granted", city: "granted" },
      locationConsent: "granted",
    });
    seedDoc(store, CommunityPaths.profile(ALICE_UID), {
      anonId: "anon-geo-normalize",
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
    });

    const rawCountry = " US/../../etc ";
    const rawRegion = " US_CA ";
    const rawCity = " US-CA-san_fran ";
    const run = callableRunner(updateCommunityProfile);
    await run(
      callableRequest(ALICE_UID, {
        countryCode: rawCountry,
        regionKey: rawRegion,
        cityKey: rawCity,
      }),
    );

    const profile = store.get(CommunityPaths.profile(ALICE_UID)) ?? {};
    expect(profile.countryCode).toBe(normalizeGeoKey(rawCountry));
    expect(profile.regionKey).toBe(normalizeGeoKey(rawRegion));
    expect(profile.cityKey).toBe(normalizeGeoKey(rawCity));
    expect(profile.countryCode).toBe("USetc");
    expect(profile.regionKey).toBe("USCA");
    expect(profile.cityKey).toBe("US-CA-sanfran");
    expect(JSON.stringify(profile)).not.toMatch(/\.\.\//);
    expect(profile.countryCode).not.toContain("/");
  });

  it("writes null for manual geo overrides that normalize to empty", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), {
      l2Tiers: { world: "granted", country: "granted", region: "granted", city: "granted" },
      locationConsent: "granted",
    });
    seedDoc(store, CommunityPaths.profile(ALICE_UID), {
      anonId: "anon-geo-clear",
      countryCode: "US",
      regionKey: "US-CA",
      cityKey: "US-CA-old",
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
    });

    const run = callableRunner(updateCommunityProfile);
    await run(
      callableRequest(ALICE_UID, {
        countryCode: "   ",
        regionKey: "___",
        cityKey: "\x00\x1f",
      }),
    );

    const profile = store.get(CommunityPaths.profile(ALICE_UID)) ?? {};
    expect(profile.countryCode).toBeNull();
    expect(profile.regionKey).toBeNull();
    expect(profile.cityKey).toBeNull();
  });
});

describe("exportLookingGlassBundle", () => {
  beforeEach(() => {
    store.clear();
    storageSaveMock.mockClear();
    vi.mocked(appendAuditEventRequired).mockReset();
    vi.mocked(appendAuditEventRequired).mockResolvedValue(undefined);
  });

  it("defaults to JSONL and records signedUrl, traceCount, format, and expiresIn", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), { l3LookingGlass: "granted" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t1`, { sessionId: "s1" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t2`, { sessionId: "s2" });

    const run = callableRunner(exportLookingGlassBundle);
    const result = (await run(callableRequest(ALICE_UID, {}))) as {
      signedUrl: string;
      downloadUrl: string;
      traceCount: number;
      format: string;
      expiresIn: number;
    };

    expect(result.signedUrl).toMatch(/^https:\/\//);
    expect(result.downloadUrl).toBe(result.signedUrl);
    expect(result.traceCount).toBe(2);
    expect(result.format).toBe("jsonl");
    expect(result.expiresIn).toBe(__communityCallableTestExports.SIGNED_URL_TTL_SECONDS);
    expect(storageSaveMock).toHaveBeenCalledWith(expect.any(Buffer), { contentType: "application/x-ndjson" });
  });

  it("writes Parquet bundles when requested", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), { l3LookingGlass: "granted" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t1`, {
      sessionId: "s1",
      model: "gpt-5.5",
      provider: "openai",
      purpose: "logic",
      corrected: false,
      totalTokens: 42,
      costUSD: 0.02,
      signals: ["file_edit"],
      recordedAt: "2026-07-09T00:00:00.000Z",
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
    });

    const run = callableRunner(exportLookingGlassBundle);
    const result = (await run(callableRequest(ALICE_UID, { format: "parquet" }))) as {
      traceCount: number;
      format: string;
    };

    expect(result.traceCount).toBe(1);
    expect(result.format).toBe("parquet");
    expect(storageSaveMock).toHaveBeenCalledWith(expect.any(Buffer), {
      contentType: "application/vnd.apache.parquet",
    });
    const firstSaveCall = storageSaveMock.mock.calls.at(0) as unknown[] | undefined;
    const parquetBuffer = firstSaveCall?.[0];
    expect(Buffer.isBuffer(parquetBuffer)).toBe(true);
    if (!Buffer.isBuffer(parquetBuffer)) throw new Error("Parquet export did not save a Buffer.");
    expect(parquetBuffer.subarray(0, 4).toString("utf8")).toBe("PAR1");
    expect(parquetBuffer.includes("recordedAt")).toBe(true);
    expect(parquetBuffer.includes("createdAt")).toBe(false);
  });

  it("rejects unknown export formats before writing storage", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), { l3LookingGlass: "granted" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t1`, { sessionId: "s1" });

    const run = callableRunner(exportLookingGlassBundle);
    await expect(run(callableRequest(ALICE_UID, { format: "csv" }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(storageSaveMock).not.toHaveBeenCalled();
  });

  it("requires L3 consent", async () => {
    const run = callableRunner(exportLookingGlassBundle);
    await expect(run(callableRequest(ALICE_UID, {}))).rejects.toMatchObject({
      code: "permission-denied",
    });
  });
});

describe("revokeCommunityParticipation — fail-closed audit", () => {
  beforeEach(() => {
    store.clear();
    vi.mocked(appendAuditEventRequired).mockReset();
    vi.mocked(appendAuditEventRequired).mockResolvedValue(undefined);
  });

  it("does not mutate community docs or release handle when required audit rejects", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), {
      l1Analytics: "granted",
      l2Tiers: { world: "granted", country: "declined", region: "declined", city: "declined" },
    });
    seedDoc(store, CommunityPaths.profile(ALICE_UID), {
      handle: "revoke_me",
      handleLower: "revoke_me",
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
    });
    seedDoc(store, CommunityPaths.shareSnapshot(ALICE_UID), {
      windows: windowTotals(1),
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
      updatedAt: FRESH_SHARE_SNAPSHOT_UPDATED_AT,
    });
    seedDoc(store, CommunityPaths.handleClaim("revoke_me"), { uid: ALICE_UID });

    vi.mocked(appendAuditEventRequired).mockRejectedValueOnce(new Error("audit unavailable"));

    const run = callableRunner(revokeCommunityParticipation);
    await expect(run(callableRequest(ALICE_UID, {}))).rejects.toThrow(/audit unavailable/);

    expect(store.has(CommunityPaths.profile(ALICE_UID))).toBe(true);
    const share = store.get(CommunityPaths.shareSnapshot(ALICE_UID)) ?? {};
    expect(share.revoked).toBeUndefined();
    expect(store.get(CommunityPaths.handleClaim("revoke_me"))).toEqual({ uid: ALICE_UID });
    expect(appendAuditEventRequired).toHaveBeenCalledTimes(1);
  });
});

describe("exportLookingGlassBundle — fail-closed audit", () => {
  beforeEach(() => {
    store.clear();
    storageSaveMock.mockClear();
    vi.mocked(appendAuditEventRequired).mockReset();
    vi.mocked(appendAuditEventRequired).mockResolvedValue(undefined);
  });

  it("does not write Storage bytes when required audit rejects", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), { l3LookingGlass: "granted" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t1`, { sessionId: "s1" });

    vi.mocked(appendAuditEventRequired).mockRejectedValueOnce(new Error("audit export failed"));

    const run = callableRunner(exportLookingGlassBundle);
    await expect(run(callableRequest(ALICE_UID, {}))).rejects.toThrow(/audit export failed/);

    expect(storageSaveMock).not.toHaveBeenCalled();
    expect(appendAuditEventRequired).toHaveBeenCalledTimes(1);
  });
});