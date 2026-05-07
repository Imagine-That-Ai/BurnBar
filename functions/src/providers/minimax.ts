/**
 * @fileoverview MiniMax provider adapter.
 *
 * MiniMax exposes a single canonical "remains" endpoint for the Token Plan
 * subscription:
 *
 *   GET https://www.minimax.io/v1/token_plan/remains
 *   Authorization: Bearer <api-key>
 *
 * (See: https://platform.minimax.io/docs/token-plan/faq — "Method 2: Use the
 * API Endpoint".)
 *
 * The legacy host `api.minimax.chat` no longer serves account/balance endpoints
 * (returns 404), so we standardize on `www.minimax.io/v1` for both validation
 * and quota refresh. The "openplatform/coding_plan/remains" path the macOS
 * adapter uses for Coding Plan keys is kept as a fallback for users who paste
 * an `sk-cp-…` Coding Plan key instead of a Token Plan key.
 *
 * MiniMax wraps every response in `{ base_resp: { status_code, status_msg } }`
 * even when HTTP=200. `status_code != 0` indicates a logical error (auth,
 * format, etc.) which we surface to the caller instead of treating the call
 * as successful.
 */

import type {
  ProviderAdapter,
  CredentialTestResult,
  QuotaRefreshResult,
  QuotaBucket,
} from "../types.js";

const PROVIDER = "minimax" as const;

const TOKEN_PLAN_URL = "https://www.minimax.io/v1/token_plan/remains";
const CODING_PLAN_URL =
  "https://www.minimax.io/v1/api/openplatform/coding_plan/remains";

/** Extract a redacted label from a long token. */
function redact(token: string): string {
  if (token.length <= 8) return "minimax_***";
  return `minimax_${token.slice(0, 2)}***${token.slice(-4)}`;
}

interface MiniMaxBaseResp {
  status_code?: number;
  status_msg?: string;
}

interface MiniMaxRemainsPayload {
  base_resp?: MiniMaxBaseResp;
  // Token Plan response shape (varies between subscription tiers, but always
  // contains an array of model rows with usage counters).
  model_remains?: Array<{
    model_name?: string;
    period?: string;
    used?: number;
    remains?: number;
    total?: number;
    [k: string]: unknown;
  }>;
  // Coding Plan response shape historically returned a flat object — we keep
  // a permissive index signature so downstream consumers can still inspect it.
  [k: string]: unknown;
}

interface MiniMaxFetchResult {
  ok: boolean;
  status?: number;
  data?: MiniMaxRemainsPayload;
  /** Logical error message extracted from `base_resp` or HTTP status. */
  error?: string;
  /** Stable error code suitable for callers (e.g. `auth_failed`). */
  errorCode?: string;
}

async function minimaxFetch(
  url: string,
  token: string
): Promise<MiniMaxFetchResult> {
  let response: Response;
  try {
    response = await fetch(url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
      },
    });
  } catch (err) {
    return { ok: false, error: String(err), errorCode: "network_error" };
  }

  let payload: MiniMaxRemainsPayload | undefined;
  try {
    payload = (await response.json()) as MiniMaxRemainsPayload;
  } catch {
    payload = undefined;
  }

  if (!response.ok) {
    const baseMessage = payload?.base_resp?.status_msg;
    return {
      ok: false,
      status: response.status,
      data: payload,
      error: baseMessage ? `HTTP ${response.status}: ${baseMessage}` : `HTTP ${response.status}`,
      errorCode:
        response.status === 401 || response.status === 403
          ? "auth_failed"
          : response.status === 404
            ? "endpoint_not_found"
            : "fetch_failed",
    };
  }

  // MiniMax always returns 200 with an inline status_code; treat anything
  // other than `0` (or omitted, which means success on some endpoints) as a
  // logical failure.
  const baseResp = payload?.base_resp ?? {};
  if (
    typeof baseResp.status_code === "number" &&
    baseResp.status_code !== 0 &&
    baseResp.status_code !== 200
  ) {
    const code = baseResp.status_code;
    const msg = baseResp.status_msg || `MiniMax error ${code}`;
    return {
      ok: false,
      status: response.status,
      data: payload,
      error: msg,
      errorCode: code === 1004 || code === 1001 ? "auth_failed" : "minimax_error",
    };
  }

  return { ok: true, status: response.status, data: payload };
}

