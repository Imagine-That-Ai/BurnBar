/**
 * @fileoverview Paid hosted web_search for Elder Wand Fusion.
 *
 * Provider keys stay server-side. Perplexity Search API is primary; Tavily is
 * the fallback. The allowance debit happens only after a successful provider
 * response, with per-run dedupe and caps to control Fusion fan-out.
 */

import { createHash, randomBytes } from "node:crypto";

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";

import { db } from "./adminRuntime.js";
import { getConfig } from "./config.js";
import { enforceAuthAndAppCheck } from "./auth.js";
import { assertCloudFeatureNotSuspended } from "./cloudFeatureSuspensions.js";
import {
  allowanceDocPath,
  CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
  evaluateCloudProAllowanceReservation,
  monthKeyForDate,
} from "./cloudProAllowanceCore.js";
import { loadCloudProAllowanceConfig } from "./cloudProAllowanceRemoteConfig.js";
import { errorMessage, isRecord, isTimestampWithToMillis, stripUndefinedObject } from "./guards.js";
import { logWarn, onCallProduction } from "./logging.js";
import { providerFetch } from "./providers/httpClient.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";
import {
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  BURNBAR_ULTRA_ENTITLEMENT_ID,
  boundedTrimmedString,
  requiredIdentifier,
} from "./callables/shared.js";

const PERPLEXITY_API_KEY = defineSecret("PERPLEXITY_API_KEY");
const TAVILY_API_KEY = defineSecret("TAVILY_API_KEY");
const HOSTED_SEARCH_SECRETS = [PERPLEXITY_API_KEY, TAVILY_API_KEY];

const MAX_QUERY_CHARS = 512;
const MAX_RESULTS = 5;
const DEFAULT_RUN_SEARCH_CAP = 12;
const ABSOLUTE_RUN_SEARCH_CAP = 24;
const PENDING_LOCK_TTL_MS = 30_000;
const PENDING_POLL_MS = 250;
const PENDING_WAIT_MS = 3_000;
const PERPLEXITY_SEARCH_COST_USD = 0.005;
const TAVILY_BASIC_SEARCH_COST_USD = 0.008;

type ElderWandTier = "cloud_pro" | "ultra";
type HostedSearchProvider = "perplexity" | "tavily";

interface HostedSearchRequest {
  query?: unknown;
  sessionId?: unknown;
  runId?: unknown;
  toolCallId?: unknown;
  maxResults?: unknown;
  runSearchCap?: unknown;
}

interface HostedSearchResult {
  title: string;
  url: string;
  snippet?: string;
  publishedAt?: string;
}

interface HostedSearchResponse {
  provider: HostedSearchProvider;
  cached: boolean;
  results: HostedSearchResult[];
  monthKey: string;
  quota: {
    meter: "fusion_searches";
    included: number;
    purchased: number;
    used: number;
    remaining: number;
    monthlyCap: number;
    resetAt: string;
  };
}

interface AllowanceNumbers {
  included: number;
  used: number;
  purchased: number;
  monthlyCap: number;
}

interface SearchClaim {
  monthKey: string;
  runId: string;
  queryHash: string;
  cacheDocId: string;
  lockId: string;
  cached?: HostedSearchResponse;
}

interface ProviderSearchPayload {
  provider: HostedSearchProvider;
  results: HostedSearchResult[];
  costUSD: number;
}

function secretValue(secret: ReturnType<typeof defineSecret>): string {
  try {
    return secret.value().trim();
  } catch {
    return "";
  }
}

function nowISO(): string {
  return new Date().toISOString();
}

function nextMonthResetISO(monthKey: string): string {
  const [yearRaw, monthRaw] = monthKey.split("-");
  const year = Number(yearRaw);
  const month = Number(monthRaw);
  if (!Number.isInteger(year) || !Number.isInteger(month)) {
    return new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
  }
  return new Date(Date.UTC(month === 12 ? year + 1 : year, month === 12 ? 0 : month, 1)).toISOString();
}

