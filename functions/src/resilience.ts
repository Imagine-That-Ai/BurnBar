/**
 * Resilience infrastructure for OpenBurnBar Cloud Functions.
 *
 * Provides circuit breakers, retry-with-backoff, and timeout wrappers
 * for external service calls (Stripe, APNs, Firebase, external APIs).
 *
 * Built on `cockatiel` — a battle-tested Node.js resilience library.
 *
 * Usage:
 *   import { externalApiPolicy, stripePolicy, pushPolicy } from "./resilience.js";
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
  handleWhen,
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
const EXTERNAL_API_HALF_OPEN_AFTER_MS = 45_000;
const EXTERNAL_API_BREAKER_FAILURE_THRESHOLD = 8;
const EXTERNAL_API_RETRY_MAX_ATTEMPTS = 3;
const EXTERNAL_API_TIMEOUT_MS = 20_000;

function makeExternalApiBreaker(service: string) {
  const breaker = circuitBreaker(handleAll, {
    halfOpenAfter: EXTERNAL_API_HALF_OPEN_AFTER_MS,
    breaker: new ConsecutiveBreaker(EXTERNAL_API_BREAKER_FAILURE_THRESHOLD),
  });

  breaker.onBreak(() => {
    logError({ event: "circuit_breaker_tripped", service, state: "open" });
  });

  return breaker;
}

function makeExternalApiRetry() {
  return retry(handleAll, {
    maxAttempts: EXTERNAL_API_RETRY_MAX_ATTEMPTS,
    backoff: makeBackoff(),
  });
}

const externalBreaker = makeExternalApiBreaker("external_api");
const externalRetry = makeExternalApiRetry();
const externalTimeout = timeout(EXTERNAL_API_TIMEOUT_MS, TimeoutStrategy.Aggressive);

/** Generic external API resilience policy. */
export const externalApiPolicy: IPolicy = wrap(externalTimeout, externalRetry, externalBreaker);

/**
 * Google Play reports an already-consumed one-time product as "not owned".
 * Concurrent verification can legitimately produce that response after another
 * invocation consumed the same token. It must be re-read from Play before being
 * accepted, but it is not retryable and must not count against the provider
 * circuit breaker.
 */
export function isGooglePlayPurchaseNotOwnedError(error: unknown): boolean {
  return error instanceof Error && /product purchase is not owned by the user/i.test(error.message);
}

const googlePlayConsumeErrors = handleWhen((error) => !isGooglePlayPurchaseNotOwnedError(error));
const googlePlayConsumeBreaker = circuitBreaker(googlePlayConsumeErrors, {
  halfOpenAfter: EXTERNAL_API_HALF_OPEN_AFTER_MS,
  breaker: new ConsecutiveBreaker(EXTERNAL_API_BREAKER_FAILURE_THRESHOLD),
});
googlePlayConsumeBreaker.onBreak(() => {
  logError({
    event: "circuit_breaker_tripped",
    service: "google_play_consume",
    state: "open",
  });
});
const googlePlayConsumeRetry = retry(googlePlayConsumeErrors, {
  maxAttempts: EXTERNAL_API_RETRY_MAX_ATTEMPTS,
  backoff: makeBackoff(),
});

/** Google Play consume policy that excludes the expected already-consumed race. */
export const googlePlayConsumePolicy: IPolicy = wrap(externalTimeout, googlePlayConsumeRetry, googlePlayConsumeBreaker);

const providerPolicies = new Map<string, IPolicy>();

function normalizeProviderPolicyKey(providerKey: string): string {
  return providerKey.trim().toLowerCase() || "unknown";
}

/**
 * Provider quota HTTP policy. Each provider gets the same timeout/retry/breaker
 * shape as `externalApiPolicy`, but with isolated breaker state so a dead
 * provider cannot short-circuit unrelated providers in the same sweep.
 */
export function providerApiPolicy(providerKey: string): IPolicy {
  const normalized = normalizeProviderPolicyKey(providerKey);
  const existing = providerPolicies.get(normalized);
  if (existing) return existing;

  const policy = wrap(externalTimeout, makeExternalApiRetry(), makeExternalApiBreaker(`provider_api:${normalized}`));
  providerPolicies.set(normalized, policy);
  return policy;
}

export function resetProviderApiPoliciesForTests(): void {
  providerPolicies.clear();
}

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

// ── Convenience wrapper ───────────────────────────────────────────────────────

/**
 * Wraps any async operation with the given policy and a descriptive label.
 * Logs failures with context for easier debugging.
 */
export async function withResilience<T>(
  policy: IPolicy,
  label: string,
  fn: () => Promise<T>,
  options?: { expectedError?: (error: unknown) => boolean },
): Promise<T> {
  try {
    return await policy.execute(fn);
  } catch (err) {
    if (!options?.expectedError?.(err)) {
      logError({
        event: "resilience_failure",
        label,
        error: err instanceof Error ? err.message : String(err),
      });
    }
    throw err;
  }
}
