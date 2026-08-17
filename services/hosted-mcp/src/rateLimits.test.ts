import assert from "node:assert/strict";
import test from "node:test";
import { HttpError } from "./errors.js";
import { createInMemoryFirestore } from "./securityFixtures.js";
import { enforceRateLimit, registeredRateLimitBuckets } from "./rateLimits.js";

test("memory and code MCP buckets are explicit, not metadata fallback", () => {
  const buckets = new Set(registeredRateLimitBuckets());
  for (const bucket of [
    "memory:metadata",
    "memory:standard",
    "code:metadata",
    "code:standard",
    "code:body",
  ]) {
    assert.equal(buckets.has(bucket), true, `${bucket} must be registered explicitly`);
  }
});

test("body:standard trips 429 after the configured per-minute cap", async (context) => {
  const stableNow = Math.floor(Date.now() / 60_000) * 60_000 + 30_000;
  context.mock.timers.enable({ apis: ["Date"], now: stableNow });
  const db = createInMemoryFirestore();
  for (let i = 0; i < 30; i += 1) {
    await enforceRateLimit(db, "tenant-rl", "client-rl", "body:standard");
  }
  await assert.rejects(
    () => enforceRateLimit(db, "tenant-rl", "client-rl", "body:standard"),
    (err: unknown) =>
      err instanceof HttpError
      && err.status === 429
      && err.code === "rate_limited"
      && err.message.includes("rate limit"),
  );
});