function numberFromDoc(raw: FirebaseFirestore.DocumentData | undefined, field: string, fallback = 0): number {
  const value = raw?.[field];
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function activeEntitlement(raw: FirebaseFirestore.DocumentData | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  const expireAt = raw.expireAt;
  if (isTimestampWithToMillis(expireAt)) return expireAt.toMillis() > Date.now();
  if (typeof raw.expiresAt === "string") {
    const parsed = Date.parse(raw.expiresAt);
    return Number.isFinite(parsed) && parsed > Date.now();
  }
  return true;
}

async function activeElderWandTier(uid: string): Promise<ElderWandTier> {
  const [ultraSnap, proSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get(),
  ]);
  if (activeEntitlement(ultraSnap.data())) return "ultra";
  if (activeEntitlement(proSnap.data())) return "cloud_pro";
  throw new HttpsError("permission-denied", "BurnBar Cloud Pro or Ultra is required for hosted Fusion search.");
}

function allowanceDefaults(tier: ElderWandTier, config: Awaited<ReturnType<typeof loadCloudProAllowanceConfig>>) {
  if (tier === "ultra") {
    return {
      included: config.includedUltraFusionSearchesMonthly,
      monthlyCap: config.monthlyUltraFusionSearchCap,
    };
  }
  return {
    included: config.includedFusionSearchesMonthly,
    monthlyCap: config.monthlyFusionSearchCap,
  };
}

function normalizeQuery(raw: unknown): string {
  if (Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", "query must be a single string, not an array.");
  }
  const query = boundedTrimmedString(raw, "query", MAX_QUERY_CHARS, true)?.replace(/\s+/g, " ").trim();
  if (!query) throw new HttpsError("invalid-argument", "query is required.");
  return query;
}

function queryHash(query: string): string {
  return createHash("sha256").update(query.toLowerCase()).digest("hex");
}

function boundedPositiveInteger(raw: unknown, fallback: number, max: number): number {
  const parsed = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.max(1, Math.min(max, Math.floor(parsed)));
}

function cachedResponse(raw: FirebaseFirestore.DocumentData | undefined): HostedSearchResponse | undefined {
  if (!raw || raw.status !== "ready" || !Array.isArray(raw.results)) return undefined;
  const provider = raw.provider === "tavily" ? "tavily" : raw.provider === "perplexity" ? "perplexity" : undefined;
  const quotaRaw = isRecord(raw.quota) ? raw.quota : undefined;
  if (!provider || !quotaRaw) return undefined;
  const results = normalizeProviderResults(raw.results);
  return {
    provider,
    cached: true,
    results,
    monthKey: typeof raw.monthKey === "string" ? raw.monthKey : monthKeyForDate(new Date()),
    quota: {
      meter: "fusion_searches",
      included: Number(quotaRaw.included) || 0,
      purchased: Number(quotaRaw.purchased) || 0,
      used: Number(quotaRaw.used) || 0,
      remaining: Number(quotaRaw.remaining) || 0,
      monthlyCap: Number(quotaRaw.monthlyCap) || 0,
      resetAt: typeof quotaRaw.resetAt === "string" ? quotaRaw.resetAt : nextMonthResetISO(monthKeyForDate(new Date())),
    },
  };
}

async function waitForCachedResponse(cachePath: string): Promise<HostedSearchResponse | undefined> {
  const deadline = Date.now() + PENDING_WAIT_MS;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, PENDING_POLL_MS));
    const snap = await db.doc(cachePath).get();
    const cached = cachedResponse(snap.data());
    if (cached) return cached;
  }
  return undefined;
}

