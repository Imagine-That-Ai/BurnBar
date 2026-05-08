import type { Redis } from "ioredis";
import type { RelayLimitsConfig } from "./config.js";
import { RelayLimitError } from "./errors.js";
import type { HermesRelaySocketRole } from "./protocol.js";

export interface RelayQuotaStore {
  reserveSocket(uid: string, role: HermesRelaySocketRole, sessionID: string): Promise<void>;
  refreshSocket(uid: string, role: HermesRelaySocketRole, sessionID: string): Promise<void>;
  releaseSocket(uid: string, role: HermesRelaySocketRole, sessionID: string): Promise<void>;
  checkFrameBytes(uid: string, bytes: number): Promise<void>;
  checkRequestStart(uid: string): Promise<void>;
  reserveInFlight(uid: string, requestID: string): Promise<void>;
  releaseInFlight(uid: string, requestID: string): Promise<void>;
}

export class RedisRelayQuotaStore implements RelayQuotaStore {
  constructor(
    private readonly redis: Redis,
    private readonly limits: RelayLimitsConfig
  ) {}

  async reserveSocket(uid: string, role: HermesRelaySocketRole, sessionID: string): Promise<void> {
    const key = socketKey(uid, role);
    const now = Date.now();
    await this.redis.zremrangebyscore(key, 0, now - this.limits.socketLeaseSeconds * 1_000);
    await this.redis.zadd(key, now, sessionID);
    await this.redis.expire(key, this.limits.socketLeaseSeconds);
    const count = await this.redis.zcard(key);
    const max = role === "host"
      ? this.limits.maxHostSocketsPerUser
      : this.limits.maxClientSocketsPerUser;
    if (count > max) {
      await this.redis.zrem(key, sessionID);
      throw new RelayLimitError("socket_limit", "Hermes realtime relay socket limit reached.");
    }
  }

  async refreshSocket(uid: string, role: HermesRelaySocketRole, sessionID: string): Promise<void> {
    const key = socketKey(uid, role);
    await this.redis.zadd(key, Date.now(), sessionID);
    await this.redis.expire(key, this.limits.socketLeaseSeconds);
  }

  async releaseSocket(uid: string, role: HermesRelaySocketRole, sessionID: string): Promise<void> {
    await this.redis.zrem(socketKey(uid, role), sessionID);
  }

  async checkFrameBytes(uid: string, bytes: number): Promise<void> {
    const key = windowKey(uid, "bytes", 60_000);
    const total = await this.redis.incrby(key, bytes);
    if (total === bytes) await this.redis.expire(key, 70);
    if (total > this.limits.maxBytesPerMinute) {
      throw new RelayLimitError("byte_rate_limit", "Hermes realtime relay byte limit reached.");
    }
  }

  async checkRequestStart(uid: string): Promise<void> {
    const key = windowKey(uid, "request-start", 60_000);
    const total = await this.redis.incr(key);
    if (total === 1) await this.redis.expire(key, 70);
    if (total > this.limits.maxRequestStartsPerMinute) {
      throw new RelayLimitError("request_rate_limit", "Hermes realtime relay request rate limit reached.");
    }
  }

  async reserveInFlight(uid: string, requestID: string): Promise<void> {
    const key = inFlightKey(uid);
    const now = Date.now();
    await this.redis.zremrangebyscore(key, 0, now - this.limits.inFlightLeaseSeconds * 1_000);
    await this.redis.zadd(key, now, requestID);
    await this.redis.expire(key, this.limits.inFlightLeaseSeconds);
    const count = await this.redis.zcard(key);
    if (count > this.limits.maxInFlightRequestsPerUser) {
      await this.redis.zrem(key, requestID);
      throw new RelayLimitError("in_flight_limit", "Hermes realtime relay in-flight request limit reached.");
    }
  }

  async releaseInFlight(uid: string, requestID: string): Promise<void> {
    await this.redis.zrem(inFlightKey(uid), requestID);
  }
}

export class NoopRelayQuotaStore implements RelayQuotaStore {
  async reserveSocket(): Promise<void> {}
  async refreshSocket(): Promise<void> {}
  async releaseSocket(): Promise<void> {}
  async checkFrameBytes(): Promise<void> {}
  async checkRequestStart(): Promise<void> {}
  async reserveInFlight(): Promise<void> {}
  async releaseInFlight(): Promise<void> {}
}

function socketKey(uid: string, role: HermesRelaySocketRole): string {
  return `hermes:quota:${uid}:sockets:${role}`;
}

function inFlightKey(uid: string): string {
  return `hermes:quota:${uid}:inflight`;
}

function windowKey(uid: string, name: string, windowMs: number): string {
  return `hermes:quota:${uid}:${name}:${Math.floor(Date.now() / windowMs)}`;
}
