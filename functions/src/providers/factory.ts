/**
 * @fileoverview Factory (tryforge.io) provider adapter.
 *
 * Factory accepts either bearer tokens or session credentials.  Session
 * credentials are treated as higher risk: we warn the user and apply a
 * shorter implicit TTL.  Validation hits the /v1/me endpoint.
 */

import type {
  ProviderAdapter,
  CredentialTestResult,
  QuotaRefreshResult,
  QuotaBucket,
} from "../types.js";

const PROVIDER = "factory" as const;
const VALIDATE_URL = "https://api.tryforge.io/v1/me";
const QUOTA_URL = "https://api.tryforge.io/v1/usage/quota";

function redact(token: string): string {
  if (token.length <= 8) return "factory_***";
  return `factory_${token.slice(0, 2)}***${token.slice(-4)}`;
}

/** Heuristic to distinguish bearer vs session tokens. */
function inferKind(token: string): "bearer" | "session" {
  // Session tokens from Factory are often longer opaque strings (UUID-ish).
  // This heuristic is conservative; adjust as Factory evolves.
  const sessionPattern = /^[a-f0-9]{32,}$/i;
  return sessionPattern.test(token) ? "session" : "bearer";
}

async function factoryFetch<T>(
  url: string,
  token: string
): Promise<{ ok: boolean; data?: T; error?: string }> {
  try {
    const res = await fetch(url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
      },
    });
    if (!res.ok) {
      return { ok: false, error: `HTTP ${res.status}` };
    }
    return { ok: true, data: (await res.json()) as T };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
}

interface FactoryQuotaPayload {
  quota?: {
    used?: number;
    limit?: number;
    reset_at?: string;
  };
  tier?: string;
  [k: string]: unknown;
}

export const factoryAdapter: ProviderAdapter = {
  provider: PROVIDER,

  async testCredential(credential: string): Promise<CredentialTestResult> {
    if (!credential || credential.length < 8) {
      return {
        valid: false,
        redactedLabel: redact(credential || ""),
        credentialKind: "bearer",
        errorCode: "invalid_format",
        errorMessage: "Factory credential must be at least 8 characters.",
      };
    }

    const kind = inferKind(credential);
    const result = await factoryFetch<Record<string, unknown>>(
      VALIDATE_URL,
      credential
    );
    if (!result.ok) {
      return {
        valid: false,
        redactedLabel: redact(credential),
        credentialKind: kind,
        errorCode: "validation_failed",
        errorMessage: result.error || "Factory validation request failed.",
      };
    }

    const warningMessage =
      kind === "session"
        ? "Session credentials expire and may stop working without warning. Consider using a long-lived API key if available."
        : undefined;

    return {
      valid: true,
      redactedLabel: redact(credential),
      credentialKind: kind,
      warningMessage,
    };
  },

  async fetchQuota(
    credential: string,
    sourceId: string
  ): Promise<QuotaRefreshResult> {
    const result = await factoryFetch<FactoryQuotaPayload>(QUOTA_URL, credential);
    if (!result.ok) {
      return {
        ok: false,
        errorCode: "fetch_failed",
        errorMessage: result.error || "Factory quota request failed.",
      };
    }

    const data = result.data!;
    const q = data.quota || {};
    const used = typeof q.used === "number" ? q.used : 0;
    const limit = typeof q.limit === "number" ? q.limit : -1;

    const buckets: QuotaBucket[] = [];
    buckets.push({
      name: "requests",
      used,
      limit,
      remaining: limit >= 0 ? Math.max(0, limit - used) : -1,
      window: "monthly",
      meta: { tier: data.tier, reset_at: q.reset_at },
    });

    return {
      ok: true,
      snapshot: {
        sourceKind: "provider",
        sourceId,
        provider: PROVIDER,
        fetchedAt: new Date().toISOString(),
        source: "Factory API",
        confidence: "high",
        statusMessage: "Fetched from Factory quota endpoint.",
        buckets,
      },
    };
  },
};
