import { beforeEach, describe, expect, it, vi } from "vitest";

const resilientFetch = vi.hoisted(() => vi.fn());

vi.mock("../resilienceHelpers.js", () => ({
  resilientFetch,
}));

import { kimiAdapter, __testing__ as kimiTesting } from "../providers/kimi.js";
import { mimoAdapter } from "../providers/mimo.js";

interface FetchCall {
  url: string;
  headers?: unknown;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function urlFrom(input: unknown): string {
  if (typeof input === "string") return input;
  if (input instanceof URL) return input.href;
  if (typeof Request !== "undefined" && input instanceof Request) return input.url;
  return String(input);
}

describe("Kimi provider regional fallback", () => {
  beforeEach(() => {
    resilientFetch.mockReset();
  });

  it("keeps trying configured hosts after a regional auth failure", async () => {
    const calls: FetchCall[] = [];
    resilientFetch.mockImplementation(async (_label: string, input: unknown, init?: RequestInit) => {
      const url = urlFrom(input);
      calls.push({ url, headers: init?.headers });
      if (url.startsWith(kimiTesting.HOSTS[0])) {
        return jsonResponse({ error: { message: "regional auth rejected" } }, 401);
      }
      return jsonResponse({ data: [{ id: "moonshot-v1-8k" }] });
    });

    const result = await kimiAdapter.testCredential("moonshot-valid-key");

    expect(result.valid).toBe(true);
    expect(calls.map((call) => call.url)).toEqual([
      `${kimiTesting.HOSTS[0]}${kimiTesting.VALIDATE_PATH}`,
      `${kimiTesting.HOSTS[1]}${kimiTesting.VALIDATE_PATH}`,
    ]);
  });

  it("tries later hosts for quota and balance probes before reporting auth_failed", async () => {
    const calls: FetchCall[] = [];
    resilientFetch.mockImplementation(async (_label: string, input: unknown, init?: RequestInit) => {
      const url = urlFrom(input);
      calls.push({ url, headers: init?.headers });
      if (url.startsWith(kimiTesting.HOSTS[0])) {
        return jsonResponse({ error: { message: "regional auth rejected" } }, 403);
      }
      if (url.endsWith("/v1/users/me/balance")) {
        return jsonResponse({ available_balance: 40, total_balance: 100, currency: "CNY" });
      }
      return jsonResponse({ data: [{ id: "moonshot-v1-8k" }, { id: "moonshot-v1-32k" }] });
    });

    const refresh = await kimiAdapter.fetchQuota("moonshot-valid-key", "acct-1");

    expect(refresh.ok).toBe(true);
    expect(refresh.snapshot?.source).toBe("Kimi balance API");
    expect(refresh.snapshot?.buckets[0]).toMatchObject({
      name: "account_balance",
      used: 60,
      limit: 100,
      remaining: 40,
    });
    expect(calls.map((call) => call.url)).toEqual([
      `${kimiTesting.HOSTS[0]}${kimiTesting.VALIDATE_PATH}`,
      `${kimiTesting.HOSTS[1]}${kimiTesting.VALIDATE_PATH}`,
      `${kimiTesting.HOSTS[0]}/v1/users/me/balance`,
      `${kimiTesting.HOSTS[1]}/v1/users/me/balance`,
    ]);
  });
});

describe("MiMo pay-as-you-go quota refresh", () => {
  beforeEach(() => {
    resilientFetch.mockReset();
  });

  it("revalidates the PAYG key against the provider before returning ok", async () => {
    const calls: FetchCall[] = [];
    resilientFetch.mockImplementation(async (_label: string, input: unknown, init?: RequestInit) => {
      calls.push({ url: urlFrom(input), headers: init?.headers });
      return jsonResponse({ data: [{ id: "mimo-payg-model" }] });
    });

    const refresh = await mimoAdapter.fetchQuota("sk-valid-payg-key", "acct-1");

    expect(refresh.ok).toBe(true);
    expect(refresh.snapshot?.buckets).toEqual([]);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe("https://api.xiaomimimo.com/v1/models");
    expect(calls[0]?.headers).toMatchObject({ Authorization: "Bearer sk-valid-payg-key" });
  });

  it("returns auth_failed for revoked PAYG keys instead of marking the account healthy", async () => {
    const calls: FetchCall[] = [];
    resilientFetch.mockImplementation(async (_label: string, input: unknown, init?: RequestInit) => {
      calls.push({ url: urlFrom(input), headers: init?.headers });
      return jsonResponse({ error: { message: "key revoked" } }, 401);
    });

    const refresh = await mimoAdapter.fetchQuota("sk-revoked-payg-key", "acct-1");

    expect(refresh.ok).toBe(false);
    expect(refresh.snapshot).toBeUndefined();
    expect(refresh.errorCode).toBe("auth_failed");
    expect(refresh.errorMessage).toBe("key revoked");
    expect(calls.map((call) => call.url)).toEqual([
      "https://api.xiaomimimo.com/v1/models",
      "https://api.xiaomimimo.com/v1/models",
    ]);
    expect(calls[0]?.headers).toMatchObject({ Authorization: "Bearer sk-revoked-payg-key" });
    expect(calls[1]?.headers).toMatchObject({ "api-key": "sk-revoked-payg-key" });
  });
});