async function claimSearch(args: {
  uid: string;
  tier: ElderWandTier;
  query: string;
  sessionId: string;
  runId: string;
  runSearchCap: number;
}): Promise<SearchClaim> {
  const monthKey = monthKeyForDate(new Date());
  const hash = queryHash(args.query);
  const allowanceRef = db.doc(allowanceDocPath(args.uid, monthKey));
  const runRef = allowanceRef.collection("fusion_search_runs").doc(requiredIdentifier(args.runId, "runId"));
  const cacheDocId = requiredIdentifier(`${args.runId}_${hash.slice(0, 32)}`, "cacheDocId");
  const cacheRef = allowanceRef.collection("fusion_search_cache").doc(cacheDocId);
  const lockId = randomBytes(12).toString("hex");
  const allowanceConfig = await loadCloudProAllowanceConfig();
  const defaults = allowanceDefaults(args.tier, allowanceConfig);

  const transactionResult = await db.runTransaction(async (transaction) => {
    const [cacheSnap, runSnap, allowanceSnap] = await Promise.all([
      transaction.get(cacheRef),
      transaction.get(runRef),
      transaction.get(allowanceRef),
    ]);
    const cached = cachedResponse(cacheSnap.data());
    if (cached) return { cached };

    const cache = cacheSnap.data();
    const existingLockExpiresAt = cache?.lockExpiresAt;
    const lockStillActive =
      isTimestampWithToMillis(existingLockExpiresAt) && existingLockExpiresAt.toMillis() > Date.now();
    if (cache?.status === "pending" && lockStillActive) {
      return { pendingPath: cacheRef.path };
    }

    const attemptedSearches = numberFromDoc(runSnap.data(), "attemptedSearches", 0);
    if (attemptedSearches >= args.runSearchCap) {
      throw new HttpsError("resource-exhausted", "Fusion hosted search quota reached for this request.", {
        meter: "fusion_searches",
        runId: args.runId,
        attemptedSearches,
        runSearchCap: args.runSearchCap,
      });
    }

    const allowance = allowanceSnap.data();
    const preflight = evaluateCloudProAllowanceReservation({
      includedUnits: numberFromDoc(allowance, "includedFusionSearches", defaults.included),
      usedUnits: numberFromDoc(allowance, "fusionSearchesUsed", 0),
      topUpUnits: numberFromDoc(allowance, "topupFusionSearchesPurchased", 0),
      monthlyCap: numberFromDoc(allowance, "monthlyFusionSearchCap", defaults.monthlyCap),
      requestedUnits: 1,
    });
    if (!preflight.ok) {
      throw new HttpsError("resource-exhausted", "Fusion hosted search quota is exhausted.", {
        meter: "fusion_searches",
        monthKey,
        availableUnits: preflight.availableUnits,
        monthlyCapRemaining: preflight.monthlyCapRemaining,
        reason: preflight.reason,
      });
    }

    const now = Timestamp.now();
    transaction.set(
      runRef,
      {
        uid: args.uid,
        monthKey,
        sessionId: args.sessionId,
        runId: args.runId,
        attemptedSearches: FieldValue.increment(1),
        updatedAt: now,
        schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
      },
      { merge: true },
    );
    transaction.set(
      cacheRef,
      {
        uid: args.uid,
        monthKey,
        sessionId: args.sessionId,
        runId: args.runId,
        queryHash: hash,
        status: "pending",
        lockId,
        lockExpiresAt: Timestamp.fromMillis(Date.now() + PENDING_LOCK_TTL_MS),
        createdAt: now,
        updatedAt: now,
        schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
      },
      { merge: true },
    );
    return {};
  });

  if (transactionResult.cached) {
    return { monthKey, runId: args.runId, queryHash: hash, cacheDocId, lockId, cached: transactionResult.cached };
  }
  if (transactionResult.pendingPath) {
    const cached = await waitForCachedResponse(transactionResult.pendingPath);
    if (cached) return { monthKey, runId: args.runId, queryHash: hash, cacheDocId, lockId, cached };
    throw new HttpsError("aborted", "Another Fusion search for this query is still running. Retry shortly.");
  }

  return { monthKey, runId: args.runId, queryHash: hash, cacheDocId, lockId };
}

