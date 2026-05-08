/**
 * Provider adapter regression tests.
 *
 * Stubs `globalThis.fetch` so we can drive each adapter through the exact
 * payloads the live MiniMax/Z.ai/Factory endpoints return today (captured
 * 2026-05-06). These tests catch regressions where:
 *
 *   • The MiniMax adapter validates against `api.minimax.chat` (404) instead
 *     of `www.minimax.io/v1/token_plan/remains`.
 *   • The Z.ai adapter only probes `open.bigmodel.cn` and never hits
 *     `api.z.ai`.
 *   • Factory keeps using the dead `api.tryforge.io` host.
 */

import assert from "node:assert/strict";
import { minimaxAdapter, __testing__ as minimaxTesting } from "../lib/providers/minimax.js";
import { zaiAdapter, __testing__ as zaiTesting } from "../lib/providers/zai.js";
import { factoryAdapter, __testing__ as factoryTesting } from "../lib/providers/factory.js";

const realFetch = globalThis.fetch;
const calls = [];

function jsonResponse(body, init = {}) {
  return new Response(JSON.stringify(body), {
    status: init.status ?? 200,
    headers: { "content-type": "application/json" },
  });
}

function installFetch(handler) {
  calls.length = 0;
  globalThis.fetch = async (input, init) => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.href
          : (input && typeof input === "object" && "url" in input
              ? input.url
              : String(input));
    calls.push({ url, headers: init?.headers ?? {} });
    return handler({ url, init });
  };
}

function restoreFetch() {
  globalThis.fetch = realFetch;
}

// ---------------------------------------------------------------------------
// MiniMax — token-plan happy path
// ---------------------------------------------------------------------------

installFetch(({ url }) => {
  assert.equal(url, minimaxTesting.TOKEN_PLAN_URL, "MiniMax should validate via token_plan/remains");
  return jsonResponse({
    base_resp: { status_code: 0, status_msg: "" },
    model_remains: [
      {
        model_name: "MiniMax-M2.7",
        period: "5h",
        used: 1200,
        total: 5000,
        remains: 3800,
      },
    ],
  });
});
{
  const valid = await minimaxAdapter.testCredential("sk-some-token-456");
  assert.equal(valid.valid, true);
  assert.equal(valid.credentialKind, "bearer");
  assert.match(valid.redactedLabel, /^minimax_/);
}

installFetch(({ url }) => {
  assert.equal(url, minimaxTesting.TOKEN_PLAN_URL);
  return jsonResponse({
    base_resp: { status_code: 0 },
    model_remains: [
      { model_name: "MiniMax-M2.7", period: "weekly", used: 200, total: 1000, remains: 800 },
    ],
  });
});
{
  const refresh = await minimaxAdapter.fetchQuota("sk-some-token-456", "default");
  assert.equal(refresh.ok, true);
  assert.equal(refresh.snapshot.buckets.length, 1);
  assert.equal(refresh.snapshot.buckets[0].used, 200);
  assert.equal(refresh.snapshot.buckets[0].limit, 1000);
  assert.equal(refresh.snapshot.buckets[0].remaining, 800);
}

// ---------------------------------------------------------------------------
// MiniMax — coding-plan key prefers coding_plan/remains
// ---------------------------------------------------------------------------

installFetch(({ url }) => {
  assert.equal(url, minimaxTesting.CODING_PLAN_URL, "Coding-plan keys should hit coding_plan/remains");
  return jsonResponse({
    base_resp: { status_code: 0 },
    model_remains: [
      { model_name: "MiniMax-M2.7", period: "5h", used: 50, total: 100, remains: 50 },
    ],
  });
});
{
  const valid = await minimaxAdapter.testCredential("sk-cp-coding-plan-key");
  assert.equal(valid.valid, true);
}

// ---------------------------------------------------------------------------
// MiniMax — auth failure surfaces structured error
// ---------------------------------------------------------------------------

installFetch(() =>
  jsonResponse({
    base_resp: {
      status_code: 1004,
      status_msg: "login fail: Please carry the API secret key in the 'Authorization' field of the request header",
    },
  })
);
{
  const result = await minimaxAdapter.testCredential("not-a-real-key-12345");
  assert.equal(result.valid, false);
  assert.equal(result.errorCode, "auth_failed");
  assert.match(result.errorMessage, /login fail/);
}

// ---------------------------------------------------------------------------
// Z.ai — falls back from api.z.ai to bigmodel.cn on non-auth failure
// ---------------------------------------------------------------------------

