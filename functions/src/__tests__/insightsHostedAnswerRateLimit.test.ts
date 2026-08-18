import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";

import { ALICE_UID, callableRequest, callableRunner, pathKeyedFirestore, seedDoc } from "./bola/callableBolaHarness.js";

const PROMPT_CAP_ENV = "INSIGHTS_HOSTED_FALLBACK_MAX_PROMPT_CHARS";
const USER_PROMPT_CAP_ENV = "INSIGHTS_HOSTED_FALLBACK_MAX_USER_PROMPT_CHARS";
const NOW = "2026-06-25T09:30:00.000Z";

const mocks = vi.hoisted(() => ({
  config: {
    enforceAppCheck: true,
    burnBarProProductID: "burnbar_pro",
    hostedQuotaProductID: "hosted_quota_sync",
    googlePlaySubscriptionProductID: "google_play_subscription",
  },
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
vi.mock("../auth.js", () => ({
  assertAppCheck: vi.fn(),
  assertAuth: vi.fn(),
}));
vi.mock("../cloudFeatureSuspensions.js", () => ({
  assertCloudFeatureNotSuspended: vi.fn(async () => undefined),
}));
vi.mock("../config.js", () => ({
  getConfig: () => mocks.config,
}));
vi.mock("../resilienceHelpers.js", () => ({
  resilientFetch: mocks.fetch,
}));

import { insightsHostedAnswer } from "../insightsHostedAnswer.js";
import { checkHostedInsightsAnswerRateLimit, isPublicRateLimitExceeded } from "../callables/publicRateLimit.js";

function seedActiveEntitlement(uid: string): void {
  seedDoc(mocks.store, `users/${uid}/entitlements/burnbar_pro`, {
    active: true,
    productID: mocks.config.burnBarProProductID,
    expiresAt: "2099-01-01T00:00:00.000Z",
    schemaVersion: 1,
    createdAt: NOW,
    updatedAt: NOW,
  });
}

describe("checkHostedInsightsAnswerRateLimit", () => {
  beforeEach(() => {
    mocks.store.clear();
  });

  it("allows a short burst and rejects the 11th request for a uid", async () => {
    for (let i = 0; i < 10; i += 1) {
      await expect(checkHostedInsightsAnswerRateLimit(ALICE_UID)).resolves.toBeUndefined();
    }

    try {
      await checkHostedInsightsAnswerRateLimit(ALICE_UID);
      expect.fail("expected hosted insights rate limit to reject");
    } catch (error) {
      expect(isPublicRateLimitExceeded(error)).toBe(true);
      expect(error).toMatchObject({ code: "resource-exhausted" });
    }
  });
});

describe("insightsHostedAnswer prompt cap", () => {
  beforeEach(() => {
    mocks.store.clear();
    mocks.fetch.mockReset();
    mocks.fetch.mockImplementation(async () => {
      throw new Error("unexpected OpenRouter fetch");
    });
    mocks.secretValues.clear();
    mocks.secretValues.set("OPENROUTER_API_KEY", "test-openrouter-key");
    seedActiveEntitlement(ALICE_UID);
    process.env[PROMPT_CAP_ENV] = "5";
  });

  afterEach(() => {
    delete process.env[PROMPT_CAP_ENV];
    delete process.env[USER_PROMPT_CAP_ENV];
  });

  it("rejects oversized prompts before it reaches OpenRouter", async () => {
    const run = callableRunner(insightsHostedAnswer);
    const prompt = "123456";

    await expect(
      run(
        callableRequest(ALICE_UID, {
          instruction: "answerFollowUp",
          request: { prompt },
        }),
      ),
    ).rejects.toMatchObject({
      code: "invalid-argument",
      message: expect.stringContaining("max 5 characters, got 6"),
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("does not consume hosted-answer quota when OpenRouter is unconfigured", async () => {
    mocks.secretValues.delete("OPENROUTER_API_KEY");
    process.env[PROMPT_CAP_ENV] = "100";
    const run = callableRunner(insightsHostedAnswer);

    await expect(
      run(
        callableRequest(ALICE_UID, {
          instruction: "answerFollowUp",
          request: { prompt: "Can you summarize this?" },
        }),
      ),
    ).rejects.toMatchObject({
      code: "failed-precondition",
      message: expect.stringContaining("OPENROUTER_API_KEY"),
    });

    expect([...mocks.store.keys()].filter((key) => key.startsWith("public_rate_limits/"))).toEqual([]);
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("rejects oversized digest payloads before it reaches OpenRouter or consumes quota", async () => {
    process.env[PROMPT_CAP_ENV] = "1000";
    process.env[USER_PROMPT_CAP_ENV] = "700";
    const run = callableRunner(insightsHostedAnswer);

    await expect(
      run(
        callableRequest(ALICE_UID, {
          instruction: "answerFollowUp",
          request: {
            prompt: "Summarize this.",
            context: {
              digest: {
                totals: { inflated: "x".repeat(2000) },
              },
            },
          },
        }),
      ),
    ).rejects.toMatchObject({
      code: "invalid-argument",
      message: expect.stringContaining("Hosted fallback payload is too long"),
    });

    expect([...mocks.store.keys()].filter((key) => key.startsWith("public_rate_limits/"))).toEqual([]);
    expect(mocks.fetch).not.toHaveBeenCalled();
  });
});

describe("insightsHostedAnswer monthly dollar cap", () => {
  beforeEach(() => {
    mocks.store.clear();
    mocks.fetch.mockReset();
    mocks.secretValues.clear();
    mocks.secretValues.set("OPENROUTER_API_KEY", "test-openrouter-key");
    seedActiveEntitlement(ALICE_UID);
  });

  afterEach(() => {
    delete process.env.INSIGHTS_HOSTED_MONTHLY_USD_CAP;
  });

  it("refuses once the uid's month has consumed the owner-funded budget", async () => {
    // The ledger is keyed by the CURRENT month (the callable stamps isoNow()),
    // so seed the cap as already burned for whatever month "now" is.
    const monthKey = new Date().toISOString().slice(0, 7);
    seedDoc(mocks.store, `users/${ALICE_UID}/billing/hosted_insights/months/${monthKey}`, {
      monthKey,
      spentUSD: 2.5,
      answerCount: 900,
    });
    const run = callableRunner(insightsHostedAnswer);

    await expect(
      run(
        callableRequest(ALICE_UID, {
          instruction: "answerFollowUp",
          request: { prompt: "Summarize this." },
        }),
      ),
    ).rejects.toMatchObject({
      code: "resource-exhausted",
      message: expect.stringContaining("resets at the start of next month"),
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("records spend, count, and tokens in the monthly ledger after an answer", async () => {
    mocks.fetch.mockImplementation(async () => ({
      ok: true,
      status: 200,
      text: async () =>
        JSON.stringify({
          choices: [{ message: { content: JSON.stringify({ executiveSummary: "All quiet today." }) } }],
          usage: { prompt_tokens: 1000, completion_tokens: 500 },
        }),
    }));
    const run = callableRunner(insightsHostedAnswer);

    const result = await run(
      callableRequest(ALICE_UID, {
        instruction: "answerFollowUp",
        request: { prompt: "Summarize this." },
      }),
    );
    expect(result).toMatchObject({ providerKey: "burnbar-hosted" });

    const monthKey = new Date().toISOString().slice(0, 7);
    const ledger = mocks.store.get(`users/${ALICE_UID}/billing/hosted_insights/months/${monthKey}`);
    expect(ledger).toBeDefined();
    expect(ledger).toMatchObject({
      monthKey,
      answerCount: 1,
      inputTokens: 1000,
      outputTokens: 500,
    });
    expect(Number(ledger?.spentUSD)).toBeGreaterThan(0);

    // And the ops per-day rollup the margin dashboard reads.
    const dayKey = new Date().toISOString().slice(0, 10);
    const rollup = mocks.store.get(`ops/hosted_insights_daily_rollups/days/${dayKey}`);
    expect(rollup).toMatchObject({ dayKey, answerCount: 1 });
    expect(Number(rollup?.spendUSD)).toBeCloseTo(Number(ledger?.spentUSD), 10);
  });
});