/** Try Token Plan first, then fall back to Coding Plan keys for sk-cp-… users. */
async function fetchRemains(token: string): Promise<MiniMaxFetchResult> {
  const trimmed = token.trim();
  // Coding plan keys must hit the coding-plan endpoint; the token-plan
  // endpoint will reject them as "cookie missing".
  const isCodingPlan = trimmed.toLowerCase().startsWith("sk-cp-");
  if (isCodingPlan) {
    const codingResult = await minimaxFetch(CODING_PLAN_URL, trimmed);
    if (codingResult.ok) return codingResult;
    // Fall through to token-plan only when the failure is NOT auth-related —
    // a wrong endpoint ("cookie missing", 1004) deserves a clear error to the
    // user rather than silently masking it with a Token Plan auth failure.
    return codingResult;
  }

  const tokenPlan = await minimaxFetch(TOKEN_PLAN_URL, trimmed);
  if (tokenPlan.ok) return tokenPlan;
  // If the Token Plan call failed because of an unknown endpoint or unrelated
  // error, try the Coding Plan path as a courtesy. We do NOT fall back when
  // the failure is an explicit auth rejection.
  if (tokenPlan.errorCode === "auth_failed") {
    return tokenPlan;
  }
  const coding = await minimaxFetch(CODING_PLAN_URL, trimmed);
  if (coding.ok) return coding;
  // Surface the most informative original failure.
  return tokenPlan.errorCode ? tokenPlan : coding;
}

export const minimaxAdapter: ProviderAdapter = {
  provider: PROVIDER,

  async testCredential(credential: string): Promise<CredentialTestResult> {
    const trimmed = (credential ?? "").trim();
    if (trimmed.length < 8) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: "invalid_format",
        errorMessage: "MiniMax token must be at least 8 characters.",
      };
    }

    const result = await fetchRemains(trimmed);
    if (!result.ok) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: result.errorCode ?? "validation_failed",
        errorMessage: result.error || "MiniMax validation request failed.",
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
    sourceId: string
  ): Promise<QuotaRefreshResult> {
    const trimmed = (credential ?? "").trim();
    const result = await fetchRemains(trimmed);
    if (!result.ok) {
      return {
        ok: false,
        errorCode: result.errorCode ?? "fetch_failed",
        errorMessage: result.error || "MiniMax remains request failed.",
      };
    }

    const buckets = extractBuckets(result.data);

    return {
      ok: true,
      snapshot: {
        sourceKind: "provider",
        sourceId,
        provider: PROVIDER,
        fetchedAt: new Date().toISOString(),
        source: "MiniMax Token Plan",
        confidence: buckets.length ? "high" : "low",
        statusMessage: buckets.length
          ? "Fetched from MiniMax token-plan remains endpoint."
          : "MiniMax remains endpoint returned no recognizable buckets.",
        buckets,
      },
    };
  },
};

/**
 * Convert the MiniMax remains payload to the canonical {@link QuotaBucket}
 * shape. We accept three flavors: Token Plan (`model_remains` array), Coding
 * Plan (`data.model_remains`), and any flat `{used, total, remains}` payload.
 */
export function extractBuckets(
  payload: MiniMaxRemainsPayload | undefined
): QuotaBucket[] {
  if (!payload) return [];

  const rows = collectModelRows(payload);
  if (rows.length > 0) {
    return rows.map((row, index) => {
      const used = numberFrom(row.used);
      const total = numberFrom(row.total);
      const remains = numberFrom(row.remains, total !== undefined && used !== undefined ? Math.max(0, total - used) : undefined);
      const name = stringFrom(row.model_name) ?? `plan_${index + 1}`;
      return {
        name: `${name}${row.period ? ` (${row.period})` : ""}`,
        used: used ?? 0,
        limit: total ?? -1,
        remaining: remains ?? -1,
        window: stringFrom(row.period) ?? "account",
        meta: stripUndefined({
          model_name: stringFrom(row.model_name),
          period: stringFrom(row.period),
        }),
      };
    });
  }

  // Some Coding Plan deployments return a flat object with `used`, `total`,
  // `remains` at the top level. Fall back to that shape if `model_remains` is
  // missing.
  const top = numberFrom(payload.used);
  const limit = numberFrom(payload.total);
  const remaining = numberFrom(payload.remains, limit !== undefined && top !== undefined ? Math.max(0, limit - top) : undefined);
  if (top !== undefined || limit !== undefined || remaining !== undefined) {
    return [
      {
        name: "tokens",
        used: top ?? 0,
        limit: limit ?? -1,
        remaining: remaining ?? -1,
        window: "account",
      },
    ];
  }

  // Last resort — recursively walk the payload for any node that looks like
  // `{used, limit, remaining}` under one of MiniMax's many naming conventions
  // (Coding Plan, Token Plan, Open Platform balances). The dashboard prefers
  // a coarse-but-real bucket over a blank "no signal" state.
  const harvested = harvestMiniMaxBuckets(payload);
  return harvested;
}

