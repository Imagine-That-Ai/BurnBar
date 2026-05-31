import { describe, expect, it, vi, beforeEach } from "vitest";
import { ConsecutiveBreaker, circuitBreaker, handleAll, wrap } from "cockatiel";

vi.mock("../logging.js", () => ({
  logError: vi.fn(),
  logInfo: vi.fn(),
}));

import { logError } from "../logging.js";
import { withResilience, stripePolicy } from "../resilience.js";

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
});
