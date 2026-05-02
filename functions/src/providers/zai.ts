/**
 * @fileoverview Z.ai (Zhipu / Z.ai) provider adapter.
 *
 * Z.ai uses a standard API token.  We validate by calling the user/info
 * endpoint and refresh quota by calling the balance/quota endpoint.
 */

import type {
  ProviderAdapter,
  CredentialTestResult,
  QuotaRefreshResult,
  QuotaBucket,
} from "../types.js";

const PROVIDER = "zai" as const;
const VALIDATE_URL = "https://open.bigmodel.cn/api/paas/v4/user/info";
const BALANCE_URL = "https://open.bigmodel.cn/api/paas/v4/user/balance";

function redact(token: string): string {
  if (token.length <= 8) return "zai_***";
  return `zai_${token.slice(0, 2)}***${token.slice(-4)}`;
}

async function zaiFetch<T>(
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

interface ZaiBalancePayload {
  balance?: number;
  total?: number;
  used?: number;
  currency?: string;
  [k: string]: unknown;
}

export const zaiAdapter: ProviderAdapter = {
  provider: PROVIDER,

  async testCredential(credential: string): Promise<CredentialTestResult> {
    if (!credential || credential.length < 8) {
      return {
        valid: false,
        redactedLabel: redact(credential || ""),
        credentialKind: "token",
        errorCode: "invalid_format",
        errorMessage: "Z.ai token must be at least 8 characters.",
      };
    }

    const result = await zaiFetch<Record<string, unknown>>(
      VALIDATE_URL,
      credential
    );
    if (!result.ok) {
      return {
        valid: false,
        redactedLabel: redact(credential),
        credentialKind: "token",
        errorCode: "validation_failed",
        errorMessage: result.error || "Z.ai validation request failed.",
      };
    }

    return {
      valid: true,
      redactedLabel: redact(credential),
      credentialKind: "token",
    };
  },

  async fetchQuota(
    credential: string,
    sourceId: string
  ): Promise<QuotaRefreshResult> {
    const result = await zaiFetch<ZaiBalancePayload>(BALANCE_URL, credential);
    if (!result.ok) {
      return {
        ok: false,
        errorCode: "fetch_failed",
        errorMessage: result.error || "Z.ai balance request failed.",
      };
    }

    const data = result.data!;
    const buckets: QuotaBucket[] = [];

    const total = typeof data.total === "number" ? data.total : undefined;
    const used = typeof data.used === "number" ? data.used : 0;
    const balance = typeof data.balance === "number" ? data.balance : undefined;

    if (total !== undefined) {
      buckets.push({
        name: "tokens",
        used,
        limit: total,
        remaining: Math.max(0, total - used),
        window: "account",
        meta: { currency: data.currency ?? "CNY" },
      });
    } else if (balance !== undefined) {
      buckets.push({
        name: "balance",
        used: 0,
        limit: -1,
        remaining: balance,
        window: "account",
        meta: { currency: data.currency ?? "CNY" },
      });
    }

    return {
      ok: true,
      snapshot: {
        sourceKind: "provider",
        sourceId,
        provider: PROVIDER,
        fetchedAt: new Date().toISOString(),
        source: "Z.ai API",
        confidence: buckets.length ? "high" : "low",
        statusMessage: "Fetched from Z.ai balance endpoint.",
        buckets,
      },
    };
  },
};
