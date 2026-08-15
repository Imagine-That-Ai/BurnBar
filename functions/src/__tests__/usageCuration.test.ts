/**
 * curateUsageMemoryBatch — callable-level coverage: kill flag, lane-scoped
 * entitlement gates, input validation, the CoreWeave-pinned OpenRouter call,
 * reserve/settle metering, and replay refusal. Pure limits/allowance coverage
 * lives in usageCurationAllowance.test.ts.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

import { ALICE_UID, callableRequest, callableRunner, pathKeyedFirestore, seedDoc } from "./bola/callableBolaHarness.js";

const FAR_FUTURE = "2099-01-01T00:00:00.000Z";

const mocks = vi.hoisted(() => ({
  config: {
    enforceAppCheck: true,
    hostedQuotaProductID: "com.openburnbar.hostedQuotaSync.cloud.monthly",
    burnBarProProductID: "com.openburnbar.pro.monthly",
    burnBarProAnnualProductID: "com.openburnbar.pro.annual",
    burnBarProMaxProductID: "com.openburnbar.proMax.v2.monthly",
    burnBarProMaxAnnualProductID: "com.openburnbar.proMax.annual",
    burnBarUltraProductID: "com.openburnbar.ultra.monthly",
    burnBarUltraAnnualProductID: "com.openburnbar.ultra.annual.v2",
    googlePlaySubscriptionProductID: "com.openburnbar.pro.monthly",
    googlePlayCloudMonthlyProductID: "com.openburnbar.pro.monthly",
    googlePlayCloudAnnualProductID: "com.openburnbar.pro.annual",
    googlePlayCloudProMonthlyProductID: "com.openburnbar.promax.v2.monthly",
    googlePlayCloudProAnnualProductID: "com.openburnbar.promax.annual",
    googlePlayUltraMonthlyProductID: "com.openburnbar.ultra.monthly",
    googlePlayUltraAnnualProductID: "com.openburnbar.ultra.annual",
  },
  fetch: vi.fn(),
  rcParameters: {} as Record<string, { defaultValue?: { value?: string } }>,
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

vi.mock("firebase-admin/remote-config", () => ({
  getRemoteConfig: () => ({
    getTemplate: async () => ({ parameters: mocks.rcParameters }),
  }),
}));

vi.mock("../adminRuntime.js", () => ({ db: pathKeyedFirestore(mocks.store) }));
vi.mock("../auth.js", () => ({
  assertAppCheck: vi.fn(),
  assertAuth: vi.fn(),
  enforceAuthAndAppCheck: vi.fn(),
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

import { monthKeyForDate } from "../cloudProAllowanceCore.js";
import { usageCurationAllowanceDocPath, usageCurationReservationDocPath } from "../usageCuration/allowance.js";
import { dayKeyForDate, nextMonthlyResetISO } from "../usageCuration/limits.js";
import { USAGE_CURATION_MULTIMODAL_MODEL, USAGE_CURATION_TEXT_MODEL } from "../usageCuration/openrouterClient.js";
import {
  USAGE_CURATION_FENCE_BEGIN,
  USAGE_CURATION_PROMPT_PREFIX,
  USAGE_CURATION_PROMPT_VERSION,
} from "../usageCuration/prompt.js";
import { curateUsageMemoryBatch, __testing__ } from "../callables/usageCuration.js";

function seedEntitlement(uid: string, docId: string, productID: string): void {
  seedDoc(mocks.store, `users/${uid}/entitlements/${docId}`, {
    active: true,
    productID,
    expiresAt: FAR_FUTURE,
  });
}

function seedProUser(uid: string = ALICE_UID): void {
  seedEntitlement(uid, "burnbar_pro", mocks.config.burnBarProProductID);
}

function seedProMaxUser(uid: string = ALICE_UID): void {
  seedProUser(uid);
  seedEntitlement(uid, "burnbar_pro_max", mocks.config.burnBarProMaxProductID);
}

function seedUltraUser(uid: string = ALICE_UID): void {
  seedProMaxUser(uid);
  seedEntitlement(uid, "burnbar_ultra", mocks.config.burnBarUltraProductID);
}

function openRouterResponse(overrides: Record<string, unknown> = {}): {
  ok: boolean;
  status: number;
  text: () => Promise<string>;
} {
  const payload = {
    id: "gen-1",
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content: JSON.stringify({
            memories: [
              {
                text: "Alberto prefers drafts over automerge.",
                kind: "preference",
                confidence: 0.9,
                keywords: ["draft", "merge"],
                tags: ["workflow"],
                context: "Stated while reviewing PR flow.",
                candidateId: "c1",
              },
            ],
          }),
        },
        finish_reason: "stop",
      },
    ],
    usage: { prompt_tokens: 800, completion_tokens: 100 },
    ...overrides,
  };
  return { ok: true, status: 200, text: async () => JSON.stringify(payload) };
}

function lastFetchBody(): Record<string, unknown> {
  const call = mocks.fetch.mock.calls.at(-1);
  expect(call).toBeTruthy();
  return JSON.parse((call![2] as { body: string }).body) as Record<string, unknown>;
}

beforeEach(() => {
  mocks.store.clear();
  mocks.rcParameters = {};
  mocks.fetch.mockReset();
  mocks.fetch.mockImplementation(async () => {
    throw new Error("unexpected OpenRouter fetch");
  });
  mocks.secretValues.clear();
  mocks.secretValues.set("OPENROUTER_API_KEY", "test-openrouter-key");
});

describe("curateUsageMemoryBatch helpers", () => {
  it("estimates tokens as chars/4 + flat image cost + the 512-token output budget", () => {
    expect(__testing__.MAX_OUTPUT_TOKENS).toBe(512);
    expect(__testing__.estimateTokens(400, 0)).toBe(100 + 512);
    expect(__testing__.estimateTokens(401, 2)).toBe(101 + 2 * __testing__.IMAGE_TOKEN_ESTIMATE + 512);
  });

  it("sanitizes model memories: drops unknown candidateIds and clamps confidence", () => {
    const memories = __testing__.sanitizeCuratedMemories(
      JSON.stringify({
        memories: [
          { text: "keep me", kind: "fact", confidence: 7, keywords: ["k"], tags: [], context: "c", candidateId: "c1" },
          { text: "orphan", kind: "fact", confidence: 0.5, keywords: [], tags: [], context: "", candidateId: "ghost" },
          { text: "", kind: "fact", confidence: 0.5, keywords: [], tags: [], context: "", candidateId: "c1" },
        ],
      }),
      new Set(["c1"]),
    );
    expect(memories).toHaveLength(1);
    expect(memories[0]).toMatchObject({ text: "keep me", confidence: 1, candidateId: "c1" });
  });
});

describe("curateUsageMemoryBatch", () => {
  const run = () => callableRunner(curateUsageMemoryBatch);
  const textBatch = (overrides: Record<string, unknown> = {}) => ({
    lane: "text",
    candidates: [{ id: "c1", sourceKind: "page", text: "Alberto said drafts only, he merges himself." }],
    ...overrides,
  });

  it("throws failed-precondition when the usage_curation_enabled kill flag is off", async () => {
    mocks.rcParameters = { usage_curation_enabled: { defaultValue: { value: "false" } } };
    await expect(run()(callableRequest(ALICE_UID, textBatch()))).rejects.toMatchObject({
      code: "failed-precondition",
      message: expect.stringContaining("disabled"),
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("denies the text lane without any active Pro entitlement", async () => {
    await expect(run()(callableRequest(ALICE_UID, textBatch()))).rejects.toMatchObject({
      code: "permission-denied",
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("denies the multimodal lane for a plain Pro subscriber", async () => {
    seedProUser();
    await expect(
      run()(
        callableRequest(ALICE_UID, {
          lane: "multimodal",
          candidates: [{ id: "c1", sourceKind: "page", text: "look at this" }],
        }),
      ),
    ).rejects.toMatchObject({ code: "permission-denied" });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("rejects batches with more than 25 candidates", async () => {
    seedProUser();
    const candidates = Array.from({ length: 26 }, (_, i) => ({ id: `c${i}`, sourceKind: "page", text: "x" }));
    await expect(run()(callableRequest(ALICE_UID, textBatch({ candidates })))).rejects.toMatchObject({
      code: "invalid-argument",
      message: expect.stringContaining("25"),
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("rejects a candidate whose text exceeds 4 KiB", async () => {
    seedProUser();
    const candidates = [{ id: "c1", sourceKind: "page", text: "x".repeat(4 * 1024 + 1) }];
    await expect(run()(callableRequest(ALICE_UID, textBatch({ candidates })))).rejects.toMatchObject({
      code: "invalid-argument",
      message: expect.stringContaining("4096-byte"),
    });
  });

  it("rejects imageRefs on the text lane", async () => {
    seedProUser();
    const candidates = [{ id: "c1", sourceKind: "page", text: "x", imageRefs: ["data:image/png;base64,AAAA"] }];
    await expect(run()(callableRequest(ALICE_UID, textBatch({ candidates })))).rejects.toMatchObject({
      code: "invalid-argument",
      message: expect.stringContaining("multimodal"),
    });
  });

  it("rejects more than 4 images per batch", async () => {
    seedProMaxUser();
    const candidates = [
      {
        id: "c1",
        sourceKind: "page",
        text: "x",
        imageRefs: Array.from({ length: 5 }, () => "data:image/png;base64,AAAA"),
      },
    ];
    await expect(run()(callableRequest(ALICE_UID, { lane: "multimodal", candidates }))).rejects.toMatchObject({
      code: "invalid-argument",
      message: expect.stringContaining("at most 4 images"),
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("curates a text batch end to end with the CoreWeave privacy pin", async () => {
    seedProUser();
    mocks.fetch.mockResolvedValueOnce(openRouterResponse());

    const response = (await run()(callableRequest(ALICE_UID, textBatch({ requestId: "req-1" })))) as Record<
      string,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      any
    >;

    expect(mocks.fetch).toHaveBeenCalledTimes(1);
    const [label, url, init] = mocks.fetch.mock.calls[0] as [string, string, { headers: Record<string, string> }];
    expect(label).toBe("usage_curation.openrouter.chat");
    expect(url).toBe("https://openrouter.ai/api/v1/chat/completions");
    expect(init.headers.Authorization).toBe("Bearer test-openrouter-key");

    const body = lastFetchBody();
    expect(body.model).toBe(USAGE_CURATION_TEXT_MODEL);
    // Privacy invariant: CoreWeave pinned, no fallbacks, no data collection, ZDR.
    expect(body.provider).toEqual({
      order: ["CoreWeave"],
      allow_fallbacks: false,
      data_collection: "deny",
      zdr: true,
    });
    const messages = body.messages as Array<{ role: string; content: string }>;
    expect(messages[0]).toEqual({ role: "system", content: USAGE_CURATION_PROMPT_PREFIX });
    expect(messages[1].content).toContain(USAGE_CURATION_FENCE_BEGIN);

    expect(response.results).toEqual([
      {
        text: "Alberto prefers drafts over automerge.",
        kind: "preference",
        confidence: 0.9,
        keywords: ["draft", "merge"],
        tags: ["workflow"],
        context: "Stated while reviewing PR flow.",
        candidateId: "c1",
      },
    ]);
    expect(response.promptVersion).toBe(USAGE_CURATION_PROMPT_VERSION);
    expect(response.usage).toEqual({ promptTokens: 800, outputTokens: 100, cachedTokens: 0, lane: "text" });
    expect(response.allowance.textRemainingMonth).toBe(1_000_000 - 900);
    expect(response.allowance.multimodalRemainingMonth).toBe(0);
    expect(response.allowance.resetsAt).toBe(nextMonthlyResetISO(new Date()));

    // The ledger settled to ACTUAL usage (900), not the estimate.
    const monthKey = monthKeyForDate(new Date());
    const allowanceDoc = mocks.store.get(usageCurationAllowanceDocPath(ALICE_UID, monthKey));
    expect(allowanceDoc?.textTokensUsed).toBe(900);
    expect(allowanceDoc?.textTokensUsedToday).toBe(900);
    const reservationDoc = mocks.store.get(usageCurationReservationDocPath(ALICE_UID, monthKey, "curate_text_req-1"));
    expect(reservationDoc).toMatchObject({ status: "settled", settledTokens: 900, lane: "text" });
  });

  it("routes the multimodal lane to minimax with OpenAI-format image parts", async () => {
    seedProMaxUser();
    mocks.fetch.mockResolvedValueOnce(openRouterResponse());

    const response = (await run()(
      callableRequest(ALICE_UID, {
        lane: "multimodal",
        candidates: [{ id: "c1", sourceKind: "screenshot", text: "chart", imageRefs: ["data:image/png;base64,AAAA"] }],
      }),
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    )) as Record<string, any>;

    const body = lastFetchBody();
    expect(body.model).toBe(USAGE_CURATION_MULTIMODAL_MODEL);
    expect(body.provider).toMatchObject({ order: ["CoreWeave"], allow_fallbacks: false });
    const messages = body.messages as Array<{ role: string; content: unknown }>;
    const parts = messages[1].content as Array<Record<string, unknown>>;
    expect(parts[0]).toMatchObject({ type: "text" });
    expect(parts[1]).toEqual({ type: "image_url", image_url: { url: "data:image/png;base64,AAAA" } });
    expect(response.usage.lane).toBe("multimodal");
    expect(response.allowance.multimodalRemainingMonth).toBe(2_000_000 - 900);
  });

  it("gives ultra members the multiplied allowance headroom", async () => {
    seedUltraUser();
    mocks.fetch.mockResolvedValueOnce(openRouterResponse());
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const response = (await run()(callableRequest(ALICE_UID, textBatch()))) as Record<string, any>;
    expect(response.allowance.textRemainingMonth).toBe(50_000_000 - 900);
    expect(response.allowance.multimodalRemainingMonth).toBe(20_000_000);
  });

  it("refuses to re-run a requestId whose reservation already settled", async () => {
    seedProUser();
    mocks.fetch.mockResolvedValue(openRouterResponse());
    await run()(callableRequest(ALICE_UID, textBatch({ requestId: "req-replay" })));
    await expect(run()(callableRequest(ALICE_UID, textBatch({ requestId: "req-replay" })))).rejects.toMatchObject({
      code: "already-exists",
      message: expect.stringContaining("already completed"),
    });
    // Exactly ONE metered cloud call for one reservation.
    expect(mocks.fetch).toHaveBeenCalledTimes(1);
    const monthKey = monthKeyForDate(new Date());
    expect(mocks.store.get(usageCurationAllowanceDocPath(ALICE_UID, monthKey))?.textTokensUsed).toBe(900);
  });

  it("blocks the call before OpenRouter when the monthly allowance is exhausted", async () => {
    seedProUser();
    const monthKey = monthKeyForDate(new Date());
    seedDoc(mocks.store, usageCurationAllowanceDocPath(ALICE_UID, monthKey), {
      schemaVersion: 1,
      textTokensUsed: 1_000_000,
      textTokensUsedToday: 0,
      dayKey: dayKeyForDate(new Date()),
    });
    await expect(run()(callableRequest(ALICE_UID, textBatch()))).rejects.toMatchObject({
      code: "resource-exhausted",
      details: expect.objectContaining({ lane: "text", resetsAt: expect.stringMatching(/T00:00:00\.000Z$/) }),
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("releases the reserved estimate when the OpenRouter call fails", async () => {
    seedProUser();
    mocks.fetch.mockResolvedValueOnce({
      ok: false,
      status: 500,
      text: async () => JSON.stringify({ error: { message: "upstream exploded" } }),
    });
    await expect(run()(callableRequest(ALICE_UID, textBatch({ requestId: "req-fail" })))).rejects.toMatchObject({
      code: "unavailable",
    });
    const monthKey = monthKeyForDate(new Date());
    const allowanceDoc = mocks.store.get(usageCurationAllowanceDocPath(ALICE_UID, monthKey));
    expect(allowanceDoc?.textTokensUsed).toBe(0);
    expect(allowanceDoc?.textTokensUsedToday).toBe(0);
  });

  it("fails preconditions without burning allowance when the API key secret is empty", async () => {
    seedProUser();
    mocks.secretValues.delete("OPENROUTER_API_KEY");
    await expect(run()(callableRequest(ALICE_UID, textBatch()))).rejects.toMatchObject({
      code: "failed-precondition",
      message: expect.stringContaining("OPENROUTER_API_KEY"),
    });
    const monthKey = monthKeyForDate(new Date());
    expect(mocks.store.get(usageCurationAllowanceDocPath(ALICE_UID, monthKey))).toBeUndefined();
    expect(mocks.fetch).not.toHaveBeenCalled();
  });
});
