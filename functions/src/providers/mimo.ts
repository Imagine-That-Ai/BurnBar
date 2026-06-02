/**
 * @fileoverview Xiaomi MiMo provider adapter.
 *
 * Supports two billing lanes:
 *   • Token Plan (`tp-…`) — regional token-plan hosts + optional `/token_plan/remains`
 *   • Pay-as-you-go (`sk-…`) — `https://api.xiaomimimo.com/v1` (routing only; no balance API)
 */

import type {
  ProviderAdapter,
  CredentialTestResult,
  QuotaRefreshResult,
  QuotaBucket,
  ProviderAccountConnectContext,
} from "../types.js";
import { recordOrUndefined } from "../guards.js";
import { providerFetch } from "./httpClient.js";

const PROVIDER = "mimo" as const;

type MimoRegion = "cn" | "sgp" | "ams";
type MimoTokenPlanTier = "lite" | "standard" | "pro" | "max";

const PAYG_BASE = "https://api.xiaomimimo.com/v1";

const TOKEN_PLAN_HOSTS: Record<MimoRegion, string> = {
  cn: "https://token-plan-cn.xiaomimimo.com/v1",
  sgp: "https://token-plan-sgp.xiaomimimo.com/v1",
  ams: "https://token-plan-ams.xiaomimimo.com/v1",
};

const TIER_MONTHLY_CREDITS: Record<MimoTokenPlanTier, number> = {
  lite: 60_000_000,
  standard: 200_000_000,
  pro: 700_000_000,
  max: 1_600_000_000,
};

function redact(token: string): string {
  const trimmed = (token ?? "").trim();
  if (trimmed.length <= 8) return "mimo_***";
  return `mimo_${trimmed.slice(0, 4)}***${trimmed.slice(-4)}`;
}

function keyKind(apiKey: string): "token_plan" | "payg" | "unknown" {
  const lower = apiKey.trim().toLowerCase();
  if (lower.startsWith("tp-")) return "token_plan";
  if (lower.startsWith("sk-")) return "payg";
  return "unknown";
}

function resolveRegion(ctx: ProviderAccountConnectContext | undefined, apiKey: string): MimoRegion | null {
  const region = ctx?.region;
  if (region === "cn" || region === "sgp" || region === "ams") {
    return region;
  }
  const profile = ctx?.endpointProfileID ?? "";
  if (profile.endsWith(".cn")) return "cn";
  if (profile.endsWith(".sgp")) return "sgp";
  if (profile.endsWith(".ams")) return "ams";
  if (keyKind(apiKey) === "token_plan") {
    return null;
  }
  return null;
}

function resolveInferenceBase(ctx: ProviderAccountConnectContext | undefined, apiKey: string): string {
  const kind = keyKind(apiKey);
  if (kind === "payg") return PAYG_BASE;
  const region = resolveRegion(ctx, apiKey);
  if (!region) {
    throw new Error("Token Plan keys require a region (cn, sgp, or ams).");
  }
  return TOKEN_PLAN_HOSTS[region];
}

interface FetchResult {
  ok: boolean;
  status?: number;
  data?: unknown;
  error?: string;
  errorCode?: string;
}

async function mimoFetch(url: string, token: string, authStyle: "bearer" | "api-key" = "bearer"): Promise<FetchResult> {
  const headers: Record<string, string> = {
    Accept: "application/json",
  };
  if (authStyle === "bearer") {
    headers.Authorization = `Bearer ${token}`;
  } else {
    headers["api-key"] = token;
  }

  let response: Response;
  try {
    response = await providerFetch(PROVIDER, "api", url, { method: "GET", headers });
  } catch (err) {
    return { ok: false, error: String(err), errorCode: "network_error" };
  }

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    payload = undefined;
  }

  if (!response.ok) {
    const body = recordOrUndefined(payload);
    const nestedError = recordOrUndefined(body?.error);
    const message =
      (typeof nestedError?.message === "string" ? nestedError.message : undefined) ??
      (typeof body?.message === "string" ? body.message : undefined) ??
      `HTTP ${response.status}`;
    return {
      ok: false,
      status: response.status,
      data: payload,
      error: message,
      errorCode:
        response.status === 401 || response.status === 403
          ? "auth_failed"
          : response.status === 402
            ? "insufficient_balance"
            : "fetch_failed",
    };
  }

  return { ok: true, status: response.status, data: payload };
}