function normalizeProviderResults(raw: unknown[]): HostedSearchResult[] {
  return raw.flatMap((item): HostedSearchResult[] => {
    if (!isRecord(item)) return [];
    const url = typeof item.url === "string" ? item.url.trim() : "";
    if (!url.startsWith("http://") && !url.startsWith("https://")) return [];
    const title =
      boundedTrimmedString(item.title, "result.title", 180, false) ??
      boundedTrimmedString(item.name, "result.name", 180, false) ??
      url;
    const snippet =
      boundedTrimmedString(item.snippet, "result.snippet", 800, false) ??
      boundedTrimmedString(item.content, "result.content", 800, false) ??
      boundedTrimmedString(item.description, "result.description", 800, false);
    const publishedAt =
      boundedTrimmedString(item.date, "result.date", 80, false) ??
      boundedTrimmedString(item.published_date, "result.published_date", 80, false) ??
      boundedTrimmedString(item.last_updated, "result.last_updated", 80, false);
    return [
      stripUndefinedObject({
        title,
        url,
        snippet,
        publishedAt,
      }) as HostedSearchResult,
    ];
  });
}

async function searchPerplexity(query: string, maxResults: number): Promise<ProviderSearchPayload> {
  const apiKey = secretValue(PERPLEXITY_API_KEY);
  if (!apiKey) throw new HttpsError("failed-precondition", "Perplexity Search API key is not configured.");
  const response = await providerFetch("perplexity", "search", "https://api.perplexity.ai/search", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      query,
      max_results: maxResults,
    }),
  });
  if (!response.ok) {
    throw new HttpsError("unavailable", `Perplexity search returned HTTP ${response.status}.`);
  }
  const json = (await response.json()) as unknown;
  const root = isRecord(json) ? json : {};
  const rawResults = Array.isArray(root.results)
    ? root.results
    : Array.isArray(root.search_results)
      ? root.search_results
      : [];
  return {
    provider: "perplexity",
    results: normalizeProviderResults(rawResults).slice(0, maxResults),
    costUSD: PERPLEXITY_SEARCH_COST_USD,
  };
}

async function searchTavily(query: string, maxResults: number): Promise<ProviderSearchPayload> {
  const apiKey = secretValue(TAVILY_API_KEY);
  if (!apiKey) throw new HttpsError("failed-precondition", "Tavily API key is not configured.");
  const response = await providerFetch("tavily", "search", "https://api.tavily.com/search", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      query,
      search_depth: "basic",
      max_results: maxResults,
      include_answer: false,
      include_images: false,
      include_raw_content: false,
    }),
  });
  if (!response.ok) {
    throw new HttpsError("unavailable", `Tavily search returned HTTP ${response.status}.`);
  }
  const json = (await response.json()) as unknown;
  const root = isRecord(json) ? json : {};
  const rawResults = Array.isArray(root.results) ? root.results : [];
  return {
    provider: "tavily",
    results: normalizeProviderResults(rawResults).slice(0, maxResults),
    costUSD: TAVILY_BASIC_SEARCH_COST_USD,
  };
}

async function performProviderSearch(query: string, maxResults: number): Promise<ProviderSearchPayload> {
  const errors: string[] = [];
  try {
    return await searchPerplexity(query, maxResults);
  } catch (err) {
    errors.push(errorMessage(err));
  }

  try {
    return await searchTavily(query, maxResults);
  } catch (err) {
    errors.push(errorMessage(err));
  }

  throw new HttpsError("unavailable", "No hosted search provider completed successfully.", {
    providers: ["perplexity", "tavily"],
    errors: errors.slice(0, 4),
  });
}

function quotaResponse(numbers: AllowanceNumbers, monthKey: string): HostedSearchResponse["quota"] {
  const limit = Math.min(numbers.monthlyCap, numbers.included + numbers.purchased);
  return {
    meter: "fusion_searches",
    included: numbers.included,
    purchased: numbers.purchased,
    used: numbers.used,
    remaining: Math.max(0, limit - numbers.used),
    monthlyCap: numbers.monthlyCap,
    resetAt: nextMonthResetISO(monthKey),
  };
}

