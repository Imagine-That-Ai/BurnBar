import { describe, expect, it, vi, beforeEach } from "vitest";
import {
  ConsecutiveBreaker,
  ConstantBackoff,
  circuitBreaker,
  handleAll,
  handleWhen,
  retry,
  wrap,
} from "cockatiel";

vi.mock("../../../packages/functions-shared/src/logging.js", () => ({
  logError: vi.fn(),
  logInfo: vi.fn(),
}));

import { logError } from "../../../packages/functions-shared/src/logging.js";
import {
  googlePlayConsumePolicy,
  isGooglePlayPurchaseNotOwnedError,
  isRetryableError,
  stripePolicy,
  withResilience,
} from "../../../packages/functions-shared/src/resilience.js";

describe("resilience", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("withResilience logs resilience_failure and rethrows", async () => {
    await expect(
      withResilience(stripePolicy, "test.stripe", () => Promise.reject(new Error("stripe down"))),
    ).rejects.toThrow("stripe down");
    expect(logError).toHaveBeenCalledWith(
      expect.objectContaining({ event: "resilience_failure", label: "test.stripe" }),
    );
  });

  it("production stripe breaker logs circuit_breaker_tripped when open", async () => {
    const breaker = circuitBreaker(handleAll, {
      halfOpenAfter: 30_000,
      breaker: new ConsecutiveBreaker(2),
    });
    breaker.onBreak(() => {
      logError({ event: "circuit_breaker_tripped", service: "test", state: "open" });
    });
    const policy = wrap(breaker);
    const fail = () => Promise.reject(new Error("boom"));
    await expect(policy.execute(fail)).rejects.toThrow("boom");
    await expect(policy.execute(fail)).rejects.toThrow("boom");
    await expect(policy.execute(fail)).rejects.toThrow();
    expect(logError).toHaveBeenCalledWith(
      expect.objectContaining({ event: "circuit_breaker_tripped", service: "test" }),
    );
  });

  it("does not retry or error-log Google Play's expected already-consumed response", async () => {
    const operation = vi.fn(async () => {
      throw new Error("The product purchase is not owned by the user.");
    });

    await expect(
      withResilience(googlePlayConsumePolicy, "external:googleplay.products.consume", operation, {
        expectedError: isGooglePlayPurchaseNotOwnedError,
      }),
    ).rejects.toThrow("not owned by the user");

    expect(operation).toHaveBeenCalledTimes(1);
    expect(logError).not.toHaveBeenCalledWith(expect.objectContaining({ event: "resilience_failure" }));
    expect(isGooglePlayPurchaseNotOwnedError(new Error("The product purchase is not owned by the user."))).toBe(true);
  });

  describe("isRetryableError", () => {
    const cases: Array<[string, unknown, boolean]> = [
      // Stripe SDK shapes (stripe 19.x `type` discriminates).
      ["stripe connection error retries", { type: "StripeConnectionError" }, true],
      ["stripe rate-limit error retries", { type: "StripeRateLimitError", statusCode: 429 }, true],
      ["stripe API error retries", { type: "StripeAPIError", statusCode: 500 }, true],
      ["stripe card error fails fast", { type: "StripeCardError", statusCode: 402 }, false],
      ["stripe invalid-request error fails fast", { type: "StripeInvalidRequestError", statusCode: 400 }, false],
      ["stripe auth error fails fast", { type: "StripeAuthenticationError", statusCode: 401 }, false],
      ["stripe idempotency error fails fast", { type: "StripeIdempotencyError", statusCode: 400 }, false],
      // Raw HTTP statuses.
      ["HTTP 429 retries", { statusCode: 429 }, true],
      ["HTTP 503 retries", { status: 503 }, true],
      ["HTTP 409 lock conflict retries", { statusCode: 409 }, true],
      ["HTTP 400 fails fast", { statusCode: 400 }, false],
      ["HTTP 404 fails fast", { status: 404 }, false],
      // Gaxios (googleapis) shapes.
      ["gaxios 500 via response.status retries", { response: { status: 500 } }, true],
      ["gaxios 403 fails fast", { code: "403", response: { status: 403 } }, false],
      ["google rateLimitExceeded on 403 retries", {
        code: "403",
        response: { status: 403 },
        errors: [{ reason: "rateLimitExceeded" }],
      }, true],
      // Firebase Admin / HttpsError codes.
      ["messaging/server-unavailable retries", { code: "messaging/server-unavailable" }, true],
      ["messaging/quota-exceeded retries", { code: "messaging/quota-exceeded" }, true],
      ["messaging/invalid-argument fails fast", { code: "messaging/invalid-argument" }, false],
      ["messaging/registration-token-not-registered fails fast", {
        code: "messaging/registration-token-not-registered",
      }, false],
      ["bare HttpsError unavailable retries", { code: "unavailable" }, true],
      ["bare HttpsError permission-denied fails fast", { code: "permission-denied" }, false],
      // Firestore gRPC numeric codes.
      ["gRPC UNAVAILABLE (14) retries", { code: 14 }, true],
      ["gRPC PERMISSION_DENIED (7) fails fast", { code: 7 }, false],
      // Network failures.
      ["fetch TypeError with ECONNRESET cause retries", {
        name: "TypeError",
        message: "fetch failed",
        cause: { code: "ECONNRESET" },
      }, true],
      ["bare Gaxios ECONNRESET code retries", { code: "ECONNRESET" }, true],
      ["TypeError without a cause fails fast", { name: "TypeError", message: "Failed to parse URL" }, false],
      // Pre-classified markers.
      ["ApnsRetryableError retries", { name: "ApnsRetryableError", apnsStatusCode: 503 }, true],
      ["TimeoutError retries", { name: "TimeoutError" }, true],
      ["AbortError never retries", { name: "AbortError", code: 20 }, false],
      // Unknown shapes fail fast.
      ["plain Error fails fast", new Error("stripe down"), false],
      ["non-error values fail fast", "boom", false],
    ];

    it.each(cases)("%s", (_label, error, expected) => {
      expect(isRetryableError(error)).toBe(expected);
    });
  });

  describe("retryable-only retry composition", () => {
    // Mirrors the production retry builder shape without touching the shared
    // module-level breakers (their consecutive-failure counters span tests).
    function buildTestRetryPolicy() {
      return retry(handleWhen((error) => isRetryableError(error)), {
        maxAttempts: 3,
        backoff: new ConstantBackoff(0),
      });
    }

    // NOTE: cockatiel's maxAttempts counts retries after the initial attempt,
    // so maxAttempts: 3 invokes an always-failing operation 4 times total.
    it("replays a transient Stripe error up to maxAttempts", async () => {
      const operation = vi.fn(async () => {
        throw Object.assign(new Error("stripe overloaded"), {
          type: "StripeAPIError",
          statusCode: 503,
        });
      });
      await expect(buildTestRetryPolicy().execute(operation)).rejects.toThrow("stripe overloaded");
      expect(operation).toHaveBeenCalledTimes(4);
    });

    it("fails a permanent Stripe error on the first attempt", async () => {
      const operation = vi.fn(async () => {
        throw Object.assign(new Error("card declined"), {
          type: "StripeCardError",
          statusCode: 402,
        });
      });
      await expect(buildTestRetryPolicy().execute(operation)).rejects.toThrow("card declined");
      expect(operation).toHaveBeenCalledTimes(1);
    });

    it("replays a transient FCM error but not a permanent one", async () => {
      const transient = vi.fn(async () => {
        throw Object.assign(new Error("fcm unavailable"), { code: "messaging/server-unavailable" });
      });
      await expect(buildTestRetryPolicy().execute(transient)).rejects.toThrow("fcm unavailable");
      expect(transient).toHaveBeenCalledTimes(4);

      const permanent = vi.fn(async () => {
        throw Object.assign(new Error("bad token"), { code: "messaging/invalid-registration-token" });
      });
      await expect(buildTestRetryPolicy().execute(permanent)).rejects.toThrow("bad token");
      expect(permanent).toHaveBeenCalledTimes(1);
    });
  });
});