async function validateModelsEndpoint(baseURL: string, token: string): Promise<FetchResult> {
  const url = `${baseURL.replace(/\/$/, "")}/models`;
  const bearer = await mimoFetch(url, token, "bearer");
  if (bearer.ok) return bearer;
  if (bearer.errorCode === "auth_failed") {
    return mimoFetch(url, token, "api-key");
  }
  return bearer;
}

function tierCreditLimit(ctx: ProviderAccountConnectContext | undefined): number | null {
  const tier = ctx?.tokenPlanTier;
  if (!tier) return null;
  const monthly = TIER_MONTHLY_CREDITS[tier];
  return ctx?.tokenPlanBillingCycle === "annual" ? monthly * 12 : monthly;
}

function parseRemainsBuckets(payload: unknown): QuotaBucket[] {
  const root = recordOrUndefined(payload);
  if (!root) return [];
  const data = recordOrUndefined(root.data) ?? root;

  const remains =
    (Array.isArray(data.model_remains) ? data.model_remains : undefined) ??
    (Array.isArray(data.remains) ? data.remains : undefined) ??
    (Array.isArray(data.credits) ? data.credits : undefined);

  if (Array.isArray(remains) && remains.length > 0) {
    const buckets: QuotaBucket[] = [];
    for (const row of remains) {
      const item = recordOrUndefined(row);
      if (!item) continue;
      const used = Number(item.used ?? item.current_interval_usage_count ?? 0);
      const total = Number(item.total ?? item.current_interval_total_count ?? item.limit ?? -1);
      const remainsVal = Number(item.remains ?? item.remaining ?? (total >= 0 ? Math.max(0, total - used) : -1));
      buckets.push({
        name: String(item.model_name ?? item.name ?? "token_plan"),
        used,
        limit: total,
        remaining: remainsVal,
        window: String(item.period ?? item.window ?? "monthly"),
        meta: { source: "vendor_remains" },
      });
    }
    if (buckets.length > 0) return buckets;
  }

  const used = Number(data.used ?? data.used_credits ?? 0);
  const total = Number(data.total ?? data.total_credits ?? data.limit ?? -1);
  const remaining = Number(
    data.remains ?? data.remaining ?? data.remaining_credits ?? (total >= 0 ? total - used : -1),
  );
  if (total > 0 || remaining >= 0) {
    return [
      {
        name: "token_plan_credits",
        used,
        limit: total,
        remaining,
        window: "monthly",
        meta: { source: "vendor_remains" },
      },
    ];
  }

  return [];
}

function ledgerBuckets(ctx: ProviderAccountConnectContext | undefined): QuotaBucket[] {
  const limit = tierCreditLimit(ctx);
  if (limit == null) return [];

  return [
    {
      name: "token_plan_credits",
      used: 0,
      limit,
      remaining: limit,
      window: ctx?.tokenPlanBillingCycle === "annual" ? "annual" : "monthly",
      meta: {
        quotaSource: "burnbar_ledger",
        endpointProfileID: ctx?.endpointProfileID,
        region: ctx?.region,
        tokenPlanTier: ctx?.tokenPlanTier,
      },
    },
  ];
}

