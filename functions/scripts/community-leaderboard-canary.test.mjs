import { strict as assert } from "node:assert";
import test from "node:test";

import {
  summarizeCanary,
  validateLiveDoc,
  validateThresholdDoc,
} from "./community-leaderboard-canary.mjs";

test("validateThresholdDoc requires belowThreshold, empty entries, and cohortSize 0", () => {
  const ok = validateThresholdDoc({
    name: "projects/p/databases/(default)/documents/community_leaderboards_public/30d/city/US-CA-SF",
    belowThreshold: true,
    entries: [],
    kThreshold: 10,
    cohortSize: 0,
  });
  assert.equal(ok.ok, true);

  const withRows = validateThresholdDoc({
    belowThreshold: true,
    entries: [{ rank: 1, anonId: "leak-1", totalTokens: 1 }],
    kThreshold: 10,
    cohortSize: 0,
  });
  assert.equal(withRows.ok, false);
  assert.ok(withRows.checks.some((c) => c.label === "entries empty" && !c.ok));
});

test("validateLiveDoc requires live cohort and anonymous entries", () => {
  const ok = validateLiveDoc(
    {
      name: "projects/p/databases/(default)/documents/community_leaderboards_public/30d/world/global",
      belowThreshold: false,
      entries: [{ rank: 1, anonId: "world-a1", totalTokens: 100 }],
      cohortSize: 12,
    },
    { expectedDocId: "30d/world/global" },
  );
  assert.equal(ok.ok, true);

  const smallCohort = validateLiveDoc({
    belowThreshold: false,
    entries: [{ rank: 1, anonId: "world-a1", totalTokens: 100 }],
    cohortSize: 9,
  });
  assert.equal(smallCohort.ok, false);
});

test("validateLiveDoc fails when revoked anonId is still present", () => {
  const result = validateLiveDoc(
    {
      belowThreshold: false,
      entries: [
        { rank: 1, anonId: "revoked-user", totalTokens: 100 },
        { rank: 2, anonId: "world-b2", totalTokens: 90 },
      ],
      cohortSize: 12,
    },
    { revokedAnonId: "revoked-user" },
  );
  assert.equal(result.ok, false);
  assert.ok(result.checks.some((c) => c.label === "revoked anonId excluded" && !c.ok));
});

test("strict mode fails when no revoked anonId is supplied for live validation", () => {
  const live = validateLiveDoc(
    {
      belowThreshold: false,
      entries: [{ rank: 1, anonId: "world-a1", totalTokens: 100 }],
      cohortSize: 12,
    },
    { strict: true },
  );
  assert.equal(live.ok, false);

  const summary = summarizeCanary(
    {
      thresholdDoc: { belowThreshold: true, entries: [], kThreshold: 10, cohortSize: 0 },
      liveDoc: {
        belowThreshold: false,
        entries: [{ rank: 1, anonId: "world-a1", totalTokens: 100 }],
        cohortSize: 12,
      },
    },
    { strict: true },
  );
  assert.equal(summary.ok, false);
});