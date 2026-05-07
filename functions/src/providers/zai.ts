/**
 * @fileoverview Z.ai (Zhipu / GLM) provider adapter.
 *
 * Z.ai serves the same account/usage endpoints from two regional hosts:
 *
 *   • https://api.z.ai            (international)
 *   • https://open.bigmodel.cn    (mainland China — original Zhipu host)
 *
 * Both expose:
 *   • GET /api/paas/v4/models                       — credential validation
 *   • GET /api/paas/v4/user/balance                  — pay-as-you-go balance
 *   • GET /api/monitor/usage/quota/limit            — coding-plan window limits
 *
 * Historically this adapter only hit `open.bigmodel.cn` and the now-defunct
 * `/v4/user/info` route. The mainland host is unreachable from many
 * production regions (and explicitly errors on coding-plan keys), so we
 * iterate the candidate hosts in order and fall back to whichever one
 * responds first. Validation always uses `/v4/models`, which is the only
 * stable Z.ai endpoint that accepts both account-style and coding-plan keys.
 *
 * Z.ai responses use a mix of `{ error: { code, message } }` (paas/v4) and
 * `{ code, msg, data }` (monitor/*) envelopes; both are handled here.
 */

import type {
  ProviderAdapter,
  CredentialTestResult,
  QuotaRefreshResult,
  QuotaBucket,
} from "../types.js";

const PROVIDER = "zai" as const;

const HOSTS = [
  "https://api.z.ai",
  "https://open.bigmodel.cn",
] as const;

const VALIDATE_PATH = "/api/paas/v4/models";
const BALANCE_PATH = "/api/paas/v4/user/balance";
const QUOTA_PATH = "/api/monitor/usage/quota/limit";

function redact(token: string): string {
  if (token.length <= 8) return "zai_***";
  return `zai_${token.slice(0, 2)}***${token.slice(-4)}`;
}

interface ZaiFetchResult<T> {
  ok: boolean;
  status?: number;
  data?: T;
  error?: string;
  errorCode?: string;
}

async function zaiFetch<T = unknown>(
  url: string,
  token: string
): Promise<ZaiFetchResult<T>> {
  let response: Response;
  try {
    response = await fetch(url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "Accept-Language": "en-US,en",
      },
    });
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
    const message = inlineErrorMessage(payload) ?? `HTTP ${response.status}`;
    return {
      ok: false,
      status: response.status,
      data: payload as T,
      error: message,
      errorCode:
        response.status === 401 || response.status === 403
          ? "auth_failed"
          : response.status === 404
            ? "endpoint_not_found"
            : "fetch_failed",
    };
  }

  // The monitor/* endpoints return 200 with an inline `success: false` /
  // `code: 401` envelope on bad keys.
  const inline = inlineErrorMessage(payload);
  if (inline) {
    const code = extractInlineCode(payload);
    return {
      ok: false,
      status: response.status,
      data: payload as T,
      error: inline,
      errorCode: code === 401 || code === 1001 ? "auth_failed" : "zai_error",
    };
  }

  return { ok: true, status: response.status, data: payload as T };
}

function inlineErrorMessage(payload: unknown): string | undefined {
  if (!payload || typeof payload !== "object") return undefined;
  const obj = payload as Record<string, unknown>;

  // paas/v4 error shape: { error: { code, message } }
  const error = obj.error as Record<string, unknown> | undefined;
  if (error && typeof error === "object") {
    const message = stringFromAny(error.message ?? error.msg);
    if (message) return message;
  }

  // monitor/* shape: { success: false, code, msg }
  if (obj.success === false) {
    return (
      stringFromAny(obj.msg ?? obj.message ?? obj.error) ?? "Z.ai request was unsuccessful."
    );
  }

  // monitor/* alternate shape: { code: 401, msg: "..." }
  const code = numberFromAny(obj.code);
  if (code !== undefined && code !== 0 && code !== 200) {
    const message = stringFromAny(obj.msg ?? obj.message);
    return message ?? `Z.ai error code ${code}`;
  }

  return undefined;
}

function extractInlineCode(payload: unknown): number | undefined {
  if (!payload || typeof payload !== "object") return undefined;
  const obj = payload as Record<string, unknown>;
  const direct = numberFromAny(obj.code);
  if (direct !== undefined) return direct;
  const error = obj.error as Record<string, unknown> | undefined;
  if (error && typeof error === "object") {
    return numberFromAny(error.code ?? error.status);
  }
  return undefined;
}

async function tryEachHost<T>(
  path: string,
  token: string
): Promise<ZaiFetchResult<T>> {
  let lastFailure: ZaiFetchResult<T> | undefined;
  for (const host of HOSTS) {
    const url = `${host}${path}`;
    const result = await zaiFetch<T>(url, token);
    if (result.ok) return result;
    lastFailure = result;
    // Don't try the second host when the credential is rejected — we know it
    // will fail again. Auth failures are the user's signal to fix their key.
    if (result.errorCode === "auth_failed") return result;
  }
  return lastFailure ?? {
    ok: false,
    error: "Z.ai request failed against all candidate hosts.",
    errorCode: "fetch_failed",
  };
}