let zaiCallCount = 0;
installFetch(({ url }) => {
  zaiCallCount += 1;
  if (zaiCallCount === 1) {
    assert.match(url, /api\.z\.ai\/api\/paas\/v4\/models/);
    return new Response("Service Unavailable", { status: 503 });
  }
  assert.match(url, /open\.bigmodel\.cn\/api\/paas\/v4\/models/);
  return jsonResponse({ data: [{ id: "glm-4.5" }] });
});
{
  const result = await zaiAdapter.testCredential("sk-test-zai-key-1234");
  assert.equal(result.valid, true);
  assert.equal(zaiCallCount, 2, "Z.ai should fall back through both candidate hosts");
}

// ---------------------------------------------------------------------------
// Z.ai — auth failure on api.z.ai short-circuits and does NOT try bigmodel.cn
// ---------------------------------------------------------------------------

zaiCallCount = 0;
installFetch(({ url }) => {
  zaiCallCount += 1;
  assert.match(url, /api\.z\.ai/);
  return jsonResponse({ error: { code: "401", message: "token expired or incorrect" } }, { status: 401 });
});
{
  const result = await zaiAdapter.testCredential("invalid-key-xxxxxxxx");
  assert.equal(result.valid, false);
  assert.equal(result.errorCode, "auth_failed");
  assert.equal(zaiCallCount, 1, "Auth failures should not roll over to the second host");
  assert.match(result.errorMessage, /token expired/);
}

// ---------------------------------------------------------------------------
// Z.ai — coding plan quota buckets normalize to QuotaBucket[]
// ---------------------------------------------------------------------------

zaiCallCount = 0;
installFetch(({ url }) => {
  zaiCallCount += 1;
  if (url.includes("/api/monitor/usage/quota/limit")) {
    return jsonResponse({
      success: true,
      code: 200,
      data: {
        quotaList: [
          { window: "5h", limit: 1000, used: 200, remaining: 800 },
          { window: "weekly", limit: 10000, used: 200, remaining: 9800 },
        ],
      },
    });
  }
  return jsonResponse({ error: { code: "404", message: "not found" } }, { status: 404 });
});
{
  const refresh = await zaiAdapter.fetchQuota("sk-zai-coding-plan", "default");
  assert.equal(refresh.ok, true);
  assert.equal(refresh.snapshot.buckets.length, 2);
  assert.equal(refresh.snapshot.buckets[0].window, "5h");
  assert.equal(refresh.snapshot.buckets[0].used, 200);
}

// ---------------------------------------------------------------------------
// Factory — talks to api.factory.ai (NOT the dead api.tryforge.io)
// ---------------------------------------------------------------------------

installFetch(({ url, init }) => {
  assert.match(url, new RegExp(`^${factoryTesting.API_HOST}/api/app/auth/me`));
  assert.equal(init?.headers?.Authorization, "Bearer factory-key-12345");
  return jsonResponse({
    user: { email: "alice@example.com" },
    organization: {
      name: "OpenBurnBar",
      subscription: { factoryTier: "Pro", orbSubscription: { plan: { name: "Factory Pro" } } },
    },
  });
});
{
  const valid = await factoryAdapter.testCredential("factory-key-12345");
  assert.equal(valid.valid, true);
  assert.equal(valid.credentialKind, "bearer");
}

installFetch(({ url }) => {
  assert.match(url, /\/api\/organization\/subscription\/usage/);
  return jsonResponse({
    usage: {
      endDate: "2026-06-01T00:00:00Z",
      standard: { userTokens: 12500, totalAllowance: 100000, usedRatio: 0.125 },
      premium: { userTokens: 0, totalAllowance: 0, usedRatio: 0 },
    },
  });
});
{
  const refresh = await factoryAdapter.fetchQuota("factory-key-12345", "default");
  assert.equal(refresh.ok, true);
  assert.equal(refresh.snapshot.buckets.length, 1, "Empty premium lane should be skipped");
  assert.equal(refresh.snapshot.buckets[0].used, 12500);
  assert.equal(refresh.snapshot.buckets[0].limit, 100000);
  assert.equal(refresh.snapshot.buckets[0].remaining, 87500);
}

// ---------------------------------------------------------------------------
// Factory — auth failures surface the API's `detail` field
// ---------------------------------------------------------------------------

installFetch(() =>
  jsonResponse(
    {
      detail: "Access token is invalid or expired. Please sign in again.",
      status: 401,
      title: "Unauthorized",
    },
    { status: 401 }
  )
);
{
  const result = await factoryAdapter.testCredential("expired-key-xxxxxx");
  assert.equal(result.valid, false);
  assert.equal(result.errorCode, "auth_failed");
  assert.match(result.errorMessage, /Access token is invalid or expired/);
}

restoreFetch();
console.log("provider adapter regression checks passed");
