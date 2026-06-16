import assert from "node:assert/strict";
import test from "node:test";
import { registeredRateLimitBuckets } from "./rateLimits.js";

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
