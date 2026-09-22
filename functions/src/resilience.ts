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
import { errorCode, isRecord } from "./guards.js";

// ── Retryable-error classification ────────────────────────────────────────────

/**
 * HTTP statuses where a retry with backoff can plausibly succeed: rate limits,
 * lock conflicts (Stripe 409 lock timeouts, Firestore/Google ABORTED), request
 * timeouts, and server faults. Every other classified status fails fast so a
 * 4xx client error is never replayed.
 */
const RETRYABLE_HTTP_STATUSES: ReadonlySet<number> = new Set([408, 409, 429, 500, 502, 503, 504]);

/** Stripe SDK error `type` values that signal a transient fault (stripe 19.x). */
const RETRYABLE_STRIPE_ERROR_TYPES: ReadonlySet<string> = new Set([
  "StripeConnectionError",
  "StripeRateLimitError",
  "StripeAPIError",
]);

/**
 * Firebase Admin SDK / HttpsError code suffixes that signal a transient fault.
 * Matches both `messaging/server-unavailable` and bare `unavailable` forms.
 */
const RETRYABLE_ERROR_CODE_SUFFIXES: ReadonlySet<string> = new Set([
  "aborted",
  "deadline-exceeded",
  "internal",
  "internal-error",
  "quota-exceeded",
  "resource-exhausted",
  "server-unavailable",
  "timeout",
  "unavailable",
]);

/**
 * gRPC status codes the Firestore client surfaces on numeric `code` for
 * transient faults: DEADLINE_EXCEEDED (4), RESOURCE_EXHAUSTED (8), ABORTED
 * (10), INTERNAL (13), UNAVAILABLE (14).
 */
const RETRYABLE_GRPC_CODES: ReadonlySet<number> = new Set([4, 8, 10, 13, 14]);

/** Node syscall failures where the network path — not the request — failed. */
const RETRYABLE_SYSCALL_CODES: ReadonlySet<string> = new Set([
  "EAI_AGAIN",
  "ECONNABORTED",
  "ECONNREFUSED",
  "ECONNRESET",
  "EHOSTDOWN",
  "EHOSTUNREACH",
  "ENETDOWN",
  "ENETRESET",
  "ENETUNREACH",
  "ENOTFOUND",
  "EPIPE",
  "ETIMEDOUT",
]);

/**
 * Google API `errors[].reason` values that mean "back off and retry" even when
 * the HTTP status is not itself retryable (Play quota errors arrive as 403).
 */
const RETRYABLE_GOOGLE_REASONS: ReadonlySet<string> = new Set([
  "backendError",
  "quotaExceeded",
  "rateLimitExceeded",
  "userRateLimitExceeded",
]);

/** Marker thrown by apnsSender for pre-classified transient APNs outcomes. */
const APNS_RETRYABLE_ERROR_NAME = "ApnsRetryableError";

const MAX_CLASSIFY_DEPTH = 3;

function numericStatus(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isInteger(value)) return value;
  if (typeof value === "string" && /^\d{3}$/.test(value.trim())) return Number(value.trim());
  return undefined;
}

/** Extracts the HTTP status from Stripe / Gaxios / fetch-wrapper error shapes. */
function httpStatusOf(record: Record<string, unknown>): number | undefined {
  return (
    numericStatus(record["status"]) ??
    numericStatus(record["statusCode"]) ??
    (isRecord(record["response"]) ? numericStatus(record["response"]["status"]) : undefined)
  );
}

function hasRetryableGoogleReason(record: Record<string, unknown>): boolean {
  const errors = record["errors"];
  if (!Array.isArray(errors)) return false;
  return errors.some((entry) => isRecord(entry) && typeof entry["reason"] === "string" && RETRYABLE_GOOGLE_REASONS.has(entry["reason"]));
}

/**
 * Returns true when `error` carries an explicit transient signal: a retryable
 * HTTP status, a transient SDK code/type (Stripe, Firebase, gRPC, Google
 * reasons), a network syscall failure, or a pre-classified marker.
 *
 * Unknown shapes fail fast (return false): an unrecognized error is more
 * likely a bug or a permanent rejection than a transient fault, and silent
 * retries would only delay the caller's own handling. Statuses checked by
 * callers via `res.ok` never reach this classifier — only thrown errors do.
 */
