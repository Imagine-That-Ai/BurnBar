import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createHash } from "node:crypto";

const { store, dbMock, FieldValueMock, FakeTimestamp } = vi.hoisted(() => {
  const store = new Map<string, Record<string, unknown>>();

  class FakeTimestamp {
    constructor(public readonly ms: number) {}
    static now(): FakeTimestamp {
      return new FakeTimestamp(Date.now());
    }
    static fromMillis(ms: number): FakeTimestamp {
      return new FakeTimestamp(ms);
    }
    toMillis(): number {
      return this.ms;
    }
  }

  const FieldValueMock = {
    increment: (n: number) => ({ __increment: n }),
  };

  const applyPatch = (path: string, data: Record<string, unknown>, merge: boolean) => {
    const existing = merge ? (store.get(path) ?? {}) : {};
    const next: Record<string, unknown> = { ...existing };
    for (const [key, value] of Object.entries(data)) {
      if (
        value &&
        typeof value === "object" &&
        !Array.isArray(value) &&
        Object.prototype.hasOwnProperty.call(value, "__increment")
      ) {
        const increment = Reflect.get(value, "__increment");
        const previous = next[key];
        next[key] = (typeof previous === "number" ? previous : 0) + (typeof increment === "number" ? increment : 0);
      } else {
        next[key] = value;
      }
    }
    store.set(path, next);
  };

  const snapshotFor = (path: string) => {
    const data = store.get(path);
    return {
      exists: data !== undefined,
      id: path.split("/").pop() ?? "",
      data: () => data,
      get: (field: string) => data?.[field],
      ref: makeDocRef(path),
    };
  };

  function makeCollectionRef(path: string) {
    return {
      path,
      doc(id: string) {
        return makeDocRef(`${path}/${id}`);
      },
    };
  }

  function makeDocRef(path: string) {
    return {
      path,
      collection(collectionId: string) {
        return makeCollectionRef(`${path}/${collectionId}`);
      },
      async get() {
        return snapshotFor(path);
      },
      async set(data: Record<string, unknown>, opts?: { merge?: boolean }) {
        applyPatch(path, data, opts?.merge === true);
      },
    };
  }

  const dbMock = {
    doc: (path: string) => makeDocRef(path),
    collection: (path: string) => makeCollectionRef(path),
    async runTransaction<T>(fn: (tx: unknown) => Promise<T>): Promise<T> {
      const tx = {
        async get(ref: { path: string }) {
          return snapshotFor(ref.path);
        },
        set(ref: { path: string }, data: Record<string, unknown>, opts?: { merge?: boolean }) {
          applyPatch(ref.path, data, opts?.merge === true);
        },
      };
      return fn(tx);
    },
  };

  return { store, dbMock, FieldValueMock, FakeTimestamp };
});

const { performProviderSearchMock, logWarnMock } = vi.hoisted(() => ({
  performProviderSearchMock: vi.fn(),
  logWarnMock: vi.fn(),
}));

