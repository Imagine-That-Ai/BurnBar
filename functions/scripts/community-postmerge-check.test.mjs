import { strict as assert } from "node:assert";
import test from "node:test";

import {
  isActiveCommunityConsent,
  isStaleLeaderboard,
  parseArgs,
  summarizeCommunityState,
} from "./community-postmerge-check.mjs";

const NOW_MS = Date.parse("2026-01-15T12:00:00.000Z");
const STALE_MS = 48 * 60 * 60 * 1000;

test("isActiveCommunityConsent counts only explicit L2 plus tier grants", () => {
  assert.equal(
    isActiveCommunityConsent({
      l2Rankings: "granted",
      l2Tiers: { world: "granted", country: "unset", region: "unset", city: "unset" },
    }),
    true,
  );
  assert.equal(
    isActiveCommunityConsent({
      l2Rankings: "granted",
      l2Tiers: { world: "unset", country: "unset", region: "unset", city: "unset" },
    }),
    false,
  );
  assert.equal(
    isActiveCommunityConsent({
      l2Rankings: "unset",
      l2Tiers: { world: "granted", country: "granted", region: "granted", city: "granted" },
    }),
    false,
  );
});

test("summarizeCommunityState groups below-threshold boards by window and tier", () => {
  const summary = summarizeCommunityState(
    {
      communityDocs: [],
      leaderboardDocs: [
        { id: "30d/city/us-ca-sf", data: { window: "30d", tier: "city", belowThreshold: true } },
        { id: "30d/city/us-ca-oak", data: { window: "30d", tier: "city", belowThreshold: true } },
        { id: "7d/region/us-ca", data: { window: "7d", tier: "region", belowThreshold: true } },
        { id: "30d/world/global", data: { window: "30d", tier: "world", belowThreshold: false, updatedAt: NOW_MS } },
      ],
    },
    { nowMs: NOW_MS, staleMs: STALE_MS },
  );

  assert.deepEqual(summary.belowThresholdByTierWindow, {
    "30d/city": 2,
    "7d/region": 1,
  });
});

test("summarizeCommunityState identifies stale leaderboards and reports cleaned count", () => {
  const old = NOW_MS - STALE_MS - 60_000;
  const summary = summarizeCommunityState(
    {
      communityDocs: [
        {
          id: "consent",
          data: {
            l2Rankings: "granted",
            l2Tiers: { world: "granted", country: "unset", region: "unset", city: "unset" },
          },
        },
      ],
      leaderboardDocs: [
        { id: "stale-board", data: { window: "30d", tier: "world", belowThreshold: false, updatedAt: new Date(old).toISOString() } },
        { id: "fresh-board", data: { window: "7d", tier: "world", belowThreshold: false, updatedAt: new Date(NOW_MS).toISOString() } },
      ],
    },
    { nowMs: NOW_MS, staleMs: STALE_MS, cleaned: 3, includeIds: true },
  );

  assert.equal(summary.activeCommunityParticipants, 1);
  assert.equal(summary.stalePublicLeaderboards.eligible, 1);
  assert.equal(summary.stalePublicLeaderboards.cleaned, 3);
  assert.deepEqual(summary.stalePublicLeaderboards.ids, ["stale-board"]);
  assert.equal(isStaleLeaderboard({ updatedAt: old }, NOW_MS, STALE_MS), true);
});

test("parseArgs accepts --stale-hours 0 for rollback cleanup", () => {
  const options = parseArgs(["node", "script", "--stale-hours", "0"], {});
  assert.equal(options.staleHours, 0);
});

test("staleMs 0 marks every leaderboard with a timestamp as eligible", () => {
  const summary = summarizeCommunityState(
    {
      communityDocs: [],
      leaderboardDocs: [
        {
          id: "fresh-board",
          data: { window: "7d", tier: "world", belowThreshold: false, updatedAt: new Date(NOW_MS - 1).toISOString() },
        },
      ],
    },
    { nowMs: NOW_MS, staleMs: 0, includeIds: true },
  );
  assert.equal(summary.stalePublicLeaderboards.eligible, 1);
  assert.deepEqual(summary.stalePublicLeaderboards.ids, ["fresh-board"]);
});