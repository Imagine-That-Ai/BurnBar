/**
 * @fileoverview Factory (factory.ai) provider adapter.
 *
 * Factory accepts both bearer API keys (created at
 * https://app.factory.ai/settings/api-keys) and longer-lived session tokens.
 *
 * The `api.tryforge.io` host this adapter previously targeted is gone (DNS
 * NXDOMAIN). Factory's current production stack lives at:
 *
 *   • api.factory.ai/api/app/auth/me                — validates the bearer
 *   • api.factory.ai/api/organization/subscription/usage?useCache=true
 *                                                  — usage / quota data
 *
 * (The same endpoints the macOS `FactoryQuotaAdapter` already uses.) Both
 * return JSON like `{"detail":"…","status":401}` for bad keys.
 */

import type {
  ProviderAdapter,
  CredentialTestResult,
  QuotaRefreshResult,
  QuotaBucket,
} from "../types.js";

const PROVIDER = "factory" as const;

const API_HOST = "https://api.factory.ai";
const VALIDATE_PATH = "/api/app/auth/me";
const USAGE_PATH = "/api/organization/subscription/usage?useCache=true";

function redact(token: string): string {
  if (token.length <= 8) return "factory_***";
  return `factory_${token.slice(0, 2)}***${token.slice(-4)}`;
}

/** Heuristic: long opaque hex strings look like session tokens, not API keys. */
function inferKind(token: string): "bearer" | "session" {
  return /^[a-f0-9]{32,}$/i.test(token) ? "session" : "bearer";
}

interface FactoryFetchResult<T> {
  ok: boolean;
  status?: number;
  data?: T;
  error?: string;
  errorCode?: string;
}

async function factoryFetch<T = unknown>(
  url: string,
  token: string
): Promise<FactoryFetchResult<T>> {
  let response: Response;
  try {
    response = await fetch(url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "Content-Type": "application/json",
        Origin: "https://app.factory.ai",
        Referer: "https://app.factory.ai/",
        "x-factory-client": "openburnbar",
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
    const detail =
      payload && typeof payload === "object"
        ? stringFrom((payload as Record<string, unknown>).detail ?? (payload as Record<string, unknown>).message)
        : undefined;
    return {
      ok: false,
      status: response.status,
      data: payload as T,
      error: detail ?? `HTTP ${response.status}`,
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

interface FactoryAuthMePayload {
  user?: { email?: string; name?: string };
  organization?: {
    name?: string;
    subscription?: {
      factoryTier?: string;
      orbSubscription?: { plan?: { name?: string } };
    };
  };
  [k: string]: unknown;
}

interface FactoryUsageLane {
  userTokens?: number;
  totalAllowance?: number;
  usedRatio?: number;
}

interface FactoryUsagePayload {
  usage?: {
    endDate?: string;
    standard?: FactoryUsageLane;
    premium?: FactoryUsageLane;
  };
  [k: string]: unknown;
}

export const factoryAdapter: ProviderAdapter = {
  provider: PROVIDER,

  async testCredential(credential: string): Promise<CredentialTestResult> {
    const trimmed = (credential ?? "").trim();
    if (trimmed.length < 8) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: "invalid_format",
        errorMessage: "Factory credential must be at least 8 characters.",
      };
    }

    const kind = inferKind(trimmed);
    const result = await factoryFetch<FactoryAuthMePayload>(
      `${API_HOST}${VALIDATE_PATH}`,
      trimmed
    );
    if (!result.ok) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: kind,
        errorCode: result.errorCode ?? "validation_failed",
        errorMessage: result.error || "Factory validation request failed.",
      };
    }

    return {
      valid: true,
      redactedLabel: redact(trimmed),
      credentialKind: kind,
      warningMessage:
        kind === "session"
          ? "Session credentials expire and may stop working without warning. Use an API key from app.factory.ai/settings/api-keys for the most stable refresh."
          : undefined,
    };
  },

  async fetchQuota(
    credential: string,
    sourceId: string
  ): Promise<QuotaRefreshResult> {
    const trimmed = (credential ?? "").trim();
    const result = await factoryFetch<FactoryUsagePayload>(
      `${API_HOST}${USAGE_PATH}`,
      trimmed
    );
    if (!result.ok) {
      return {
        ok: false,
        errorCode: result.errorCode ?? "fetch_failed",
        errorMessage: result.error || "Factory usage request failed.",
      };
    }

    const usage = result.data?.usage ?? {};
    const buckets: QuotaBucket[] = [];
    const standard = bucketFromLane("Standard tokens", usage.standard, usage.endDate);
    if (standard) buckets.push(standard);
    const premium = bucketFromLane("Premium tokens", usage.premium, usage.endDate);
    if (premium) buckets.push(premium);

    return {
      ok: true,
      snapshot: {
        sourceKind: "provider",
        sourceId,
        provider: PROVIDER,
        fetchedAt: new Date().toISOString(),
        source: "Factory subscription usage",
        confidence: buckets.length ? "high" : "low",
        statusMessage: buckets.length
          ? "Fetched from Factory subscription usage endpoint."
          : "Factory responded but exposed no recognizable token lanes.",
        buckets,
      },
    };
  },
};

function bucketFromLane(
  name: string,
  lane: FactoryUsageLane | undefined,
  windowEnd: string | undefined
): QuotaBucket | undefined {
  if (!lane) return undefined;
  const used = numberFrom(lane.userTokens) ?? 0;
  const limit = numberFrom(lane.totalAllowance) ?? -1;
  const ratio = numberFrom(lane.usedRatio);
  // Skip lanes with no usage, no allowance, and no ratio. A 0/0/0 lane just
  // means the user isn't subscribed to that tier; emitting a bucket would
  // make the dashboard look broken.
  if (used <= 0 && limit <= 0 && (ratio ?? 0) <= 0) return undefined;

  return {
    name,
    used,
    limit,
    remaining: limit >= 0 ? Math.max(0, limit - used) : -1,
    window: "monthly",
    meta: stripUndefined({
      usedRatio: ratio,
      windowEnd,
    }),
  };
}

function numberFrom(raw: unknown): number | undefined {
  if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  if (typeof raw === "string") {
    const value = Number(raw.trim());
    if (Number.isFinite(value)) return value;
  }
  return undefined;
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
  factoryFetch,
  bucketFromLane,
  API_HOST,
};