async function commitSuccessfulSearch(args: {
  uid: string;
  tier: ElderWandTier;
  claim: SearchClaim;
  providerPayload: ProviderSearchPayload;
  toolCallId?: string;
}): Promise<HostedSearchResponse> {
  const allowanceRef = db.doc(allowanceDocPath(args.uid, args.claim.monthKey));
  const cacheRef = allowanceRef.collection("fusion_search_cache").doc(args.claim.cacheDocId);
  const runRef = allowanceRef.collection("fusion_search_runs").doc(requiredIdentifier(args.claim.runId, "runId"));
  const usageRef = db
    .collection(`users/${args.uid}/usage`)
    .doc(requiredIdentifier(`elder_wand_search_${args.claim.runId}_${args.claim.queryHash.slice(0, 24)}`, "usageId"));
  const quotaRef = db.doc(`users/${args.uid}/quota_snapshots/openburnbar_elder_wand_fusion`);
  const allowanceConfig = await loadCloudProAllowanceConfig();
  const defaults = allowanceDefaults(args.tier, allowanceConfig);

  return db.runTransaction(async (transaction) => {
    const [allowanceSnap, cacheSnap] = await Promise.all([transaction.get(allowanceRef), transaction.get(cacheRef)]);
    const cache = cacheSnap.data();
    if (cache?.status === "ready") {
      const cached = cachedResponse(cache);
      if (cached) return cached;
    }
    if (cache?.lockId !== args.claim.lockId) {
      throw new HttpsError("aborted", "Fusion search lock expired before quota could be committed.");
    }

    const allowance = allowanceSnap.data();
    const before: AllowanceNumbers = {
      included: numberFromDoc(allowance, "includedFusionSearches", defaults.included),
      used: numberFromDoc(allowance, "fusionSearchesUsed", 0),
      purchased: numberFromDoc(allowance, "topupFusionSearchesPurchased", 0),
      monthlyCap: numberFromDoc(allowance, "monthlyFusionSearchCap", defaults.monthlyCap),
    };
    const evaluation = evaluateCloudProAllowanceReservation({
      includedUnits: before.included,
      usedUnits: before.used,
      topUpUnits: before.purchased,
      monthlyCap: before.monthlyCap,
      requestedUnits: 1,
    });
    if (!evaluation.ok) {
      throw new HttpsError("resource-exhausted", "Fusion hosted search quota is exhausted.", {
        meter: "fusion_searches",
        monthKey: args.claim.monthKey,
        availableUnits: evaluation.availableUnits,
        monthlyCapRemaining: evaluation.monthlyCapRemaining,
        reason: evaluation.reason,
      });
    }

    const after: AllowanceNumbers = {
      ...before,
      used: evaluation.usedAfter,
    };
    const quota = quotaResponse(after, args.claim.monthKey);
    const now = Timestamp.now();
    const nowString = nowISO();
    const response: HostedSearchResponse = {
      provider: args.providerPayload.provider,
      cached: false,
      results: args.providerPayload.results,
      monthKey: args.claim.monthKey,
      quota,
    };

    transaction.set(
      allowanceRef,
      {
        includedFusionSearches: defaults.included,
        fusionSearchesUsed: FieldValue.increment(1),
        topupFusionSearchesPurchased: FieldValue.increment(0),
        monthlyFusionSearchCap: defaults.monthlyCap,
        updatedAt: now,
        schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
      },
      { merge: true },
    );
    transaction.set(
      cacheRef,
      {
        status: "ready",
        provider: args.providerPayload.provider,
        results: args.providerPayload.results,
        quota,
        lockExpiresAt: now,
        updatedAt: now,
        schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
      },
      { merge: true },
    );
    transaction.set(
      runRef,
      {
        successfulSearches: FieldValue.increment(1),
        updatedAt: now,
      },
      { merge: true },
    );
    transaction.set(
      usageRef,
      stripUndefinedObject({
        provider: "openburnbar",
        providerID: "openburnbar",
        providerAccountID: "elder-wand-fusion",
        providerAccountLabel: "Elder Wand Fusion hosted search",
        providerAccountSource: "server_private",
        model: `elder-wand-search/${args.providerPayload.provider}`,
        sessionId: args.claim.runId,
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
        costUSD: args.providerPayload.costUSD,
        currency: "USD",
        recordedAt: nowString,
        eventKind: "elder_wand_hosted_search",
        idempotencyKey: args.claim.queryHash,
        queryHash: args.claim.queryHash,
        toolCallId: args.toolCallId,
        schemaVersion: 2,
        updatedAt: nowString,
      }),
      { merge: true },
    );
    transaction.set(
      quotaRef,
      {
        sourceKind: "provider",
        sourceId: "elder-wand-fusion",
        provider: "OpenBurnBar",
        providerID: "openburnbar",
        accountID: "elder-wand-fusion",
        accountLabel: "Elder Wand Fusion",
        accountStorageScope: "server_private",
        fetchedAt: nowString,
        source: "OpenBurnBar hosted search",
        sourceLabel: "OpenBurnBar hosted search",
        resetAt: quota.resetAt,
        planTier: args.tier === "ultra" ? "Ultra" : "Cloud Pro",
        confidence: "high",
        managementURL: "https://openburnbar.com",
        statusMessage: `${quota.remaining} hosted Fusion searches remaining this month.`,
        buckets: [
          {
            name: "Elder Wand hosted searches",
            used: quota.used,
            limit: Math.min(quota.monthlyCap, quota.included + quota.purchased),
            unit: "searches",
            remaining: quota.remaining,
            window: "monthly",
            resetAt: quota.resetAt,
          },
        ],
        schemaVersion: 2,
        updatedAt: nowString,
      },
      { merge: true },
    );

    return response;
  });
}