vi.mock("../adminRuntime.js", () => ({ db: dbMock }));
vi.mock("firebase-admin/firestore", () => ({
  FieldValue: FieldValueMock,
  Timestamp: FakeTimestamp,
}));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));
vi.mock("../cloudFeatureSuspensions.js", () => ({ assertCloudFeatureNotSuspended: vi.fn() }));
vi.mock("../cloudProAllowanceRemoteConfig.js", () => ({
  loadCloudProAllowanceConfig: vi.fn(async () => ({
    includedHostedActionsMonthly: 10,
    includedRelayGBMonthly: 10,
    includedFusionSearchesMonthly: 2,
    includedUltraFusionSearchesMonthly: 4,
    actionTopUpUnit: 10,
    relayTopUpUnitGB: 10,
    fusionSearchTopUpUnit: 10,
    fusionSearchLargeTopUpUnit: 50,
    monthlyHostedActionCap: 100,
    monthlyRelayGBCap: 100,
    monthlyFusionSearchCap: 5,
    monthlyUltraFusionSearchCap: 10,
  })),
}));
vi.mock("../config.js", () => ({ getConfig: () => ({ enforceAppCheck: false }) }));
vi.mock("../runtimeOptions.js", () => ({ FUNCTIONS_REGION: "us-central1" }));
vi.mock("../logging.js", () => ({
  logWarn: logWarnMock,
  onCallProduction: (_name: string, _options: unknown, handler: (request: unknown) => Promise<unknown>) => ({
    run: handler,
  }),
}));
vi.mock("../callables/shared.js", () => ({
  BURNBAR_PRO_MAX_ENTITLEMENT_ID: "burnbar_pro_max",
  BURNBAR_ULTRA_ENTITLEMENT_ID: "burnbar_ultra",
  boundedTrimmedString: (raw: unknown, _field: string, max: number, required: boolean) => {
    if (typeof raw !== "string") {
      if (required) throw new Error("required string");
      return undefined;
    }
    const trimmed = raw.trim();
    if (!trimmed) {
      if (required) throw new Error("required string");
      return undefined;
    }
    return trimmed.slice(0, max);
  },
  requiredIdentifier: (raw: unknown, field: string) => {
    if (typeof raw !== "string" || raw.trim().length === 0) throw new Error(`${field} is required`);
    return raw.trim();
  },
}));
vi.mock("../elderWandHostedSearchProviders.js", () => ({
  HOSTED_SEARCH_SECRETS: [],
  normalizeProviderResults: (raw: unknown[]) =>
    raw.flatMap((item) => {
      if (!item || typeof item !== "object" || Array.isArray(item)) return [];
      const title = Reflect.get(item, "title");
      const url = Reflect.get(item, "url");
      const snippet = Reflect.get(item, "snippet");
      if (typeof title !== "string" || typeof url !== "string") return [];
      return [
        {
          title,
          url,
          ...(typeof snippet === "string" ? { snippet } : {}),
        },
      ];
    }),
  performProviderSearch: performProviderSearchMock,
}));

import { performElderWandHostedSearch } from "../elderWandHostedSearch.js";

const UID = "quotaUser";
const MONTH_KEY = "2026-06";
const ALLOWANCE_PATH = `users/${UID}/billing/allowances/months/${MONTH_KEY}`;
const QUOTA_SNAPSHOT_PATH = `users/${UID}/quota_snapshots/openburnbar_elder_wand_fusion`;

function seedCloudProEntitlement() {
  store.set(`users/${UID}/entitlements/burnbar_pro_max`, {
    active: true,
    expireAt: FakeTimestamp.fromMillis(Date.now() + 60_000),
  });
}

function callHostedSearch(runId: string, query = "latest burnbar quota hardening") {
  return performElderWandHostedSearch.run({
    auth: { uid: UID, token: Object.create(null), rawToken: "test-token" },
    app: { appId: "1:123:web:test", token: Object.create(null) },
    data: {
      query,
      sessionId: "session-1",
      runId,
      maxResults: 2,
      runSearchCap: 12,
    },
    rawRequest: Object.assign(Object.create(null), { headers: {} }),
    acceptsStreaming: false,
  });
}

function cachePathFor(runId: string, query: string) {
  const hash = createHash("sha256").update(query.toLowerCase()).digest("hex");
  return `${ALLOWANCE_PATH}/fusion_search_cache/${runId}_${hash.slice(0, 32)}`;
}

