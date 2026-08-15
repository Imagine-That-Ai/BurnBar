/**
 * modelInferenceFetch — paid model-inference resilience invariants:
 * exactly one attempt per call (no auto-retry of paid, non-idempotent
 * inference) and a provider-isolated breaker that cannot trip the generic
 * external-API path. Companion to providerResilience.test.ts.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  assertOutboundFetchTargetResolved: vi.fn(),
  logError: vi.fn(),
  logInfo: vi.fn(),
}));

vi.mock("../ssrfGuard.js", () => ({
  assertOutboundFetchTargetResolved: mocks.assertOutboundFetchTargetResolved,
}));

vi.mock("../logging.js", () => ({
  logError: mocks.logError,
  logInfo: mocks.logInfo,
  logWarn: vi.fn(),
}));

import { modelInferenceFetch, resilientFetch } from "../resilienceHelpers.js";
import { resetModelInferencePoliciesForTests } from "../resilience.js";

describe("model-inference resilience", () => {
  const fetchMock = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
    resetModelInferencePoliciesForTests();
    fetchMock.mockImplementation(async (url: string | URL) => {
      if (String(url).includes("dead.example")) {
        throw new Error("inference host offline");
      }
      return new Response("{}", { status: 200 });
    });
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("makes exactly ONE attempt per call — paid inference is never auto-retried", async () => {
    await expect(modelInferenceFetch("openrouter", "chat", "https://dead.example/v1")).rejects.toThrow();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("opens an isolated model_inference breaker without tripping the generic external path", async () => {
    for (let i = 0; i < 10; i += 1) {
      await expect(modelInferenceFetch("openrouter", "chat", "https://dead.example/v1")).rejects.toThrow();
    }
    expect(mocks.logError).toHaveBeenCalledWith(
      expect.objectContaining({
        event: "circuit_breaker_tripped",
        service: "model_inference:openrouter",
      }),
    );
    // The generic external-API breaker is untouched by the inference outage.
    await expect(resilientFetch("smoke", "https://healthy.example/api")).resolves.toHaveProperty("status", 200);
  });
});
