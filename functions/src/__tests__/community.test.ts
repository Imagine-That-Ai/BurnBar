import { resolve } from "node:path";

import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  buildLeaderboard,
  collectValidParticipants,
  computePercentiles,
  groupByGeoTier,
  leaderboardRecord,
  type Participant,
  type PreviousBoardHistory,
} from "../community/aggregation.js";
import { classifyPurpose, signalFingerprint } from "../community/classifier.js";
import { isValidHandle, joinCommunity, updateCommunityProfile } from "../community/callables.js";
import { communityRuntimeStatus } from "../community/rollout.js";
import { COMMUNITY_SCHEMA_VERSION, CommunityPaths, recheckConsent } from "../community/consent.js";
import { normalizeGeoKey } from "../community/geo.js";
import type { CommunityWindowTotals } from "../types/generated/community.js";
import { communityDb, loadGoldenFixtures } from "./support/communityTestGuards.js";
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

const store: Map<string, Record<string, unknown>> = vi.hoisted(() => new Map());

const { appendAuditEventRequired } = vi.hoisted(() => ({
  appendAuditEventRequired: vi.fn(async () => undefined),
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
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(store),
  };
});

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
    const db = communityDb(store);
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
    const db = communityDb(store);
    const snap = await recheckConsent(db, "bad-user");
    expect(snap.l2Rankings).toBe(false);
    expect(snap.l3LookingGlass).toBe(false);
  });

  it("parses granted and declined tri-states; city requires locationConsent", async () => {
    seedDoc(store, CommunityPaths.consent("alice"), {
      l1Analytics: "granted",
      l2Rankings: "granted",
      l2Tiers: {
        world: "granted",
        country: "declined",
        region: "unset",
        city: "granted",
      },
      l3LookingGlass: "granted",
      locationConsent: "declined",
    });
    const db = communityDb(store);
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
      l2Rankings: "granted",
      l2Tiers: { world: "declined", country: "declined", region: "declined", city: "granted" },
      locationConsent: "granted",
    });
    const db = communityDb(store);
    const snap = await recheckConsent(db, "bob");
    expect(snap.l2City).toBe(true);
    expect(snap.l2Rankings).toBe(true);
  });

  it("fails closed when tier grants exist without the top-level L2 gate", async () => {
    for (const [uid, l2Rankings] of [
      ["carol", undefined],
      ["dave", "declined"],
    ] as const) {
      seedDoc(store, CommunityPaths.consent(uid), {
        ...(l2Rankings ? { l2Rankings } : {}),
        l2Tiers: { world: "granted", country: "granted", region: "declined", city: "declined" },
        locationConsent: "granted",
      });
    }

    const db = communityDb(store);
    for (const uid of ["carol", "dave"]) {
      await expect(recheckConsent(db, uid)).resolves.toMatchObject({ l2Rankings: false, l2World: false });
    }
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
      l2Rankings: "granted",
      l2Tiers: { world: "granted", country: "declined", region: "declined", city: "declined" },
    });
    seedDoc(store, CommunityPaths.shareSnapshot(LEAK_UID), {
      windows: windowTotals(5),
      modelMix: {},
      purposeMix: {},
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
      updatedAt: FRESH_SHARE_SNAPSHOT_UPDATED_AT,
    });

    const db = communityDb(store);
    const participants = await collectValidParticipants(db);

    expect(participants).toEqual([]);
    expect(participants.some((p) => p.anonId === LEAK_UID)).toBe(false);
  });

  it("skips when profile exists but anonId is absent", async () => {
    seedDoc(store, CommunityPaths.consent(LEAK_UID), {
      l2Rankings: "granted",
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

    const db = communityDb(store);
    const participants = await collectValidParticipants(db);
    expect(participants).toHaveLength(0);
    expect(participants.some((p) => p.anonId === LEAK_UID)).toBe(false);
  });

  it("includes participant when profile has anonId distinct from Firebase uid", async () => {
    const anonId = "a1b2c3d4e5f67890";
    seedDoc(store, CommunityPaths.consent(LEAK_UID), {
      l2Rankings: "granted",
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

    const db = communityDb(store);
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
        l2Rankings: "granted",
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

    const db = communityDb(store);
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

  it("sets belowThreshold when cohort has exactly 9 members (k=10 boundary)", () => {
    const group = Array.from({ length: 9 }, (_, i) =>
      participant({
        uid: `b${i}`,
        anonId: `banon${i}`,
        windowTotals: windowTotals(i + 1),
      }),
    );
    const board = buildLeaderboard("7d", "world", "world", group, new Map());
    expect(board.belowThreshold).toBe(true);
    expect(board.entries).toEqual([]);
    expect(board.cohortSize).toBe(0);
  });

  it("publishes when cohort has exactly 10 members (k=10 boundary)", () => {
    const group = Array.from({ length: 10 }, (_, i) =>
      participant({
        uid: `t${i}`,
        anonId: `tanon${i}`,
        handle: `ten_${i}`,
        windowTotals: windowTotals(10 - i),
      }),
    );
    const board = buildLeaderboard("7d", "world", "world", group, new Map());
    expect(board.belowThreshold).toBe(false);
    expect(board.cohortSize).toBe(10);
    expect(board.entries).toHaveLength(10);
    for (const entry of board.entries) {
      expect(entry.movement).toBe("new");
    }
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
      ["anon2", 3],
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
    const anon2Entry = board.entries.find((e) => e.anonId === "anon2");
    expect(anon2Entry?.movement).toBe("down");
  });

  it("keeps first usable aggregate neutral until a prior board exists", () => {
    const group = Array.from({ length: 10 }, (_, i) =>
      participant({
        uid: `fresh${i}`,
        anonId: `fresh-anon${i}`,
        windowTotals: windowTotals(10 - i),
      }),
    );
    const previous: PreviousBoardHistory = { hasUsableHistory: false, positions: new Map() };

    const board = buildLeaderboard("30d", "world", "world", group, previous);

    expect(board.entries).toHaveLength(10);
    expect(board.entries.every((entry) => entry.movement === "same")).toBe(true);
  });

  it("computes movement within the stable cohort instead of raw rank churn", () => {
    const group = Array.from({ length: 100 }, (_, i) =>
      participant({
        uid: `smooth${i}`,
        anonId: `smooth-anon${i}`,
        windowTotals: windowTotals(100 - i),
      }),
    );
    const previous: PreviousBoardHistory = {
      hasUsableHistory: true,
      positions: new Map([
        ["smooth-anon0", { rank: 3, percentile: 99.2 }],
        ["smooth-anon1", { rank: 1, percentile: 99.0 }],
        ["smooth-anon2", { rank: 2, percentile: 100.0 }],
        ["smooth-anon99", { rank: 99, percentile: 2.0 }],
      ]),
    };

    const board = buildLeaderboard("30d", "world", "world", group, previous);

    expect(board.entries.find((entry) => entry.anonId === "smooth-anon0")?.movement).toBe("up");
    expect(board.entries.find((entry) => entry.anonId === "smooth-anon1")?.movement).toBe("down");
    expect(board.entries.find((entry) => entry.anonId === "smooth-anon2")?.movement).toBe("down");
    expect(board.entries.find((entry) => entry.anonId === "smooth-anon99")?.movement).toBe("same");
  });

  it("does not mark a small stable cohort down when one newcomer joins above them", () => {
    const unchanged = Array.from({ length: 12 }, (_, i) =>
      participant({
        uid: `stable${i}`,
        anonId: `stable-anon${i}`,
        windowTotals: windowTotals(12 - i),
      }),
    );
    const group = [
      participant({ uid: "newcomer", anonId: "stable-newcomer", windowTotals: windowTotals(40) }),
      ...unchanged,
    ];
    const previous: PreviousBoardHistory = {
      hasUsableHistory: true,
      positions: new Map(unchanged.map((p, index) => [p.anonId, { rank: index + 1, percentile: 0 }])),
    };

    const board = buildLeaderboard("7d", "world", "world", group, previous);

    expect(board.entries.find((entry) => entry.anonId === "stable-newcomer")?.movement).toBe("new");
    for (const entry of board.entries.filter((entry) => entry.anonId.startsWith("stable-anon"))) {
      expect(entry.movement).toBe("same");
    }
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

  it("persists kThreshold in leaderboard records for canary and client rendering", () => {
    expect(leaderboardRecord(buildLeaderboard("today", "world", "world", [], new Map())).kThreshold).toBe(10);
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
  const goldens = loadGoldenFixtures(goldensPath);

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

  it("normalizes file extension case in correction fingerprints", () => {
    expect(signalFingerprint({ fileExtensions: ["TS", "Swift"] })).toBe("ext:swift,ts");
  });
});

describe("handle validation and claims", () => {
  beforeEach(() => store.clear());

  it("rejects short, invalid-char, and profane handles", () => {
    expect(isValidHandle("ab")).toBe(false);
    expect(isValidHandle("ok!name")).toBe(false);
    expect(isValidHandle("my_admin")).toBe(false);
    expect(isValidHandle("valid_handle-1")).toBe(true);
  });

  it("joinCommunity rejects when handle is already taken", async () => {
    seedDoc(store, CommunityPaths.handleClaim("taken"), { uid: BOB_UID });
    const run = callableRunner(joinCommunity);

    await expect(
      run(callableRequest(ALICE_UID, { l2Rankings: "granted", l2World: "granted", handle: "taken" })),
    ).rejects.toMatchObject({
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
    await expect(run(callableRequest(ALICE_UID, { handle: "xx", l2World: "granted" }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
  });

  it("joinCommunity rejects non-string client fields before string operations", async () => {
    const run = callableRunner(joinCommunity);
    await expect(run(callableRequest(ALICE_UID, { handle: 123, locale: 456 }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
  });

  it("community mutations require App Check attestation", async () => {
    const run = callableRunner(joinCommunity);
    const { app: _app, ...withoutAppCheck } = callableRequest(ALICE_UID, { l2World: "granted" });
    await expect(run(withoutAppCheck)).rejects.toMatchObject({ code: "unauthenticated" });
  });

  it("joinCommunity preserves existing cityKey when city consent stays granted", async () => {
    seedDoc(store, CommunityPaths.profile(ALICE_UID), { anonId: "anon-existing-city", cityKey: "US-CA-san-francisco" });
    const run = callableRunner(joinCommunity);
    await run(
      callableRequest(ALICE_UID, {
        l2Rankings: "granted",
        l2World: "granted",
        l2City: "granted",
        locationConsent: "granted",
      }),
    );
    expect(store.get(CommunityPaths.profile(ALICE_UID))?.cityKey).toBe("US-CA-san-francisco");
  });

  it("joinCommunity clears existing cityKey when city or location consent is declined", async () => {
    seedDoc(store, CommunityPaths.profile(ALICE_UID), { anonId: "anon-existing-city", cityKey: "US-CA-san-francisco" });
    const run = callableRunner(joinCommunity);
    await run(
      callableRequest(ALICE_UID, {
        l2Rankings: "granted",
        l2World: "granted",
        l2City: "declined",
        locationConsent: "declined",
      }),
    );
    expect(store.get(CommunityPaths.profile(ALICE_UID))?.cityKey).toBeNull();
  });
});

describe("updateCommunityProfile geo normalization", () => {
  beforeEach(() => store.clear());

  it("persists normalizeGeoKey output for manual geo overrides when tiers are granted", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), {
      l2Rankings: "granted",
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

  it("ignores manual geo overrides that normalize to empty", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), {
      l2Rankings: "granted",
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
    expect(profile.countryCode).toBe("US");
    expect(profile.regionKey).toBe("US-CA");
    expect(profile.cityKey).toBe("US-CA-old");
  });

  it("does not persist city overrides when location consent is declined", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), {
      l2Rankings: "granted",
      l2Tiers: { world: "granted", country: "granted", region: "granted", city: "granted" },
      locationConsent: "declined",
    });
    seedDoc(store, CommunityPaths.profile(ALICE_UID), {
      anonId: "anon-location-declined",
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
    });

    const run = callableRunner(updateCommunityProfile);
    await run(callableRequest(ALICE_UID, { cityKey: "US-CA-san-francisco" }));

    expect(store.get(CommunityPaths.profile(ALICE_UID))?.cityKey).toBeUndefined();
  });
});
