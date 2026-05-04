/**
 * @fileoverview OpenAI provider adapter.
 *
 * OpenAI exposes organization usage rather than a quota-limit endpoint. We
 * validate credentials against the stable /v1/models endpoint, then surface
 * recent organization usage as account-scoped quota buckets with unknown
 * limits. Admin API keys are required for the usage endpoint.
 */

import type {
  ProviderAdapter,
  CredentialTestResult,
  QuotaRefreshResult,
  QuotaBucket,
} from "../types.js";

const PROVIDER = "openai" as const;
const MODELS_URL = "https://api.openai.com/v1/models";
const USAGE_URL = "https://api.openai.com/v1/organization/usage/completions";

function redact(token: string): string {
  if (token.length <= 10) return "openai_***";
  return `openai_${token.slice(0, 3)}***${token.slice(-4)}`;
}

async function openAIFetch<T>(
  url: string,
  token: string
): Promise<{ ok: boolean; data?: T; status?: number; error?: string }> {
  try {
    const res = await fetch(url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "OpenAI-Beta": "usage=2025-01-01",
      },
    });
    if (!res.ok) {
      return { ok: false, status: res.status, error: `HTTP ${res.status}` };
    }
    return { ok: true, status: res.status, data: (await res.json()) as T };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
}

interface OpenAIUsageBucket {
  results?: Array<{
    input_tokens?: number;
    output_tokens?: number;
    input_cached_tokens?: number;
    num_model_requests?: number;
    model?: string;
    [k: string]: unknown;
  }>;
  [k: string]: unknown;
}

interface OpenAIUsagePayload {
  data?: OpenAIUsageBucket[];
  [k: string]: unknown;
}

function usageURL(days: number): string {
  const end = Math.floor(Date.now() / 1000);
  const start = end - days * 24 * 60 * 60;
  const params = new URLSearchParams({
    start_time: String(start),
    end_time: String(end),
    bucket_width: "1d",
    limit: String(Math.min(days, 31)),
  });
  params.append("group_by[]", "model");
  return `${USAGE_URL}?${params.toString()}`;
}

export const openaiAdapter: ProviderAdapter = {
  provider: PROVIDER,

  async testCredential(credential: string): Promise<CredentialTestResult> {
    if (!credential || credential.length < 16) {
      return {
        valid: false,
        redactedLabel: redact(credential || ""),
        credentialKind: "bearer",
        errorCode: "invalid_format",
        errorMessage: "OpenAI API key must be at least 16 characters.",
      };
    }

    const result = await openAIFetch<Record<string, unknown>>(MODELS_URL, credential);
    if (!result.ok) {
      return {
        valid: false,
        redactedLabel: redact(credential),
        credentialKind: "bearer",
        errorCode: "validation_failed",
        errorMessage:
          result.error || "OpenAI credential validation failed.",
      };
    }

    return {
      valid: true,
      redactedLabel: redact(credential),
      credentialKind: "bearer",
      warningMessage:
        "OpenAI usage refresh requires an organization admin API key. Regular API keys can connect but may not refresh usage.",
    };
  },

  async fetchQuota(
    credential: string,
    sourceId: string
  ): Promise<QuotaRefreshResult> {
    const result = await openAIFetch<OpenAIUsagePayload>(usageURL(30), credential);
    if (!result.ok) {
      return {
        ok: false,
        errorCode: result.status === 403 ? "admin_key_required" : "fetch_failed",
        errorMessage:
          result.status === 403
            ? "OpenAI usage refresh requires an organization admin API key."
            : result.error || "OpenAI usage request failed.",
      };
    }

    let inputTokens = 0;
    let outputTokens = 0;
    let cachedTokens = 0;
    let requests = 0;

    for (const bucket of result.data?.data ?? []) {
      for (const row of bucket.results ?? []) {
        inputTokens += row.input_tokens ?? 0;
        outputTokens += row.output_tokens ?? 0;
        cachedTokens += row.input_cached_tokens ?? 0;
        requests += row.num_model_requests ?? 0;
      }
    }

    const totalTokens = inputTokens + outputTokens;
    const buckets: QuotaBucket[] = [
      {
        name: "tokens",
        used: totalTokens,
        limit: -1,
        remaining: -1,
        window: "30d",
        meta: {
          inputTokens,
          outputTokens,
          cachedTokens,
        },
      },
      {
        name: "requests",
        used: requests,
        limit: -1,
        remaining: -1,
        window: "30d",
      },
    ];

    return {
      ok: true,
      snapshot: {
        sourceKind: "provider",
        sourceId,
        provider: PROVIDER,
        fetchedAt: new Date().toISOString(),
        source: "OpenAI Usage API",
        confidence: "high",
        statusMessage:
          "Fetched organization usage from OpenAI. OpenAI does not expose a quota limit through this endpoint.",
        buckets,
      },
    };
  },
};