interface ZaiBalancePayload {
  balance?: number;
  total?: number;
  used?: number;
  currency?: string;
  data?: { balance?: number; total?: number; used?: number; currency?: string };
}

interface ZaiQuotaRow {
  window?: string;
  windowName?: string;
  limit?: number;
  used?: number;
  remaining?: number;
}

interface ZaiMonitorQuotaPayload {
  data?: {
    /** Coding Plan keys return an array of windowed quotas. */
    quotaList?: ZaiQuotaRow[];
    [k: string]: unknown;
  };
  /** Some deployments hoist `quotaList` to the top level. */
  quotaList?: ZaiQuotaRow[];
  [k: string]: unknown;
}

export const zaiAdapter: ProviderAdapter = {
  provider: PROVIDER,

  async testCredential(credential: string): Promise<CredentialTestResult> {
    const trimmed = (credential ?? "").trim();
    if (trimmed.length < 8) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: "invalid_format",
        errorMessage: "Z.ai token must be at least 8 characters.",
      };
    }

    const result = await tryEachHost<unknown>(VALIDATE_PATH, trimmed);
    if (!result.ok) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: result.errorCode ?? "validation_failed",
        errorMessage: result.error || "Z.ai validation request failed.",
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

    type Confidence = "high" | "medium" | "low" | "stale";

    // Coding Plan keys (server-side rate windows) live under monitor/*.
    const coding = await tryEachHost<ZaiMonitorQuotaPayload>(QUOTA_PATH, trimmed);
    let buckets: QuotaBucket[] = [];
    let source = "Z.ai";
    let confidence: Confidence = "high";

    if (coding.ok) {
      buckets = bucketsFromMonitorQuota(coding.data);
      source = "Z.ai usage monitor";
      confidence = buckets.length ? "high" : "low";
    }

    if (buckets.length === 0) {
      // Pay-as-you-go balance fallback.
      const balance = await tryEachHost<ZaiBalancePayload>(BALANCE_PATH, trimmed);
      if (!balance.ok && !coding.ok) {
        // Both probes failed — surface the most useful error. Auth failures
        // win over generic "endpoint not found" misses.
        const failure =
          (coding.errorCode === "auth_failed" ? coding : balance) ?? coding ?? balance;
        return {
          ok: false,
          errorCode: failure.errorCode ?? "fetch_failed",
          errorMessage: failure.error || "Z.ai quota request failed.",
        };
      }
      if (balance.ok) {
        buckets = bucketsFromBalance(balance.data);
        source = "Z.ai balance";
        confidence = buckets.length ? "high" : "low";
      }
    }

    return {
      ok: true,
      snapshot: {
        sourceKind: "provider",
        sourceId,
        provider: PROVIDER,
        fetchedAt: new Date().toISOString(),
        source,
        confidence,
        statusMessage: buckets.length
          ? "Fetched from Z.ai (Zhipu) account endpoint."
          : "Z.ai responded but did not expose recognizable quota buckets.",
        buckets,
      },
    };
  },
};

function bucketsFromMonitorQuota(
  payload: ZaiMonitorQuotaPayload | undefined
): QuotaBucket[] {
  const list = payload?.data?.quotaList ?? payload?.quotaList;
  if (!Array.isArray(list)) return [];

  return list
    .map((row, index): QuotaBucket | undefined => {
      const used = numberFromAny(row.used) ?? 0;
      const limit = numberFromAny(row.limit) ?? -1;
      const remaining =
        numberFromAny(row.remaining) ??
        (limit >= 0 ? Math.max(0, limit - used) : -1);
      const window = stringFromAny(row.window ?? row.windowName) ?? `window_${index + 1}`;
      return {
        name: window,
        used,
        limit,
        remaining,
        window,
      };
    })
    .filter((bucket): bucket is QuotaBucket => bucket !== undefined);
}

function bucketsFromBalance(
  payload: ZaiBalancePayload | undefined
): QuotaBucket[] {
  if (!payload) return [];
  const data = payload.data ?? payload;

  const total = numberFromAny(data.total);
  const used = numberFromAny(data.used) ?? 0;
  const balance = numberFromAny(data.balance);

  if (total !== undefined) {
    return [
      {
        name: "tokens",
        used,
        limit: total,
        remaining: Math.max(0, total - used),
        window: "account",
        meta: { currency: stringFromAny(data.currency) ?? "CNY" },
      },
    ];
  }
  if (balance !== undefined) {
    return [
      {
        name: "balance",
        used: 0,
        limit: -1,
        remaining: balance,
        window: "account",
        meta: { currency: stringFromAny(data.currency) ?? "CNY" },
      },
    ];
  }
  return [];
}

function numberFromAny(raw: unknown): number | undefined {
  if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  if (typeof raw === "string") {
    const value = Number(raw.trim());
    if (Number.isFinite(value)) return value;
  }
  return undefined;
}

function stringFromAny(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  return value.length > 0 ? value : undefined;
}

export const __testing__ = {
  zaiFetch,
  tryEachHost,
  bucketsFromMonitorQuota,
  bucketsFromBalance,
  HOSTS,
};
