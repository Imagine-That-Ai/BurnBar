/**
 * Contract tests for the Sentry quota-exhaustion GCP log mirror
 * (functions/src/sentry.ts — sentryBeforeSend).
 *
 * The Sentry drop for 429/RESOURCE_EXHAUSTED stays (quota noise would drown
 * real bugs), but every drop is mirrored to Cloud Logging at WARNING severity
 * under QUOTA_EXHAUSTION_LOG_EVENT so a log-based alert can page on sustained
 * quota exhaustion. The mirrored payload carries only low-cardinality,
 * non-PII fields — never the event message.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

function lastWarnJson(spy: ReturnType<typeof vi.spyOn>): Record<string, unknown> {
  const call = spy.mock.calls.at(-1);
  if (!call) throw new Error("no warning log emitted");
  const parsed: unknown = JSON.parse(String(call[0]));
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("expected a structured log object");
  }
  return parsed as Record<string, unknown>;
}

describe("sentry quota-exhaustion log mirror", () => {
  let warnSpy: ReturnType<typeof vi.spyOn>;
  let logSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.stubEnv("SENTRY_DSN", "");
    warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    // Module import with an empty DSN logs sentry_disabled via console.log.
    logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
  });

  it("pins the documented log-event name used by the GCP alert filter", async () => {
    const { QUOTA_EXHAUSTION_LOG_EVENT } = await import("../sentry.js");
    expect(QUOTA_EXHAUSTION_LOG_EVENT).toBe("quota_exhaustion_dropped_from_sentry");
    expect(logSpy).toHaveBeenCalled();
  });

  it("drops status-429 events and mirrors a structured WARNING log", async () => {
    const { sentryBeforeSend } = await import("../sentry.js");

    // @ts-expect-error reason: partial ErrorEvent fixture for drop-path test
    const result = sentryBeforeSend({ message: "callable failed", extra: { statusCode: 429 } });

    expect(result).toBeNull();
    expect(warnSpy).toHaveBeenCalledOnce();
    const payload = lastWarnJson(warnSpy);
    expect(payload.severity).toBe("WARNING");
    expect(payload.event).toBe("quota_exhaustion_dropped_from_sentry");
    expect(payload.reason).toBe("status_429");
    expect(payload.status_code).toBe(429);
    expect(payload.sentry_dropped).toBe(true);
  });

  it("drops RESOURCE_EXHAUSTED message events with a resource_exhausted reason", async () => {
    const { sentryBeforeSend } = await import("../sentry.js");

    // @ts-expect-error reason: partial ErrorEvent fixture for drop-path test
    const result = sentryBeforeSend({ message: "9 RESOURCE_EXHAUSTED: quota exceeded" });

    expect(result).toBeNull();
    expect(warnSpy).toHaveBeenCalledOnce();
    const payload = lastWarnJson(warnSpy);
    expect(payload.event).toBe("quota_exhaustion_dropped_from_sentry");
    expect(payload.reason).toBe("resource_exhausted");
    expect(payload.status_code).toBeUndefined();
  });

  it("drops rate-limit message events with a rate_limit_message reason", async () => {
    const { sentryBeforeSend } = await import("../sentry.js");

    // @ts-expect-error reason: partial ErrorEvent fixture for drop-path test
    const result = sentryBeforeSend({ message: "outer rate limit hit on token refresh" });

    expect(result).toBeNull();
    expect(warnSpy).toHaveBeenCalledOnce();
    expect(lastWarnJson(warnSpy).reason).toBe("rate_limit_message");
  });

  it("never mirrors PII: the dropped event message is not logged", async () => {
    const { sentryBeforeSend } = await import("../sentry.js");

    // @ts-expect-error reason: partial ErrorEvent fixture for drop-path test
    const result = sentryBeforeSend({ message: "RESOURCE_EXHAUSTED for alice@example.com from 10.0.0.9" });

    expect(result).toBeNull();
    const serialized = String(warnSpy.mock.calls.at(-1)?.[0] ?? "");
    expect(serialized).not.toContain("alice@example.com");
    expect(serialized).not.toContain("10.0.0.9");
    expect(serialized).not.toContain("RESOURCE_EXHAUSTED");
  });

  it("passes non-noise events through sanitized without mirroring", async () => {
    const { sentryBeforeSend } = await import("../sentry.js");

    const rawEvent = {
      message: "genuine bug",
      extra: { statusCode: 500, nested: { apiKey: "extra-api-key" } },
    };
    // @ts-expect-error reason: partial ErrorEvent fixture for pass-through test
    const result = sentryBeforeSend(rawEvent);

    expect(result).not.toBeNull();
    expect(warnSpy).not.toHaveBeenCalled();
    const nested = result?.extra?.nested as Record<string, unknown> | undefined;
    expect(nested?.apiKey).toBe("[REDACTED]");
    expect(result?.message).toBe("genuine bug");
  });

  it("classifies quota noise by status code and message text", async () => {
    const { isRateLimitNoiseEvent } = await import("../sentry.js");

    // @ts-expect-error reason: partial ErrorEvent fixtures for predicate test
    expect(isRateLimitNoiseEvent({ extra: { statusCode: 429 } })).toBe(true);
    // @ts-expect-error reason: partial ErrorEvent fixtures for predicate test
    expect(isRateLimitNoiseEvent({ extra: { statusCode: 500 } })).toBe(false);
    // @ts-expect-error reason: partial ErrorEvent fixtures for predicate test
    expect(isRateLimitNoiseEvent({ message: "boom" })).toBe(false);
    // @ts-expect-error reason: partial ErrorEvent fixtures for predicate test
    expect(isRateLimitNoiseEvent({ message: "RESOURCE_EXHAUSTED" })).toBe(true);
    // @ts-expect-error reason: partial ErrorEvent fixtures for predicate test
    expect(isRateLimitNoiseEvent({ message: "hit the rate limit" })).toBe(true);
  });
});