export function isRetryableError(error: unknown, depth = 0): boolean {
  if (!isRecord(error) || depth > MAX_CLASSIFY_DEPTH) return false;

  const name = typeof error["name"] === "string" ? error["name"] : undefined;
  // Caller-cancelled work must never be replayed.
  if (name === "AbortError") return false;
  if (name === APNS_RETRYABLE_ERROR_NAME) return true;
  if (name === "TimeoutError") return true;

  // Stripe SDK errors self-classify via `type`; authoritative for the SDK.
  const stripeType = typeof error["type"] === "string" ? error["type"] : undefined;
  if (stripeType?.startsWith("Stripe")) return RETRYABLE_STRIPE_ERROR_TYPES.has(stripeType);

  // Google quota signals can hide behind a non-retryable 403, so check reasons first.
  if (hasRetryableGoogleReason(error)) return true;

  const status = httpStatusOf(error);
  if (status !== undefined) return RETRYABLE_HTTP_STATUSES.has(status);

  const code = errorCode(error);
  if (typeof code === "number") {
    // Numeric codes are either gRPC statuses (small) or HTTP statuses.
    return code >= 100 ? RETRYABLE_HTTP_STATUSES.has(code) : RETRYABLE_GRPC_CODES.has(code);
  }
  if (typeof code === "string") {
    const trimmed = code.trim();
    const numeric = numericStatus(trimmed);
    if (numeric !== undefined) return RETRYABLE_HTTP_STATUSES.has(numeric);
    if (RETRYABLE_SYSCALL_CODES.has(trimmed)) return true;
    const suffix = trimmed.includes("/") ? trimmed.slice(trimmed.lastIndexOf("/") + 1) : trimmed;
    if (RETRYABLE_ERROR_CODE_SUFFIXES.has(suffix)) return true;
  }

  // Undici fetch failures (`TypeError: fetch failed`) and Firebase SDK errors
  // carry the signal on `cause` / `error`; a missing signal fails fast.
  for (const nested of [error["cause"], error["error"]]) {
    if (isRecord(nested) && isRetryableError(nested, depth + 1)) return true;
  }
  return false;
}

/**
 * Retry filter: only transient faults are replayed. Circuit breakers
 * deliberately stay on `handleAll` — a flood of 4xx still signals an
 * unhealthy integration and should shed load, and breaker isolation tests
 * rely on every failure counting toward the trip threshold.
 */
const retryableErrors = handleWhen((error) => isRetryableError(error));

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

const stripeRetry = retry(retryableErrors, {
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

const pushRetry = retry(retryableErrors, {
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
  return retry(retryableErrors, {
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
const googlePlayConsumeRetryErrors = handleWhen(
  (error) => !isGooglePlayPurchaseNotOwnedError(error) && isRetryableError(error),
);
const googlePlayConsumeRetry = retry(googlePlayConsumeRetryErrors, {
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

// ── Model inference (paid LLM completions) ────────────────────────────────────

/**
 * Paid model-inference calls (OpenRouter usage curation): a single attempt
 * with a 60 s cap and a provider-isolated breaker.
 *
 * Deliberately NO retry wrap: a completion is paid, non-idempotent work, and a
 * timed-out attempt may still finish (and bill) upstream, so replaying it
 * could double-spend — callers release their reservation on failure instead.
 * The longer timeout exists because multimodal completions legitimately exceed
 * the generic 20 s external-API cap. The breaker is per provider key so an
 * inference outage cannot short-circuit unrelated external integrations.
 */
const MODEL_INFERENCE_TIMEOUT_MS = 60_000;
const modelInferencePolicies = new Map<string, IPolicy>();

export function modelInferencePolicy(providerKey: string): IPolicy {
  const normalized = normalizeProviderPolicyKey(providerKey);
  const existing = modelInferencePolicies.get(normalized);
  if (existing) return existing;

  const policy = wrap(
    timeout(MODEL_INFERENCE_TIMEOUT_MS, TimeoutStrategy.Aggressive),
    makeExternalApiBreaker(`model_inference:${normalized}`),
  );
  modelInferencePolicies.set(normalized, policy);
  return policy;
}

export function resetModelInferencePoliciesForTests(): void {
  modelInferencePolicies.clear();
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

const firestoreRetry = retry(retryableErrors, {
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