describe("performElderWandHostedSearch quota reservation", () => {
  beforeEach(() => {
    vi.useFakeTimers({ now: new Date("2026-06-22T14:00:00Z") });
    store.clear();
    performProviderSearchMock.mockReset();
    logWarnMock.mockReset();
    seedCloudProEntitlement();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("reserves hosted-search quota before provider work and does not double-debit on commit", async () => {
    let providerObservedUsed: unknown;
    performProviderSearchMock.mockImplementation(async () => {
      providerObservedUsed = store.get(ALLOWANCE_PATH)?.fusionSearchesUsed;
      return {
        provider: "perplexity",
        results: [{ title: "Result", url: "https://example.com/result", snippet: "ok" }],
        costUSD: 0.005,
      };
    });

    const response = await callHostedSearch("run-reserve-first");

    expect(providerObservedUsed).toBe(1);
    expect(store.get(ALLOWANCE_PATH)?.fusionSearchesUsed).toBe(1);
    expect(response.quota).toMatchObject({ used: 1, remaining: 1, included: 2, monthlyCap: 5 });
    expect(response.cached).toBe(false);
    const cacheDoc = [...store.values()].find((doc) => doc.status === "ready" && doc.runId === "run-reserve-first");
    expect(cacheDoc).toMatchObject({ reservationStatus: "consumed", reservedUnits: 1 });
  });

  it("keeps the reserved unit consumed when provider work fails", async () => {
    performProviderSearchMock.mockRejectedValue(new Error("provider failed after claim"));

    await expect(callHostedSearch("run-provider-fails")).rejects.toThrow(/provider failed/);

    expect(store.get(ALLOWANCE_PATH)?.fusionSearchesUsed).toBe(1);
    expect(store.get(QUOTA_SNAPSHOT_PATH)).toMatchObject({
      statusMessage: "1 hosted Fusion searches remaining this month.",
      buckets: [expect.objectContaining({ used: 1, remaining: 1 })],
    });
    const cacheDoc = [...store.values()].find((doc) => doc.status === "failed" && doc.runId === "run-provider-fails");
    expect(cacheDoc).toMatchObject({
      reservationStatus: "consumed_failed",
      reservedUnits: 1,
      error: "provider failed after claim",
    });
    expect(logWarnMock).toHaveBeenCalledWith(expect.objectContaining({ event: "elder_wand_hosted_search.failed" }));
  });

  it("reuses an expired pending reservation instead of debiting the same cached search twice", async () => {
    const query = "same deduped hosted search";
    const runId = "run-expired-pending";
    store.set(ALLOWANCE_PATH, {
      includedFusionSearches: 2,
      fusionSearchesUsed: 1,
      topupFusionSearchesPurchased: 0,
      monthlyFusionSearchCap: 5,
    });
    store.set(`${ALLOWANCE_PATH}/fusion_search_runs/${runId}`, {
      attemptedSearches: 1,
    });
    store.set(cachePathFor(runId, query), {
      uid: UID,
      monthKey: MONTH_KEY,
      sessionId: "session-1",
      runId,
      queryHash: "already-reserved",
      status: "pending",
      reservationStatus: "reserved",
      reservedUnits: 1,
      reservedAt: FakeTimestamp.fromMillis(Date.now() - 60_000),
      quota: {
        meter: "fusion_searches",
        included: 2,
        purchased: 0,
        used: 1,
        remaining: 1,
        monthlyCap: 5,
        resetAt: "2026-07-01T00:00:00.000Z",
      },
      lockId: "old-lock",
      lockExpiresAt: FakeTimestamp.fromMillis(Date.now() - 1),
      createdAt: FakeTimestamp.fromMillis(Date.now() - 60_000),
      updatedAt: FakeTimestamp.fromMillis(Date.now() - 60_000),
    });
    let providerObservedUsed: unknown;
    performProviderSearchMock.mockImplementation(async () => {
      providerObservedUsed = store.get(ALLOWANCE_PATH)?.fusionSearchesUsed;
      return {
        provider: "perplexity",
        results: [{ title: "Taken over", url: "https://example.com/taken-over" }],
        costUSD: 0.005,
      };
    });

    const response = await callHostedSearch(runId, query);

    expect(providerObservedUsed).toBe(1);
    expect(store.get(ALLOWANCE_PATH)?.fusionSearchesUsed).toBe(1);
    expect(store.get(`${ALLOWANCE_PATH}/fusion_search_runs/${runId}`)?.attemptedSearches).toBe(2);
    expect(response.quota).toMatchObject({ used: 1, remaining: 1 });
  });

  it("serves successful duplicate searches from cache without another provider call or debit", async () => {
    performProviderSearchMock.mockResolvedValue({
      provider: "perplexity",
      results: [{ title: "Cached", url: "https://example.com/cached" }],
      costUSD: 0.005,
    });

    const first = await callHostedSearch("run-cached");
    const second = await callHostedSearch("run-cached");

    expect(first.cached).toBe(false);
    expect(second.cached).toBe(true);
    expect(performProviderSearchMock).toHaveBeenCalledTimes(1);
    expect(store.get(ALLOWANCE_PATH)?.fusionSearchesUsed).toBe(1);
  });
});
