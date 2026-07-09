/**
 * Characterization pin for `kimiAdapter.fetchQuota` (U11 complexity refactor).
 *
 * Records the CURRENT observable behavior of `fetchQuota` across the
 * representative branches:
 *   • credential-validation failure (auth_failed short-circuits hosts),
 *   • full balance payload (available + total) -> high-confidence balance bucket,
 *   • models-accessible fallback when the balance endpoint returns no usable data.
 *
 * The refactor extracts cohesive helpers; this test guarantees the relocations
 * are pure (identical inputs -> identical snapshot/return shape, including the
 * exact errorCode/errorMessage on the failure path).
 *
 * `kimiAdapter` reaches the network only through `providerFetch` ->
 * `providerResilientFetch`, so we mock `../resilienceHelpers.js` and route per-URL.
 */

import { describe, expect, it, vi, beforeEach } from "vitest";

const providerResilientFetch = vi.fn();

vi.mock("../resilienceHelpers.js", () => ({
  providerResilientFetch,
}));

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("kimiAdapter.fetchQuota characterization (U11)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns a failure result with auth_failed when /v1/models rejects the key", async () => {
    providerResilientFetch.mockImplementation(async (_provider: string, _label: string, url: string | URL) => {
      const u = String(url);
      if (u.endsWith("/v1/models")) {
        return jsonResponse(401, { error: { message: "Invalid API key." } });
      }
      throw new Error(`unexpected url ${u}`);
    });

    const { kimiAdapter } = await import("../providers/kimi.js");
    const result = await kimiAdapter.fetchQuota("sk-bad-credential", "default");

    expect(result).toEqual({
      ok: false,
      errorCode: "auth_failed",
      errorMessage: "Invalid API key.",
    });
  });

  it("produces a high-confidence account_balance bucket from a full balance payload", async () => {
    providerResilientFetch.mockImplementation(async (_provider: string, _label: string, url: string | URL) => {
      const u = String(url);
      if (u.endsWith("/v1/models")) {
        return jsonResponse(200, { data: [{ id: "kimi-k2" }, { id: "moonshot-v1-8k" }] });
      }
      if (u.endsWith("/v1/users/me/balance")) {
        return jsonResponse(200, {
          available_balance: 40,
          used_balance: 60,
          total_balance: 100,
          currency: "CNY",
        });
      }
      throw new Error(`unexpected url ${u}`);
    });

    const { kimiAdapter } = await import("../providers/kimi.js");
    const result = await kimiAdapter.fetchQuota("sk-good-credential", "plan-1");

    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("expected ok result");
    const snapshot = result.snapshot;
    expect(snapshot).toBeDefined();
    if (!snapshot) throw new Error("expected snapshot");

    expect(snapshot.sourceKind).toBe("provider");
    expect(snapshot.sourceId).toBe("plan-1");
    expect(snapshot.provider).toBe("kimi");
    expect(snapshot.source).toBe("Kimi balance API");
    expect(snapshot.confidence).toBe("high");
    expect(snapshot.statusMessage).toBe("Fetched account balance from Kimi.");
    expect(snapshot.buckets).toEqual([
      {
        name: "account_balance",
        used: 60,
        limit: 100,
        remaining: 40,
        window: "monthly",
        meta: { currency: "CNY" },
      },
    ]);
  });

  it("falls back to a models bucket (medium confidence) when balance data is unusable", async () => {
    providerResilientFetch.mockImplementation(async (_provider: string, _label: string, url: string | URL) => {
      const u = String(url);
      if (u.endsWith("/v1/models")) {
        return jsonResponse(200, { data: [{ id: "kimi-k2" }, { id: "moonshot-v1-8k" }, { id: "moonshot-v1-32k" }] });
      }
      if (u.endsWith("/v1/users/me/balance")) {
        return jsonResponse(404, { error: { message: "not found" } });
      }
      throw new Error(`unexpected url ${u}`);
    });

    const { kimiAdapter } = await import("../providers/kimi.js");
    const result = await kimiAdapter.fetchQuota("sk-good-credential", "default");

    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("expected ok result");
    const snapshot = result.snapshot;
    if (!snapshot) throw new Error("expected snapshot");

    expect(snapshot.source).toBe("Kimi /v1/models");
    expect(snapshot.confidence).toBe("medium");
    expect(snapshot.statusMessage).toBe("Kimi key verified; balance endpoint did not return usable quota data.");
    expect(snapshot.buckets).toEqual([
      {
        name: "models",
        used: 0,
        limit: 3,
        remaining: 3,
        window: "static",
        meta: { unit: "models", modelsAccessible: 3 },
      },
    ]);
  });
});
