import test from "node:test";
import assert from "node:assert/strict";
import {
  fetchOpenCodeQuota,
  parseOpenCodeQuota,
  parseOpenCodeQuotaWindows,
} from "../src/providers/opencode.mjs";

test("parseOpenCodeQuota extracts 5h, 7d, and monthly credit buckets", () => {
  const buckets = parseOpenCodeQuota(`
    OpenCode Go quota
    5-hour window 12% used resets in 2h
    Weekly limit 44% used resets Monday
    Monthly credits $3.25 / $20 resets Jun 1
  `);

  assert.equal(buckets.length, 3);
  assert.equal(buckets[0].window, "5h");
  assert.equal(buckets[0].remaining, 88);
  assert.equal(buckets[1].window, "7d");
  assert.equal(buckets[1].remaining, 56);
  assert.equal(buckets[2].window, "monthly");
  assert.equal(buckets[2].used, 3.25);
  assert.equal(buckets[2].limit, 20);
});

test("parseOpenCodeQuotaWindows prefers exact local SQLite 5h cost over 24h stats fallback", () => {
  const buckets = parseOpenCodeQuotaWindows({
    fiveHourCost: 0.75,
    oneDay: "Total Cost $1.50",
    sevenDay: "Total Cost $8.25",
    thirtyDay: "Total Cost $21.75",
  }, {
    fiveHour: 12,
    weekly: 30,
    monthly: 60,
  });

  assert.equal(buckets.length, 3);
  assert.equal(buckets[0].name, "OpenCode 5-hour limit");
  assert.equal(buckets[0].used, 0.75);
  assert.equal(buckets[0].limit, 12);
  assert.equal(buckets[0].window, "5h");
  assert.equal(buckets[0].meta.source, "opencode-sqlite");
  assert.equal(buckets[0].meta.isEstimated, undefined);
  assert.equal(buckets[1].used, 8.25);
  assert.equal(buckets[1].limit, 30);
  assert.equal(buckets[1].window, "7d");
  assert.equal(buckets[2].used, 21.75);
  assert.equal(buckets[2].limit, 60);
  assert.equal(buckets[2].window, "monthly");
});

test("parseOpenCodeQuotaWindows falls back to 24h stats when the local SQLite DB is unavailable", () => {
  const buckets = parseOpenCodeQuotaWindows({
    oneDay: "Total Cost $1.50",
    sevenDay: "Total Cost $8.25",
    thirtyDay: "Total Cost $21.75",
  }, {
    fiveHour: 12,
    weekly: 30,
    monthly: 60,
  });

  assert.equal(buckets[0].name, "OpenCode 5-hour limit (24h fallback)");
  assert.equal(buckets[0].used, 1.5);
  assert.equal(buckets[0].meta.source, "opencode-stats-24h-fallback");
  assert.equal(buckets[0].meta.isEstimated, true);
});

test("fetchOpenCodeQuota rejects hosted request-body credentials", async () => {
  await assert.rejects(
    fetchOpenCodeQuota({
      credential: "{\"opencode-go\":{\"key\":\"secret\"}}",
      accountID: "opencode-primary",
    }),
    /hosted credential refresh is not supported/
  );
});
