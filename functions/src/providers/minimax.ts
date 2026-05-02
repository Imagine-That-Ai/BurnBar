/**
 * @fileoverview MiniMax provider adapter.
 *
 * MiniMax uses a "token-plan" style credential.  We treat the credential as
 * an API token and hit the user info / balance endpoint to validate and
 * refresh quota.  If MiniMax changes their endpoint shape, only this file
 * needs updating.
 */

import type {
  ProviderAdapter,
  CredentialTestResult,
  QuotaRefreshResult,
  QuotaBucket,
} from "../types.js";

const PROVIDER = "minimax" as const;
const VALIDATE_URL = "https://api.minimax.chat/v1/user/info";
const BALANCE_URL = "https://api.minimax.chat/v1/user/balance";

/** Extract a redacted label from a long token. */
function redact(token: string): string {
  if (token.length <= 8) return "minimax_***";
  return `minimax_${token.slice(0, 2)}***${token.slice(-4)}`;
}

async function minimaxFetch<T>(
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

interface MiniMaxBalancePayload {
  balance?: number;
  total_balance?: number;
  currency?: string;
  // Free-form because MiniMax docs vary by region/plan.
  [k: string]: unknown;
}

export const minimaxAdapter: ProviderAdapter = {
  provider: PROVIDER,

  async testCredential(credential: string): Promise<CredentialTestResult> {
    if (!credential || credential.length < 8) {
      return {
        valid: false,
        redactedLabel: redact(credential || ""),
        credentialKind: "token",
        errorCode: "invalid_format",
        errorMessage: "MiniMax token must be at least 8 characters.",
      };
    }

    const result = await minimaxFetch<Record<string, unknown>>(
      VALIDATE_URL,
      credential
    );
    if (!result.ok) {
      return {
        valid: false,
        redactedLabel: redact(credential),
        credentialKind: "token",
        errorCode: "validation_failed",
        errorMessage: result.error || "MiniMax validation request failed.",
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
    const result = await minimaxFetch<MiniMaxBalancePayload>(
      BALANCE_URL,
      credential
    );
    if (!result.ok) {
      return {
        ok: false,
        errorCode: "fetch_failed",
        errorMessage: result.error || "MiniMax balance request failed.",
      };
    }

    const data = result.data!;
    const balance = typeof data.balance === "number" ? data.balance : undefined;
    const total =
      typeof data.total_balance === "number" ? data.total_balance : undefined;

    const buckets: QuotaBucket[] = [];
    if (balance !== undefined) {
      buckets.push({
        name: "balance",
        used: 0, // MiniMax does not expose a per-window used count directly.
        limit: total ?? balance,
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
        source: "MiniMax API",
        confidence: buckets.length ? "medium" : "low",
        statusMessage: "Fetched from MiniMax balance endpoint.",
        buckets,
      },
    };
  },
};
