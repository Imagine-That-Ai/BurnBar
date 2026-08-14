import { beforeEach, describe, expect, it, vi } from "vitest";

import { callableRunner, pathKeyedFirestore } from "./bola/callableBolaHarness.js";

const TEST_IP = "203.0.113.10";
const OTHER_IP = "198.51.100.7";

const mocks = vi.hoisted(() => ({
  fetch: vi.fn(),
  secretValues: new Map<string, string>(),
  store: new Map<string, Record<string, unknown>>(),
}));

vi.mock("firebase-functions/params", () => ({
  defineInt: (_name: string, options: { default?: number } = {}) => ({
    value: () => options.default ?? 0,
  }),
  defineSecret: (name: string) => ({
    name,
    value: () => mocks.secretValues.get(name) ?? "",
  }),
}));

vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(mocks.store),
  };
});

vi.mock("../adminRuntime.js", () => ({ db: pathKeyedFirestore(mocks.store) }));
vi.mock("../providers/httpClient.js", () => ({
  providerFetch: mocks.fetch,
}));

import {
  BENCH_ASSISTANT_SYSTEM_PROMPT,
  BENCH_CHART_DIMENSIONS,
  BENCH_CHART_METRICS,
  BENCH_CHART_TYPES,
  benchAssistant,
  sanitizeBenchChartSpec,
} from "../benchAssistant.js";
import { checkBenchAssistantRateLimit, isPublicRateLimitExceeded } from "../callables/publicRateLimit.js";

const run = callableRunner(benchAssistant);

function validPayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    schemaVersion: 1,
    question: "Which harness has the best solution rate?",
    digest: JSON.stringify({
      stacks: [{ harness: "terminal-bench", model: "gpt-x", solution_rate: 0.42, strict_rate: 0.31, n: 120 }],
    }),
    ...overrides,
  };
}

/** Public callable: no auth context, only the raw HTTP request carrying the client IP. */
function benchRequest(data: Record<string, unknown>, ip?: string): unknown {
  return {
    rawRequest: { headers: {}, ...(ip === undefined ? {} : { ip }) },
    data,
  };
}

function openRouterJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function openRouterCompletion(
  content: string,
  usage: { prompt_tokens: number; completion_tokens: number } = {
    prompt_tokens: 100,
    completion_tokens: 50,
  },
): Response {
  return openRouterJson({
    choices: [{ index: 0, message: { role: "assistant", content } }],
    usage,
  });
}

const VALID_MODEL_OUTPUT = JSON.stringify({
  answer: "**Terminal-Bench** leads the digest on solution rate (0.42 over 120 tasks).",
  chart: { type: "bar", dimension: "harness", metric: "solution_rate", title: "Solution rate by harness" },
  rowsUsed: ["terminal-bench/gpt-x"],
});

function rateLimitDocPaths(): string[] {
  return [...mocks.store.keys()].filter((key) => key.startsWith("public_rate_limits/"));
}

beforeEach(() => {
  mocks.store.clear();
  mocks.fetch.mockReset();
  mocks.fetch.mockImplementation(async () => {
    throw new Error("unexpected OpenRouter fetch");
  });
  mocks.secretValues.clear();
  mocks.secretValues.set("OPENROUTER_API_KEY", "test-openrouter-key");
});

describe("checkBenchAssistantRateLimit", () => {
  it("allows a short burst and rejects the 11th request from the same IP", async () => {
    for (let i = 0; i < 10; i += 1) {
      await expect(checkBenchAssistantRateLimit({ ip: TEST_IP })).resolves.toBeUndefined();
    }

    try {
      await checkBenchAssistantRateLimit({ ip: TEST_IP });
      expect.fail("expected bench assistant rate limit to reject");
    } catch (error) {
      expect(isPublicRateLimitExceeded(error)).toBe(true);
      expect(error).toMatchObject({ code: "resource-exhausted" });
    }
  });

  it("keys the limit per IP, so a different source is unaffected", async () => {
    for (let i = 0; i < 10; i += 1) {
      await checkBenchAssistantRateLimit({ ip: TEST_IP });
    }
    await expect(checkBenchAssistantRateLimit({ ip: OTHER_IP })).resolves.toBeUndefined();
  });

  it("falls back to the shared unknown-ip bucket when the platform supplies no IP", async () => {
    for (let i = 0; i < 10; i += 1) {
      await checkBenchAssistantRateLimit({ headers: {} });
    }
    await expect(checkBenchAssistantRateLimit({ headers: {} })).rejects.toMatchObject({
      code: "resource-exhausted",
    });
    expect(rateLimitDocPaths().some((path) => path.startsWith("public_rate_limits/bench_assistant_burst_"))).toBe(true);
  });
});

