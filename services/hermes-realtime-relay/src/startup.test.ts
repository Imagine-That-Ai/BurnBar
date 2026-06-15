import assert from "node:assert/strict";
import test from "node:test";
import { verifyRedisAtStartup } from "./startup.js";

test("verifyRedisAtStartup returns true when Redis answers the ping", async () => {
  let pinged = false;
  const ok = await verifyRedisAtStartup({
    ping: async () => {
      pinged = true;
      return "PONG";
    },
  });
  assert.equal(ok, true);
  assert.equal(pinged, true);
});

test("verifyRedisAtStartup returns false when Redis is unreachable (does not throw)", async () => {
  const ok = await verifyRedisAtStartup({
    ping: async () => {
      throw new Error("ECONNREFUSED 10.0.0.3:6379");
    },
  });
  // Must resolve false rather than reject — a boot-time Redis outage should be
  // logged loudly, not crash the process into a restart loop.
  assert.equal(ok, false);
});
