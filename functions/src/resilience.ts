/**
 * Resilience infrastructure for OpenBurnBar Cloud Functions.
 *
 * Provides circuit breakers, retry-with-backoff, and timeout wrappers
 * for external service calls (Stripe, APNs, Firebase, external APIs).
 *
 * Built on `cockatiel` — a battle-tested Node.js resilience library.
 *
 * Usage:
 *   import { externalApiPolicy, stripePolicy, apnsPolicy } from "./resilience.js";
 *
 *   // Wrap any external call:
 *   const result = await externalApiPolicy.execute(() => callExternalApi());
 *
 *   // Or with specific policies chained together:
 *   const result = await stripePolicy.execute(() => stripe.charges.create(...));
 */

import {
  circuitBreaker,
  ConsecutiveBreaker,
  ExponentialBackoff,
  handleAll,
  IPolicy,
  retry,
  timeout,
  TimeoutStrategy,
  wrap,
  bulkhead,
} from "cockatiel";
import { logError, logInfo } from "./logging.js";

// ── Shared backoff strategy ───────────────────────────────────────────────────

/**
 * Exponential backoff: initial 250ms, doubles each attempt, capped at 30s.
 * Adds jitter to prevent thundering herd on mass failures.
 */
function makeBackoff() {
  return new ExponentialBackoff({
    initialDelay: 250,
    maxDelay: 30_000,
  });
}

// ── Stripe circuit breaker ────────────────────────────────────────────────────

/**
 * Stripe policy: retry 3 times with exponential backoff, circuit breaks after
 * 5 consecutive failures (trips for 30s).
 *
 * Stripe's own idempotency keys make retries safe.
 */
const stripeBreaker = circuitBreaker(handleAll, {
  halfOpenAfter: 30_000,
  breaker: new ConsecutiveBreaker(5),
});

stripeBreaker.onBreak(() => {
  logError({ event: "circuit_breaker_tripped", service: "stripe", state: "open" });
});

stripeBreaker.onReset(() => {
  logInfo({ event: "circuit_breaker_reset", service: "stripe", state: "closed" });
});

const stripeRetry = retry(handleAll, {
  maxAttempts: 3,
  backoff: makeBackoff(),
});

const stripeTimeout = timeout(15_000, TimeoutStrategy.Aggressive);

/** Stripe-specific resilience policy: timeout → retry → circuit breaker. */
export const stripePolicy: IPolicy = wrap(stripeTimeout, stripeRetry, stripeBreaker);

// ── APNs / FCM circuit breaker ────────────────────────────────────────────────

/**
 * Push notification policy: retry 2 times, circuit breaks after 10 failures
 * (trips for 60s). Push is fire-and-forget so aggressive retry is not needed.
 */
const pushBreaker = circuitBreaker(handleAll, {
  halfOpenAfter: 60_000,
  breaker: new ConsecutiveBreaker(10),
});

pushBreaker.onBreak(() => {
  logError({ event: "circuit_breaker_tripped", service: "push", state: "open" });
});

const pushRetry = retry(handleAll, {
  maxAttempts: 2,
  backoff: makeBackoff(),
});

const pushTimeout = timeout(10_000, TimeoutStrategy.Aggressive);

/** APNs/FCM push notification resilience policy. */
export const pushPolicy: IPolicy = wrap(pushTimeout, pushRetry, pushBreaker);

// ── External API (generic) circuit breaker ────────────────────────────────────

/**
 * Generic external API policy: retry 3 times, circuit breaks after 8 failures.
 * Use for OpenTimestamps, external webhooks, and other third-party HTTP calls.
 */
const externalBreaker = circuitBreaker(handleAll, {
  halfOpenAfter: 45_000,
  breaker: new ConsecutiveBreaker(8),
});

externalBreaker.onBreak(() => {
  logError({ event: "circuit_breaker_tripped", service: "external_api", state: "open" });
});

const externalRetry = retry(handleAll, {
  maxAttempts: 3,
  backoff: makeBackoff(),
});

const externalTimeout = timeout(20_000, TimeoutStrategy.Aggressive);

/** Generic external API resilience policy. */
export const externalApiPolicy: IPolicy = wrap(externalTimeout, externalRetry, externalBreaker);

// ── Firestore circuit breaker ─────────────────────────────────────────────────

/**
 * Firestore policy: retry 5 times (Firestore transient errors are common),
 * circuit breaks after 15 consecutive failures (trips for 15s).
 * Lighter bulkhead: max 50 concurrent Firestore calls to prevent GRPC saturation.
 */
const firestoreBreaker = circuitBreaker(handleAll, {
  halfOpenAfter: 15_000,
  breaker: new ConsecutiveBreaker(15),
});

firestoreBreaker.onBreak(() => {
  logError({ event: "circuit_breaker_tripped", service: "firestore", state: "open" });
});

const firestoreRetry = retry(handleAll, {
  maxAttempts: 5,
  backoff: makeBackoff(),
});

const firestoreBulkhead = bulkhead(50, 25);
const firestoreTimeout = timeout(10_000, TimeoutStrategy.Cooperative);

/** Firestore resilience policy. */
export const firestorePolicy: IPolicy = wrap(firestoreTimeout, firestoreBulkhead, firestoreRetry, firestoreBreaker);

// ── Quota refresh circuit breaker ─────────────────────────────────────────────

/**
 * Provider quota refresh policy: retry 2 times with generous backoff.
 * Circuit breaks after 5 failures — quota refresh is a periodic background job.
 */
const quotaBreaker = circuitBreaker(handleAll, {
  halfOpenAfter: 120_000, // 2 minutes — quota providers are slow to recover
  breaker: new ConsecutiveBreaker(5),
});

const quotaRetry = retry(handleAll, {
  maxAttempts: 2,
  backoff: makeBackoff(),
});

const quotaTimeout = timeout(30_000, TimeoutStrategy.Aggressive);

/** Provider quota refresh resilience policy. */
export const quotaPolicy: IPolicy = wrap(quotaTimeout, quotaRetry, quotaBreaker);

// ── Convenience wrapper ───────────────────────────────────────────────────────

/**
 * Wraps any async operation with the given policy and a descriptive label.
 * Logs failures with context for easier debugging.
 */
export async function withResilience<T>(policy: IPolicy, label: string, fn: () => Promise<T>): Promise<T> {
  try {
    return await policy.execute(fn);
  } catch (err) {
    logError({
      event: "resilience_failure",
      label,
      error: err instanceof Error ? err.message : String(err),
    });
    throw err;
  }
}
