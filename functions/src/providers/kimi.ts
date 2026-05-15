/**
 * @fileoverview Kimi (Moonshot AI) provider adapter.
 *
 * Kimi/Moonshot serves the same OpenAI-compatible API surface from two
 * regional hosts:
 *
 *   • https://api.kimi.ai      (international)
 *   • https://api.moonshot.cn  (mainland China)
 *
 * Both expose:
 *   • GET /v1/models — credential validation + model list
 *
 * Kimi does not expose a public balance or quota-limit endpoint. We follow
 * the OpenAI adapter pattern: validate credentials against /v1/models, then
 * surface a "connected" signal with a placeholder usage bucket (unknown
 * limits) so the dashboard renders a tile rather than a blank state.
 *
 * If Kimi adds a balance or usage endpoint in the future, fetchQuota can be
 * extended to populate real usage numbers.
 */

import type {
  ProviderAdapter,
  CredentialTestResult,
  QuotaRefreshResult,
  QuotaBucket,
} from "../types.js";

const PROVIDER = "kimi" as const;

const HOSTS = [
  "https://api.kimi.ai",
  "https://api.moonshot.cn",
] as const;

const VALIDATE_PATH = "/v1/models";

function redact(token: string): string {
  if (token.length <= 8) return "kimi_***";
  return `kimi_${token.slice(0, 2)}***${token.slice(-4)}`;
}

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

interface KimiFetchResult<T> {
  ok: boolean;
  status?: number;
  data?: T;
  error?: string;
  errorCode?: string;
}

async function kimiFetch<T = unknown>(
  url: string,
  token: string
): Promise<KimiFetchResult<T>> {
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

  return { ok: true, status: response.status, data: payload as T };
}

function inlineErrorMessage(payload: unknown): string | undefined {
  if (!payload || typeof payload !== "object") return undefined;
  const obj = payload as Record<string, unknown>;

  // OpenAI-compatible error shape: { error: { message, code, type } }
  const error = obj.error as Record<string, unknown> | undefined;
  if (error && typeof error === "object") {
    const message = stringFromAny(error.message ?? error.msg);
    if (message) return message;
  }

  // Alternate shape: { message: "..." } or { msg: "..." }
  const direct = stringFromAny(obj.message ?? obj.msg);
  if (direct) return direct;

  return undefined;
}

// ---------------------------------------------------------------------------
// Multi-host fallback (mirrors zai adapter pattern)
// ---------------------------------------------------------------------------

async function tryEachHost<T>(
  path: string,
  token: string
): Promise<KimiFetchResult<T>> {
  let lastFailure: KimiFetchResult<T> | undefined;
  for (const host of HOSTS) {
    const url = `${host}${path}`;
    const result = await kimiFetch<T>(url, token);
    if (result.ok) return result;
    lastFailure = result;
    // Auth failures mean the key is bad — no point trying another host.
    if (result.errorCode === "auth_failed") return result;
  }
  return lastFailure ?? {
    ok: false,
    error: "Kimi request failed against all candidate hosts.",
    errorCode: "fetch_failed",
  };
}

// ---------------------------------------------------------------------------
// Adapter
// ---------------------------------------------------------------------------

interface KimiModelsPayload {
  data?: Array<{
    id?: string;
    object?: string;
    [k: string]: unknown;
  }>;
  [k: string]: unknown;
}

