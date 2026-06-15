import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  providerFetch: vi.fn(),
}));

vi.mock("../providers/httpClient.js", () => ({
  providerFetch: mocks.providerFetch,
}));

import { mimoAdapter } from "../providers/mimo.js";

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as unknown as Response;
}

describe("mimo parseRemainsBuckets (characterization via fetchQuota)", () => {
  beforeEach(() => {
    mocks.providerFetch.mockReset();
  });

  it("maps a vendor model_remains array into per-model buckets (high confidence)", async () => {
    mocks.providerFetch.mockResolvedValueOnce(
      jsonResponse({
        data: {
          model_remains: [
            {
              model_name: "mimo-7b",
              current_interval_usage_count: 10,
              current_interval_total_count: 100,
              period: "monthly",
            },
            {
              name: "mimo-pro",
              used: 5,
              total: 50,
              remaining: 45,
              window: "weekly",
            },
          ],
        },
      }),
    );

    const result = await mimoAdapter.fetchQuota("tp-secret-token", "src-1", {
      region: "sgp",
    });

    expect(result.ok).toBe(true);
    expect(result.snapshot?.confidence).toBe("high");
    expect(result.snapshot?.source).toBe("MiMo Token Plan");
    expect(result.snapshot?.buckets).toEqual([
      {
        name: "mimo-7b",
        used: 10,
        limit: 100,
        remaining: 90,
        window: "monthly",
        meta: { source: "vendor_remains" },
      },
      {
        name: "mimo-pro",
        used: 5,
        limit: 50,
        remaining: 45,
        window: "weekly",
        meta: { source: "vendor_remains" },
      },
    ]);
  });

  it("falls back to an aggregate token_plan_credits bucket when no array is present", async () => {
    mocks.providerFetch.mockResolvedValueOnce(
      jsonResponse({
        used_credits: 30,
        total_credits: 200,
      }),
    );

    const result = await mimoAdapter.fetchQuota("tp-secret-token", "src-2", {
      region: "ams",
    });

    expect(result.ok).toBe(true);
    expect(result.snapshot?.confidence).toBe("high");
    expect(result.snapshot?.buckets).toEqual([
      {
        name: "token_plan_credits",
        used: 30,
        limit: 200,
        remaining: 170,
        window: "monthly",
        meta: { source: "vendor_remains" },
      },
    ]);
  });

  it("returns an empty-bucket low-confidence snapshot when remains payload is empty and no tier", async () => {
    mocks.providerFetch.mockResolvedValueOnce(jsonResponse({ data: {} }));

    const result = await mimoAdapter.fetchQuota("tp-secret-token", "src-3", {
      region: "cn",
    });

    expect(result.ok).toBe(true);
    expect(result.snapshot?.confidence).toBe("low");
    expect(result.snapshot?.buckets).toEqual([]);
  });
});
