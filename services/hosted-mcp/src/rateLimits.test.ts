import assert from "node:assert/strict";
import test from "node:test";
import { registeredRateLimitBuckets } from "./rateLimits.js";

test("unregistered rate-limit bucket fails closed", async () => {
  const { enforceRateLimit } = await import("./rateLimits.js");
  const fakeDb = {
    doc: () => ({ }),
    runTransaction: async () => { throw new Error("should not run"); }
  };
  await assert.rejects(
    () => enforceRateLimit(fakeDb as never, "uid", "client", "unknown:bucket"),
    (err: unknown) => {
      assert.ok(err instanceof Error);
      assert.match(err.message, /bucket_unregistered|not registered/i);
      return true;
    }
  );
});

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