describe("benchAssistant request validation", () => {
  it("rejects a question over 2000 chars before any upstream call or quota spend", async () => {
    await expect(run(benchRequest(validPayload({ question: "x".repeat(2001) }), TEST_IP))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
    expect(rateLimitDocPaths()).toEqual([]);
  });

  it("rejects a non-1 schemaVersion", async () => {
    await expect(run(benchRequest(validPayload({ schemaVersion: 2 }), TEST_IP))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("rejects a missing question", async () => {
    const payload = validPayload();
    delete payload.question;
    await expect(run(benchRequest(payload, TEST_IP))).rejects.toMatchObject({ code: "invalid-argument" });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("rejects a digest over 24000 chars", async () => {
    await expect(run(benchRequest(validPayload({ digest: "d".repeat(24_001) }), TEST_IP))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("rejects a view over 200 chars", async () => {
    await expect(run(benchRequest(validPayload({ view: "v".repeat(201) }), TEST_IP))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });
});

describe("sanitizeBenchChartSpec", () => {
  it("accepts every closed-vocabulary enum combination", () => {
    for (const type of BENCH_CHART_TYPES) {
      for (const dimension of BENCH_CHART_DIMENSIONS) {
        for (const metric of BENCH_CHART_METRICS) {
          expect(sanitizeBenchChartSpec({ type, dimension, metric })).toEqual({ type, dimension, metric });
        }
      }
    }
  });

  it("strips unknown top-level and filter keys instead of rejecting them", () => {
    expect(
      sanitizeBenchChartSpec({
        type: "scatter",
        dimension: "model",
        metric: "cost_usd",
        rogue: "drop-me",
        filter: { harness: "terminal-bench", rogueFilter: "drop-me" },
        title: "Cost by model",
      }),
    ).toEqual({
      type: "scatter",
      dimension: "model",
      metric: "cost_usd",
      filter: { harness: "terminal-bench" },
      title: "Cost by model",
    });
  });

  it("rejects an unknown chart type", () => {
    expect(() => sanitizeBenchChartSpec({ type: "pie", dimension: "model", metric: "tokens" })).toThrow(/chart\.type/);
  });

  it("rejects an unknown dimension or metric", () => {
    expect(() => sanitizeBenchChartSpec({ type: "bar", dimension: "region", metric: "tokens" })).toThrow(
      /chart\.dimension/,
    );
    expect(() => sanitizeBenchChartSpec({ type: "bar", dimension: "model", metric: "vibes" })).toThrow(/chart\.metric/);
  });

  it("returns null for an absent chart and throws for a non-object chart", () => {
    expect(sanitizeBenchChartSpec(null)).toBeNull();
    expect(sanitizeBenchChartSpec(undefined)).toBeNull();
    expect(() => sanitizeBenchChartSpec("bar")).toThrow(/object or null/);
  });
});

describe("benchAssistant model-output handling", () => {
  it("retries once with a valid-JSON nudge and returns the second, valid reply", async () => {
    mocks.fetch
      .mockResolvedValueOnce(openRouterCompletion("sorry, I cannot help with that"))
      .mockResolvedValueOnce(openRouterCompletion(VALID_MODEL_OUTPUT));

    const response = await run<Record<string, unknown>>(benchRequest(validPayload(), TEST_IP));

    expect(mocks.fetch).toHaveBeenCalledTimes(2);
    const retryInit: RequestInit = mocks.fetch.mock.calls[1]?.[3];
    const retryBody = requestBody<{ messages: Array<{ content: string }> }>(retryInit);
    expect(retryBody.messages[1]?.content).toContain("valid JSON only");

    expect(response).toMatchObject({
      answer: "**Terminal-Bench** leads the digest on solution rate (0.42 over 120 tasks).",
      chart: { type: "bar", dimension: "harness", metric: "solution_rate", title: "Solution rate by harness" },
      rowsUsed: ["terminal-bench/gpt-x"],
      modelSlug: "openai/gpt-5.6-luna-pro",
    });
    expect(response.tokenUsage).toMatchObject({ inputTokens: 200, outputTokens: 100 });
  });

  it("falls back to a best-effort answer with a null chart after two malformed replies", async () => {
    mocks.fetch.mockImplementation(async () =>
      openRouterCompletion("The digest shows Terminal-Bench ahead on solution rate."),
    );

    const response = await run<Record<string, unknown>>(benchRequest(validPayload(), TEST_IP));

    expect(mocks.fetch).toHaveBeenCalledTimes(2);
    expect(response).toMatchObject({
      answer: "The digest shows Terminal-Bench ahead on solution rate.",
      chart: null,
      rowsUsed: [],
    });
  });

  it("returns the polite fallback when both replies are JSON but contract-invalid", async () => {
    mocks.fetch.mockImplementation(async () => openRouterCompletion(JSON.stringify({ chart: { type: "pie" } })));

    const response = await run<Record<string, unknown>>(benchRequest(validPayload(), TEST_IP));

    expect(mocks.fetch).toHaveBeenCalledTimes(2);
    expect(response).toMatchObject({ chart: null, rowsUsed: [] });
    expect(String(response.answer)).toContain("could not produce a well-formed answer");
  });
});

describe("benchAssistant rate limiting", () => {
  it("rejects with resource-exhausted before calling OpenRouter once the IP is over the burst limit", async () => {
    for (let i = 0; i < 10; i += 1) {
      await checkBenchAssistantRateLimit({ ip: TEST_IP });
    }

    await expect(run(benchRequest(validPayload(), TEST_IP))).rejects.toMatchObject({
      code: "resource-exhausted",
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });
});

describe("benchAssistant upstream failure handling", () => {
  it("maps an OpenRouter 500 to a generic unavailable error without leaking upstream detail", async () => {
    mocks.fetch.mockResolvedValue(openRouterJson({ error: { message: "upstream secret detail" } }, 500));

    await expect(run(benchRequest(validPayload(), TEST_IP))).rejects.toMatchObject({
      code: "unavailable",
      message: expect.not.stringContaining("upstream secret detail"),
    });
  });

  it("maps a transport failure to unavailable", async () => {
    mocks.fetch.mockRejectedValue(new Error("socket hang up"));

    await expect(run(benchRequest(validPayload(), TEST_IP))).rejects.toMatchObject({ code: "unavailable" });
  });

  it("fails closed with failed-precondition when the secret is unconfigured, without consuming quota", async () => {
    mocks.secretValues.delete("OPENROUTER_API_KEY");

    await expect(run(benchRequest(validPayload(), TEST_IP))).rejects.toMatchObject({
      code: "failed-precondition",
      message: expect.stringContaining("OPENROUTER_API_KEY"),
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
    expect(rateLimitDocPaths()).toEqual([]);
  });
});

interface RecordedFetch {
  provider: string;
  operation: string;
  url: string;
  init: RequestInit;
}

function recordedFetch(index = 0): RecordedFetch {
  const call: unknown[] = mocks.fetch.mock.calls[index] ?? [];
  const [provider, operation, url, init] = call;
  if (typeof provider !== "string" || typeof operation !== "string" || typeof url !== "string") {
    throw new Error(`fetch call ${index} did not record provider/operation/url`);
  }
  if (typeof init !== "object" || init === null) {
    throw new Error(`fetch call ${index} did not record a request init`);
  }
  return { provider, operation, url, init };
}

function requestHeaders(init: RequestInit): Record<string, string> {
  const headers: Record<string, string> = {};
  for (const [key, value] of Object.entries({ ...init.headers })) {
    if (typeof value === "string") headers[key] = value;
  }
  return headers;
}

function requestBody<T>(init: RequestInit): T {
  const body: T = JSON.parse(String(init.body));
  return body;
}

function tokenUsageOf(response: Record<string, unknown>): {
  inputTokens: number;
  outputTokens: number;
  estimatedCostUSD: number;
} {
  const usage = response.tokenUsage;
  if (typeof usage !== "object" || usage === null) throw new Error("response carried no tokenUsage");
  const inputTokens: unknown = Reflect.get(usage, "inputTokens");
  const outputTokens: unknown = Reflect.get(usage, "outputTokens");
  const estimatedCostUSD: unknown = Reflect.get(usage, "estimatedCostUSD");
  if (typeof inputTokens !== "number" || typeof outputTokens !== "number" || typeof estimatedCostUSD !== "number") {
    throw new Error("tokenUsage was not fully numeric");
  }
  return { inputTokens, outputTokens, estimatedCostUSD };
}

describe("benchAssistant happy path", () => {
  it("proxies to OpenRouter with the contracted request and shapes the contracted response", async () => {
    mocks.fetch.mockResolvedValue(openRouterCompletion(VALID_MODEL_OUTPUT));

    const response = await run<Record<string, unknown>>(benchRequest(validPayload({ view: "leaderboard" }), TEST_IP));

    expect(mocks.fetch).toHaveBeenCalledTimes(1);
    const { provider, operation, url, init } = recordedFetch();
    expect(provider).toBe("openrouter");
    expect(operation).toBe("bench_assistant.chat");
    expect(url).toBe("https://openrouter.ai/api/v1/chat/completions");
    expect(requestHeaders(init).Authorization).toBe("Bearer test-openrouter-key");
    const body = requestBody<{
      model: string;
      response_format: { type: string };
      messages: Array<{ role: string; content: string }>;
    }>(init);
    expect(body.model).toBe("openai/gpt-5.6-luna-pro");
    expect(body.response_format).toEqual({ type: "json_object" });
    expect(body.messages[0]?.content).toBe(BENCH_ASSISTANT_SYSTEM_PROMPT);
    expect(body.messages[1]?.content).toContain("Which harness has the best solution rate?");
    expect(body.messages[1]?.content).toContain("The user is currently viewing: leaderboard");

    expect(response).toMatchObject({
      answer: "**Terminal-Bench** leads the digest on solution rate (0.42 over 120 tasks).",
      chart: { type: "bar", dimension: "harness", metric: "solution_rate", title: "Solution rate by harness" },
      rowsUsed: ["terminal-bench/gpt-x"],
      modelSlug: "openai/gpt-5.6-luna-pro",
    });
    expect(typeof response.ranAt).toBe("string");
    const tokenUsage = tokenUsageOf(response);
    expect(tokenUsage.inputTokens).toBe(100);
    expect(tokenUsage.outputTokens).toBe(50);
    // 100 input @ $0.10/M + 50 output @ $0.60/M = $0.00004.
    expect(tokenUsage.estimatedCostUSD).toBeCloseTo(0.00004, 10);
  });

  it("public benchmark assistant answers only from the supplied digest and exposes no tenant objects", async () => {
    mocks.fetch.mockResolvedValue(openRouterCompletion(VALID_MODEL_OUTPUT));

    await run(benchRequest(validPayload(), TEST_IP));

    const body = requestBody<{ messages: Array<{ content: string }> }>(recordedFetch().init);
    expect(body.messages[1]?.content).toContain('"solution_rate":0.42');

    // The only Firestore writes a public call may produce are the IP-keyed
    // public_rate_limits counters — never a users/ tenant path.
    expect([...mocks.store.keys()].every((key) => key.startsWith("public_rate_limits/"))).toBe(true);
  });
});
