import assert from "node:assert/strict";
import test from "node:test";
import type { Redis } from "ioredis";
import { RedisRelayQuotaStore } from "./quota.js";
import type { RelayLimitsConfig } from "./config.js";

class FakeRedis {
  readonly calls: Array<{ command: string; key: string; args: unknown[] }> = [];
  private readonly zsets = new Map<string, Set<string>>();
  private readonly counters = new Map<string, number>();

  async zremrangebyscore(key: string, ...args: unknown[]): Promise<number> {
    this.calls.push({ command: "zremrangebyscore", key, args });
    return 0;
  }

  async zadd(key: string, _score: number, member: string): Promise<number> {
    this.calls.push({ command: "zadd", key, args: [_score, member] });
    let members = this.zsets.get(key);
    if (!members) {
      members = new Set();
      this.zsets.set(key, members);
    }
    members.add(member);
    return 1;
  }

  async expire(key: string, seconds: number): Promise<number> {
    this.calls.push({ command: "expire", key, args: [seconds] });
    return 1;
  }

  async zcard(key: string): Promise<number> {
    this.calls.push({ command: "zcard", key, args: [] });
    return this.zsets.get(key)?.size ?? 0;
  }

  async zrem(key: string, member: string): Promise<number> {
    this.calls.push({ command: "zrem", key, args: [member] });
    this.zsets.get(key)?.delete(member);
    return 1;
  }

  async incrby(key: string, bytes: number): Promise<number> {
    this.calls.push({ command: "incrby", key, args: [bytes] });
    const next = (this.counters.get(key) ?? 0) + bytes;
    this.counters.set(key, next);
    return next;
  }

  async incr(key: string): Promise<number> {
    this.calls.push({ command: "incr", key, args: [] });
    const next = (this.counters.get(key) ?? 0) + 1;
    this.counters.set(key, next);
    return next;
  }
}

const limits: RelayLimitsConfig = {
  maxFrameBytes: 512 * 1024,
  maxHostSocketsPerUser: 2,
  maxClientSocketsPerUser: 4,
  maxRequestStartsPerMinute: 60,
  maxBytesPerMinute: 25 * 1024 * 1024,
  maxInFlightRequestsPerUser: 6,
  socketLeaseSeconds: 120,
  inFlightLeaseSeconds: 600,
};

test("separates global socket pressure from runtime-specific socket buckets", async () => {
  const redis = new FakeRedis();
  const quota = new RedisRelayQuotaStore(redis as unknown as Redis, limits);

  await quota.reserveSocket("user-1", "client", "session-1");
  await quota.reserveRuntimeSocket("user-1", "client", "session-1", "hermes");
  await quota.reserveRuntimeSocket("user-1", "client", "session-2", "pi");

  const keys = redis.calls.map((call) => call.key);
  assert.ok(keys.includes("relay:quota:user-1:sockets:client"));
  assert.ok(keys.includes("hermes:quota:user-1:sockets:client"));
  assert.ok(keys.includes("pi:quota:user-1:sockets:client"));
});

test("keeps request, byte, and in-flight quotas isolated by relay runtime", async () => {
  const redis = new FakeRedis();
  const quota = new RedisRelayQuotaStore(redis as unknown as Redis, limits);

  await quota.checkFrameBytes("user-1", 10);
  await quota.checkFrameBytes("user-1", 10, "hermes");
  await quota.checkFrameBytes("user-1", 10, "pi");
  await quota.checkRequestStart("user-1", "hermes");
  await quota.checkRequestStart("user-1", "pi");
  await quota.reserveInFlight("user-1", "req-hermes", "hermes");
  await quota.reserveInFlight("user-1", "req-pi", "pi");

  const keys = new Set(redis.calls.map((call) => call.key));
  assert.ok([...keys].some((key) => key.startsWith("relay:quota:user-1:bytes:")));
  assert.ok([...keys].some((key) => key.startsWith("hermes:quota:user-1:bytes:")));
  assert.ok([...keys].some((key) => key.startsWith("pi:quota:user-1:bytes:")));
  assert.ok([...keys].some((key) => key.startsWith("hermes:quota:user-1:request-start:")));
  assert.ok([...keys].some((key) => key.startsWith("pi:quota:user-1:request-start:")));
  assert.ok(keys.has("hermes:quota:user-1:inflight"));
  assert.ok(keys.has("pi:quota:user-1:inflight"));
});
