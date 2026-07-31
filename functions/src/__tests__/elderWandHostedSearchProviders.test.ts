import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  providerFetch: vi.fn(),
  secretValues: new Map<string, string>(),
}));

vi.mock("firebase-functions/params", () => ({
  defineInt: (_name: string, options: { default?: number } = {}) => ({
    value: () => options.default ?? 0,
  }),
  defineSecret: (name: string) => ({
    value: () => mocks.secretValues.get(name) ?? "",
  }),
}));

vi.mock("../providers/httpClient.js", () => ({
  providerFetch: mocks.providerFetch,
}));

import { normalizeProviderResults, performProviderSearch } from "../elderWandHostedSearchProviders.js";

describe("elderWandHostedSearchProviders", () => {
  beforeEach(() => {
    mocks.providerFetch.mockReset();
    mocks.secretValues.clear();
    mocks.secretValues.set("PERPLEXITY_API_KEY", "pplx-test");
    mocks.secretValues.set("TAVILY_API_KEY", "tvly-test");
  });

  it("normalizes provider payloads without accepting non-HTTP URLs", () => {
    expect(
      normalizeProviderResults([
        {
          title: " Result ",
          url: "https://example.com/a",
          content: " useful snippet ",
          published_date: "2026-06-15",
        },
        {
          name: "Invalid",
          url: "javascript:alert(1)",
        },
        {
          url: "https://example.com/fallback",
          description: "fallback body",
        },
      ]),
    ).toEqual([
      {
        title: "Result",
        url: "https://example.com/a",
        snippet: "useful snippet",
        publishedAt: "2026-06-15",
      },
      {
        title: "https://example.com/fallback",
        url: "https://example.com/fallback",
        snippet: "fallback body",
      },
    ]);
  });

  it("uses Perplexity first and returns Perplexity results on success", async () => {
    mocks.providerFetch.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({
        results: [
          { title: "A", url: "https://example.com/a", snippet: "a" },
          { title: "B", url: "https://example.com/b", snippet: "b" },
        ],
      }),
    });

    const payload = await performProviderSearch("latest OpenBurnBar", 1);

    expect(payload).toEqual({
      provider: "perplexity",
      results: [{ title: "A", url: "https://example.com/a", snippet: "a" }],
      costUSD: 0.005,
    });
    expect(mocks.providerFetch).toHaveBeenCalledTimes(1);
    expect(mocks.providerFetch.mock.calls[0][0]).toBe("perplexity");
    expect(mocks.providerFetch.mock.calls[0][2]).toBe("https://api.perplexity.ai/search");
    expect(JSON.parse(mocks.providerFetch.mock.calls[0][3].body)).toEqual({
      query: "latest OpenBurnBar",
      max_results: 1,
    });
  });

  it("falls back to Tavily when Perplexity is unavailable", async () => {
    mocks.providerFetch
      .mockResolvedValueOnce({
        ok: false,
        status: 429,
        json: async () => ({}),
      })
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({
          results: [{ title: "T", url: "https://example.com/t", content: "t" }],
        }),
      });

    const payload = await performProviderSearch("fallback query", 3);

    expect(payload).toEqual({
      provider: "tavily",
      results: [{ title: "T", url: "https://example.com/t", snippet: "t" }],
      costUSD: 0.008,
    });
    expect(mocks.providerFetch.mock.calls.map((call) => call[0])).toEqual(["perplexity", "tavily"]);
    expect(mocks.providerFetch.mock.calls[1][2]).toBe("https://api.tavily.com/search");
    expect(JSON.parse(mocks.providerFetch.mock.calls[1][3].body)).toMatchObject({
      query: "fallback query",
      search_depth: "basic",
      include_answer: false,
      include_images: false,
      include_raw_content: false,
    });
  });

  it("fails closed when neither provider is configured", async () => {
    mocks.secretValues.clear();

    await expect(performProviderSearch("query", 1)).rejects.toMatchObject({
      code: "unavailable",
    });
    expect(mocks.providerFetch).not.toHaveBeenCalled();
  });
});
