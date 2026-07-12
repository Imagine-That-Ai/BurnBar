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

import { providerFetch } from "../providers/httpClient.js";
import { mapWithConcurrency } from "../quotaRefreshSweep.js";
import { resetProviderApiPoliciesForTests } from "../resilience.js";

type ProviderJob = {
  provider: string;
  url: string;
};

function fetchCallsFor(fetchMock: ReturnType<typeof vi.fn>, needle: string): number {
  return fetchMock.mock.calls.filter((call) => String(call[0]).includes(needle)).length;
}

describe("provider-scoped resilience", () => {
  const fetchMock = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
    resetProviderApiPoliciesForTests();
    fetchMock.mockImplementation(async (url: string | URL) => {
      const href = String(url);
      if (href.includes("dead.example")) {
        throw new Error("dead provider offline");
      }
      return new Response("{}", { status: 200 });
    });
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("opens only the failing provider breaker while healthy providers continue in the same sweep pool", async () => {
    const jobs: ProviderJob[] = [
      ...Array.from({ length: 10 }, () => ({
        provider: "dead-provider",
        url: "https://dead.example/quota",
      })),
      { provider: "healthy-provider", url: "https://healthy.example/quota-a" },
      { provider: "healthy-provider", url: "https://healthy.example/quota-b" },
    ];
    const healthyStatuses: number[] = [];

    await mapWithConcurrency(jobs, 4, async (job) => {
      if (job.provider === "dead-provider") {
        await expect(providerFetch(job.provider, "quota", job.url)).rejects.toThrow();
        return;
      }
      const response = await providerFetch(job.provider, "quota", job.url);
      healthyStatuses.push(response.status);
    });

    expect(healthyStatuses).toEqual([200, 200]);
    expect(mocks.logError).toHaveBeenCalledWith(
      expect.objectContaining({
        event: "circuit_breaker_tripped",
        service: "provider_api:dead-provider",
      }),
    );

    const deadFetchesBeforeOpenProbe = fetchCallsFor(fetchMock, "dead.example");
    await expect(providerFetch("dead-provider", "quota", "https://dead.example/quota-late")).rejects.toThrow();
    expect(fetchCallsFor(fetchMock, "dead.example")).toBe(deadFetchesBeforeOpenProbe);

    await expect(
      providerFetch("healthy-provider", "quota", "https://healthy.example/quota-late"),
    ).resolves.toHaveProperty("status", 200);
  });
});