export const mimoAdapter: ProviderAdapter = {
  provider: PROVIDER,

  async testCredential(credential: string, ctx?: ProviderAccountConnectContext): Promise<CredentialTestResult> {
    const trimmed = credential.trim();
    if (!trimmed) {
      return {
        valid: false,
        redactedLabel: "mimo_***",
        credentialKind: "bearer",
        errorCode: "empty_credential",
        errorMessage: "MiMo API key cannot be empty.",
      };
    }

    const kind = keyKind(trimmed);
    if (kind === "unknown") {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: "invalid_key_format",
        errorMessage: "MiMo keys must start with tp- (Token Plan) or sk- (pay-as-you-go).",
      };
    }

    let baseURL: string;
    try {
      baseURL = resolveInferenceBase(ctx, trimmed);
    } catch (err) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: "missing_region",
        errorMessage: String(err),
      };
    }

    const result = await validateModelsEndpoint(baseURL, trimmed);
    if (!result.ok) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: result.errorCode ?? "auth_failed",
        errorMessage: result.error ?? "MiMo rejected the API key.",
      };
    }

    return {
      valid: true,
      redactedLabel: redact(trimmed),
      credentialKind: "bearer",
    };
  },

  async fetchQuota(
    credential: string,
    sourceId: string,
    ctx?: ProviderAccountConnectContext,
  ): Promise<QuotaRefreshResult> {
    const trimmed = credential.trim();
    const kind = keyKind(trimmed);

    if (kind === "payg") {
      const validation = await validateModelsEndpoint(PAYG_BASE, trimmed);
      if (!validation.ok) {
        return {
          ok: false,
          errorCode: validation.errorCode ?? "fetch_failed",
          errorMessage: validation.error ?? "MiMo pay-as-you-go key validation failed.",
        };
      }

      return {
        ok: true,
        snapshot: {
          sourceKind: "provider",
          sourceId,
          provider: PROVIDER,
          fetchedAt: new Date().toISOString(),
          source: "MiMo Pay-as-you-go",
          confidence: "low",
          managementURL: "https://platform.xiaomimimo.com",
          statusMessage:
            "MiMo pay-as-you-go balance is only visible in the Xiaomi console. OpenBurnBar validates routing keys but does not expose PAYG balance yet.",
          buckets: [],
        },
      };
    }

    if (kind !== "token_plan") {
      return {
        ok: false,
        errorCode: "invalid_key_format",
        errorMessage: "Unsupported MiMo key format.",
      };
    }

    let baseURL: string;
    try {
      baseURL = resolveInferenceBase(ctx, trimmed);
    } catch (err) {
      return {
        ok: false,
        errorCode: "missing_region",
        errorMessage: String(err),
      };
    }

    const remainsURL = `${baseURL.replace(/\/$/, "")}/token_plan/remains`;
    const remains = await mimoFetch(remainsURL, trimmed, "bearer");
    const vendorBuckets = remains.ok ? parseRemainsBuckets(remains.data) : [];

    if (vendorBuckets.length > 0) {
      return {
        ok: true,
        snapshot: {
          sourceKind: "provider",
          sourceId,
          provider: PROVIDER,
          fetchedAt: new Date().toISOString(),
          source: "MiMo Token Plan",
          confidence: "high",
          managementURL: "https://platform.xiaomimimo.com/docs/en-US/tokenplan/subscription",
          statusMessage: "Fetched Token Plan credits from Xiaomi remains endpoint.",
          buckets: vendorBuckets,
        },
      };
    }

    const fallbackBuckets = ledgerBuckets(ctx);
    if (fallbackBuckets.length > 0) {
      return {
        ok: true,
        snapshot: {
          sourceKind: "provider",
          sourceId,
          provider: PROVIDER,
          fetchedAt: new Date().toISOString(),
          source: "MiMo Token Plan (OpenBurnBar ledger)",
          confidence: "medium",
          managementURL: "https://platform.xiaomimimo.com/docs/en-US/tokenplan/subscription",
          statusMessage: "Vendor remains endpoint unavailable. Showing tier cap for BurnBar-routed credit tracking.",
          buckets: fallbackBuckets,
        },
      };
    }

    return {
      ok: true,
      snapshot: {
        sourceKind: "provider",
        sourceId,
        provider: PROVIDER,
        fetchedAt: new Date().toISOString(),
        source: "MiMo Token Plan",
        confidence: "low",
        managementURL: "https://platform.xiaomimimo.com/docs/en-US/tokenplan/subscription",
        statusMessage:
          "Select a Token Plan tier to enable BurnBar credit tracking, or check quota in Xiaomi Subscription Management.",
        buckets: [],
      },
    };
  },
};