async function markFailedClaim(claim: SearchClaim, uid: string, error: unknown): Promise<void> {
  const cacheRef = db
    .doc(allowanceDocPath(uid, claim.monthKey))
    .collection("fusion_search_cache")
    .doc(claim.cacheDocId);
  await cacheRef.set(
    {
      status: "failed",
      error: errorMessage(error).slice(0, 240),
      lockExpiresAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    },
    { merge: true },
  );
}

export const performElderWandHostedSearch = onCallProduction<HostedSearchRequest, HostedSearchResponse>(
  "performElderWandHostedSearch",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
    secrets: HOSTED_SEARCH_SECRETS,
  },
  async (request: CallableRequest<HostedSearchRequest>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before using hosted Fusion search.");
    enforceAuthAndAppCheck(request, uid);
    await assertCloudFeatureNotSuspended(db, uid, "elder_wand_search");

    const tier = await activeElderWandTier(uid);
    const query = normalizeQuery(request.data.query);
    const sessionId =
      boundedTrimmedString(request.data.sessionId, "sessionId", 128, false) ??
      boundedTrimmedString(request.data.runId, "runId", 128, false) ??
      "elder-wand";
    const runId =
      boundedTrimmedString(request.data.runId, "runId", 128, false) ??
      boundedTrimmedString(request.data.sessionId, "sessionId", 128, false) ??
      sessionId;
    const toolCallId = boundedTrimmedString(request.data.toolCallId, "toolCallId", 128, false);
    const maxResults = boundedPositiveInteger(request.data.maxResults, MAX_RESULTS, MAX_RESULTS);
    const runSearchCap = boundedPositiveInteger(request.data.runSearchCap, DEFAULT_RUN_SEARCH_CAP, ABSOLUTE_RUN_SEARCH_CAP);

    const claim = await claimSearch({ uid, tier, query, sessionId, runId, runSearchCap });
    if (claim.cached) return claim.cached;

    try {
      const providerPayload = await performProviderSearch(query, maxResults);
      return await commitSuccessfulSearch({ uid, tier, claim, providerPayload, toolCallId });
    } catch (err) {
      await markFailedClaim(claim, uid, err);
      logWarn({
        event: "elder_wand_hosted_search.failed",
        uid,
        providerFallback: "perplexity_tavily",
        error: errorMessage(err),
      });
      throw err;
    }
  },
);
