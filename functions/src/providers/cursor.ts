/**
 * @fileoverview Cursor provider adapter.
 *
 * Cursor does not expose a public API for quota.  This adapter treats the
 * credential as a cookie/session string and attempts to introspect the
 * Cursor dashboard (best-effort).  Because session cookies are fragile,
 * we flag the connection as "advanced" with an explicit warning and a
 * shorter effective TTL.
 *
 * Backend refresh is attempted but may degrade to "low" confidence or
 * fail entirely if Cursor changes their internal endpoints.
 */

import type {
  ProviderAdapter,
  CredentialTestResult,
  QuotaRefreshResult,
  QuotaBucket,
} from "../types.js";

const PROVIDER = "cursor" as const;
const DASHBOARD_URL = "https://www.cursor.com/api/dashboard";

function redact(token: string): string {
  if (token.length <= 12) return "cursor_***";
  return `cursor_${token.slice(0, 3)}***${token.slice(-4)}`;
}

async function cursorFetch<T>(
  url: string,
  cookie: string
): Promise<{ ok: boolean; data?: T; error?: string }> {
  try {
    const res = await fetch(url, {
      method: "GET",
      headers: {
        Cookie: cookie,
        Accept: "application/json",
        // Cursor may block non-browser UAs; pretend minimally.
        "User-Agent": "OpenBurnBar/1.0",
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

interface CursorDashPayload {
  usage?: {
    used?: number;
    limit?: number;
    window?: string;
  };
  subscription?: {
    tier?: string;
    status?: string;
  };
  [k: string]: unknown;
}

export const cursorAdapter: ProviderAdapter = {
  provider: PROVIDER,

  async testCredential(credential: string): Promise<CredentialTestResult> {
    if (!credential || credential.length < 16) {
      return {
        valid: false,
        redactedLabel: redact(credential || ""),
        credentialKind: "cookie",
        errorCode: "invalid_format",
        errorMessage: "Cursor cookie must be at least 16 characters.",
      };
    }

    const result = await cursorFetch<CursorDashPayload>(DASHBOARD_URL, credential);
    if (!result.ok) {
      return {
        valid: false,
        redactedLabel: redact(credential),
        credentialKind: "cookie",
        errorCode: "validation_failed",
        errorMessage:
          result.error || "Cursor dashboard request failed (session may be expired).",
      };
    }

    return {
      valid: true,
      redactedLabel: redact(credential),
      credentialKind: "cookie",
      warningMessage:
        "Cursor connections use session cookies that expire quickly and may break when Cursor updates their site. Quota confidence is lower than API-based providers.",
    };
  },

  async fetchQuota(
    credential: string,
    sourceId: string
  ): Promise<QuotaRefreshResult> {
    const result = await cursorFetch<CursorDashPayload>(DASHBOARD_URL, credential);
    if (!result.ok) {
      return {
        ok: false,
        errorCode: "fetch_failed",
        errorMessage:
          result.error || "Cursor dashboard request failed (session may be expired).",
      };
    }

    const data = result.data!;
    const usage = data.usage || {};
    const used = typeof usage.used === "number" ? usage.used : 0;
    const limit = typeof usage.limit === "number" ? usage.limit : -1;

    const buckets: QuotaBucket[] = [];
    buckets.push({
      name: "requests",
      used,
      limit,
      remaining: limit >= 0 ? Math.max(0, limit - used) : -1,
      window: usage.window || "monthly",
      meta: { tier: data.subscription?.tier, status: data.subscription?.status },
    });

    return {
      ok: true,
      snapshot: {
        sourceKind: "provider",
        sourceId,
        provider: PROVIDER,
        fetchedAt: new Date().toISOString(),
        source: "Cursor Dashboard",
        confidence: "low",
        statusMessage: "Best-effort quota from Cursor dashboard (session cookie).",
        buckets,
      },
    };
  },
};
