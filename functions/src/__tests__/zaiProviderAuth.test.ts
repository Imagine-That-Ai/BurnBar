import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  providerFetch:
    vi.fn<(provider: string, operation: string, url: string | URL, init?: RequestInit) => Promise<Response>>(),
}));

vi.mock("../providers/httpClient.js", () => ({
  providerFetch: mocks.providerFetch,
}));

import { zaiAdapter } from "../providers/zai.js";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function requestAuthorization(callIndex: number): string | undefined {
  const options = mocks.providerFetch.mock.calls[callIndex]?.[3];
  return new Headers(options?.headers).get("Authorization") ?? undefined;
}

describe("Z.ai provider authentication", () => {
  beforeEach(() => {
    mocks.providerFetch.mockReset();
  });

  it("uses Bearer authentication for standard API credential validation", async () => {
    mocks.providerFetch.mockResolvedValueOnce(jsonResponse({ data: [{ id: "glm-4" }] }));

    const result = await zaiAdapter.testCredential("standard-api-token");

    expect(result.valid).toBe(true);
    expect(mocks.providerFetch.mock.calls[0]?.[2]).toBe("https://api.z.ai/api/paas/v4/models");
    expect(requestAuthorization(0)).toBe("Bearer standard-api-token");
  });

  it("sends the raw token to the Coding Plan monitor endpoint", async () => {
    mocks.providerFetch.mockResolvedValueOnce(
      jsonResponse({
        data: {
          quotaList: [
            {
              used: 25,
              limit: 100,
              remaining: 75,
              window: "monthly",
            },
          ],
        },
      }),
    );

    const result = await zaiAdapter.fetchQuota("coding-plan-token", "zai_default");

    expect(result.ok).toBe(true);
    expect(result.snapshot?.confidence).toBe("high");
    expect(result.snapshot?.buckets).toHaveLength(1);
    expect(mocks.providerFetch.mock.calls[0]?.[2]).toBe("https://api.z.ai/api/monitor/usage/quota/limit");
    expect(requestAuthorization(0)).toBe("coding-plan-token");
  });

  it("returns a successful empty snapshot for a valid standard API account without Coding Plan quota", async () => {
    mocks.providerFetch
      .mockResolvedValueOnce(
        jsonResponse({
          success: false,
          code: 200,
          msg: "The current user has no Coding Plan.",
        }),
      )
      .mockResolvedValueOnce(jsonResponse({ error: { message: "Not found" } }, 404))
      .mockResolvedValueOnce(jsonResponse({ data: [{ id: "glm-4" }] }));

    const result = await zaiAdapter.fetchQuota("standard-api-token", "zai_default");

    expect(result.ok).toBe(true);
    expect(result.snapshot).toMatchObject({
      source: "Z.ai standard API",
      confidence: "low",
      statusMessage: "Z.ai credentials are valid, but this account does not expose Coding Plan quota.",
      buckets: [],
    });
    expect(requestAuthorization(0)).toBe("standard-api-token");
    expect(requestAuthorization(1)).toBe("standard-api-token");
    expect(requestAuthorization(2)).toBe("Bearer standard-api-token");
    const requestedURLs = mocks.providerFetch.mock.calls.map((call) => String(call[2]));
    expect(requestedURLs.some((url) => url.includes("/user/balance"))).toBe(false);
  });

  it("still rejects a token that fails both monitor and standard API authentication", async () => {
    mocks.providerFetch
      .mockResolvedValueOnce(jsonResponse({ error: { message: "Unauthorized" } }, 401))
      .mockResolvedValueOnce(jsonResponse({ error: { message: "Unauthorized" } }, 401));

    const result = await zaiAdapter.fetchQuota("invalid-api-token", "zai_default");

    expect(result).toMatchObject({
      ok: false,
      errorCode: "auth_failed",
      errorMessage: "Unauthorized",
    });
    expect(requestAuthorization(0)).toBe("invalid-api-token");
    expect(requestAuthorization(1)).toBe("Bearer invalid-api-token");
  });
});