const MINIMAX_USED_KEYS = [
  "used", "used_num", "usedNum", "current_usage", "currentUsage",
  "current", "consumed", "current_interval_used_count",
  "currentIntervalUsedCount", "request_used", "requestsUsed",
  "use_count", "useCount",
] as const;

const MINIMAX_LIMIT_KEYS = [
  "total", "limit", "total_num", "totalNum", "max", "max_value",
  "max_count", "maxCount", "quota", "quota_limit", "quotaLimit",
  "request_limit", "requestLimit", "current_interval_total_count",
  "currentIntervalTotalCount",
] as const;

const MINIMAX_REMAINING_KEYS = [
  "remains", "remaining", "remain", "remaining_quota", "remainingQuota",
  "quota_remain", "quotaRemain", "available", "left",
  "current_interval_remaining_count", "currentIntervalRemainingCount",
  "current_interval_remains_count", "currentIntervalRemainsCount",
  "remain_count", "remainCount",
] as const;

const MINIMAX_NAME_KEYS = [
  "model_name", "modelName", "name", "title", "label", "resource_name",
  "resourceName",
] as const;

function harvestMiniMaxBuckets(payload: unknown): QuotaBucket[] {
  const buckets: QuotaBucket[] = [];
  const seen = new Set<string>();

  function walk(node: unknown, path: string[]): void {
    if (!node || typeof node !== "object") return;

    if (Array.isArray(node)) {
      node.forEach((item, idx) => walk(item, [...path, `[${idx}]`]));
      return;
    }

    const obj = node as Record<string, unknown>;
    const candidate = miniMaxBucketFromObject(obj, path);
    if (candidate) {
      const key = `${candidate.name}|${candidate.window}|${candidate.limit}|${candidate.used}`;
      if (!seen.has(key)) {
        seen.add(key);
        buckets.push(candidate);
      }
    }

    for (const [k, v] of Object.entries(obj)) {
      if (v && typeof v === "object") {
        walk(v, [...path, k]);
      }
    }
  }

  walk(payload, []);
  return buckets;
}

function miniMaxBucketFromObject(
  obj: Record<string, unknown>,
  path: string[]
): QuotaBucket | undefined {
  function pickNumber(keys: readonly string[]): number | undefined {
    for (const key of keys) {
      const value = numberFrom(obj[key]);
      if (value !== undefined) return value;
    }
    return undefined;
  }
  function pickString(keys: readonly string[]): string | undefined {
    for (const key of keys) {
      const value = stringFrom(obj[key]);
      if (value !== undefined) return value;
    }
    return undefined;
  }

  const used = pickNumber(MINIMAX_USED_KEYS);
  const limit = pickNumber(MINIMAX_LIMIT_KEYS);
  const remaining = pickNumber(MINIMAX_REMAINING_KEYS);

  if (used === undefined && limit === undefined && remaining === undefined) {
    return undefined;
  }
  if (
    (limit === undefined || limit <= 0) &&
    (remaining === undefined || remaining <= 0) &&
    (used === undefined || used <= 0)
  ) {
    return undefined;
  }

  const name =
    pickString(MINIMAX_NAME_KEYS) ?? path[path.length - 1] ?? "tokens";
  const period = pickString(["period", "window", "cycle", "period_name", "periodName"]) ?? "account";

  const finalUsed =
    used ?? (limit !== undefined && remaining !== undefined ? Math.max(0, limit - remaining) : 0);
  const finalLimit = limit ?? -1;
  const finalRemaining =
    remaining ??
    (finalLimit >= 0 && finalUsed >= 0 ? Math.max(0, finalLimit - finalUsed) : -1);

  return {
    name,
    used: finalUsed,
    limit: finalLimit,
    remaining: finalRemaining,
    window: period,
  };
}

function collectModelRows(
  payload: MiniMaxRemainsPayload
): NonNullable<MiniMaxRemainsPayload["model_remains"]> {
  if (Array.isArray(payload.model_remains)) {
    return payload.model_remains;
  }
  // Coding Plan responses sometimes wrap the rows under `data.model_remains`.
  const data = (payload as { data?: { model_remains?: unknown } }).data;
  if (data && Array.isArray(data.model_remains)) {
    return data.model_remains as NonNullable<MiniMaxRemainsPayload["model_remains"]>;
  }
  return [];
}

function numberFrom(raw: unknown, fallback?: number): number | undefined {
  if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  if (typeof raw === "string") {
    const value = Number(raw.trim());
    if (Number.isFinite(value)) return value;
  }
  return fallback;
}

function stringFrom(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  return value.length > 0 ? value : undefined;
}

function stripUndefined(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(value).filter(([, v]) => v !== undefined)
  );
}

export const __testing__ = {
  fetchRemains,
  extractBuckets,
  TOKEN_PLAN_URL,
  CODING_PLAN_URL,
};