export const kimiAdapter: ProviderAdapter = {
  provider: PROVIDER,

  async testCredential(credential: string): Promise<CredentialTestResult> {
    const trimmed = (credential ?? "").trim();
    if (trimmed.length < 8) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: "invalid_format",
        errorMessage: "Kimi API key must be at least 8 characters.",
      };
    }

    const result = await tryEachHost<KimiModelsPayload>(VALIDATE_PATH, trimmed);
    if (!result.ok) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: result.errorCode ?? "validation_failed",
        errorMessage: result.error || "Kimi credential validation failed.",
      };
    }

    // Extract model count for the warning message.
    const modelCount = result.data?.data?.length ?? 0;

    return {
      valid: true,
      redactedLabel: redact(trimmed),
      credentialKind: "bearer",
      warningMessage:
        modelCount > 0
          ? `Kimi key verified (${modelCount} model${modelCount !== 1 ? "s" : ""} accessible). Kimi does not expose a public quota endpoint; usage limits are unavailable.`
          : "Kimi key verified. Kimi does not expose a public quota endpoint; usage limits are unavailable.",
    };
  },

  async fetchQuota(
    credential: string,
    sourceId: string
  ): Promise<QuotaRefreshResult> {
    const trimmed = (credential ?? "").trim();

    // Validate the credential via /v1/models first.
    const result = await tryEachHost<KimiModelsPayload>(VALIDATE_PATH, trimmed);
    if (!result.ok) {
      return {
        ok: false,
        errorCode: result.errorCode ?? "fetch_failed",
        errorMessage: result.error || "Kimi quota request failed.",
      };
    }

    const modelCount = result.data?.data?.length ?? 0;
    const buckets: QuotaBucket[] = [];

    // Attempt the /v1/users/me/balance endpoint. Moonshot exposes account
    // balance on some plan tiers. If it works, we get real usage/limit data.
    // If it fails (404 or auth error), we gracefully fall back to a
    // usage-only signal.
    // Use the host that successfully validated the credential for the
    // balance probe. We can't tell which host succeeded from tryEachHost's
    // return value alone, so try both in order — the balance endpoint
    // must be on the same host that accepted the key.
    let confidence: "high" | "medium" | "low" = "low";
    let source = "Kimi /v1/models";
    let statusMessage =
      "Kimi credential validated; balance endpoint unavailable — usage limits are unknown.";

    const balanceResult = await tryEachHost<KimiBalancePayload>(
      "/v1/users/me/balance",
      trimmed
    );

    if (balanceResult.ok && balanceResult.data) {
      const balance = balanceResult.data;
      const available = finiteNumber(balance.available_balance ?? balance.availableBalance ?? balance.balance);
      const used = finiteNumber(balance.used_balance ?? balance.usedBalance ?? balance.used);
      const total = finiteNumber(balance.total_balance ?? balance.totalBalance ?? balance.total);

      if (available != null && total != null && total > 0) {
        const usedAmount = used != null ? used : Math.max(0, total - available);
        buckets.push({
          name: "account_balance",
          used: usedAmount,
          limit: total,
          remaining: available,
          window: "monthly",
          meta: { currency: balance.currency ?? "CNY" },
        });
        confidence = "high";
        source = "Kimi balance API";
        statusMessage = "Fetched account balance from Kimi.";
      } else if (available != null && available > 0) {
        buckets.push({
          name: "remaining_balance",
          used: 0,
          limit: available,
          remaining: available,
          window: "monthly",
          meta: { currency: balance.currency ?? "CNY" },
        });
        confidence = "medium";
        source = "Kimi balance API";
        statusMessage = "Fetched remaining balance from Kimi; total limit unavailable.";
      }
    }

    // Always include a models-accessible bucket. Use a positive synthetic
    // limit so the iOS `isDisplayableQuotaSignal` filter (which rejects
    // limit <= 0) doesn't strip this bucket.
    if (modelCount > 0) {
      buckets.push({
        name: "models",
        used: 0,
        limit: modelCount,
        remaining: modelCount,
        window: "static",
        meta: { unit: "models", modelsAccessible: modelCount },
      });
      if (confidence === "low") {
        confidence = "medium";
        statusMessage = "Kimi key verified; balance endpoint did not return usable quota data.";
      }
    }

    if (buckets.length === 0) {
      // Last resort: a minimal connected-signal bucket so the dashboard
      // doesn't show a blank tile. Use limit=1 so it passes the iOS filter.
      buckets.push({
        name: "connected",
        used: 0,
        limit: 1,
        remaining: 1,
        window: "account",
      });
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
        statusMessage,
        buckets,
      },
    };
  },
};

// ---------------------------------------------------------------------------
// Balance payload
// ---------------------------------------------------------------------------

interface KimiBalancePayload {
  available_balance?: number;
  availableBalance?: number;
  balance?: number;
  used_balance?: number;
  usedBalance?: number;
  used?: number;
  total_balance?: number;
  totalBalance?: number;
  total?: number;
  currency?: string;
  data?: KimiBalancePayload;
  [k: string]: unknown;
}

function finiteNumber(raw: unknown): number | undefined {
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : undefined;
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

function stringFromAny(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  return value.length > 0 ? value : undefined;
}

export const __testing__ = {
  kimiFetch,
  tryEachHost,
  HOSTS,
  VALIDATE_PATH,
};
