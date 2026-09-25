/**
 * @fileoverview xAI / Grok provider adapter.
 *
 * Reports remaining usage for the xAI developer tier (GrokBuild / pay-as-you-go
 * prepaid credits) by hitting two Management-API endpoints:
 *
 *   GET  https://api.x.ai/v1/teams                              → resolve team id
 *   GET  https://api.x.ai/v1/billing/teams/{team_id}/prepaid/balance
 *   POST https://api.x.ai/v1/billing/teams/{team_id}/usage      (last-30-day rollup)
 *
 * Auth uses the **Management Key** the user pastes in the OpenBurnBar settings
 * — separate from the inference key used by the proxy to actually serve
 * requests. The Management Key has the `xai-mgmt-…` prefix.
 *
 * Sign convention quirk: xAI returns `total.val` as a string of USD cents.
 * Per the public docs, a PURCHASE makes the change `amount` negative and a
 * SPEND makes it positive — so when there is *unspent* credit, `total.val`
 * comes back as a negative number. We invert it to express USD remaining.
 *
 * SuperGrok consumer-tier quotas (`xai-…` inference keys belonging to
 * SuperGrok Lite / SuperGrok / SuperGrok Heavy logins) have no published
 * remaining-quota endpoint. The macOS adapter handles those via local pacing
 * heuristics; this server-side adapter only reports the developer (GrokBuild)
 * tier authoritatively.
 *
 * Reference: docs.x.ai/docs/management-api/billing (verified 2026-05-21).
 */

import type { ProviderAdapter, CredentialTestResult, QuotaRefreshResult, QuotaBucket } from "../types.js";
import { recordOrUndefined } from "../guards.js";
import { providerFetch } from "./httpClient.js";

const PROVIDER = "xai" as const;

const MANAGEMENT_BASE_URL = "https://api.x.ai";
const TEAMS_URL = `${MANAGEMENT_BASE_URL}/v1/teams`;

function redact(token: string): string {
  const trimmed = (token ?? "").trim();
  if (trimmed.length <= 8) return "xai_***";
  return `xai_${trimmed.slice(0, 6)}***${trimmed.slice(-4)}`;
}

interface XAIFetchResult {
  ok: boolean;
  status?: number;
  data?: unknown;
  error?: string;
  errorCode?: string;
}

async function xaiGet(url: string, token: string): Promise<XAIFetchResult> {
  let response: Response;
  try {
    response = await providerFetch(PROVIDER, "api_get", url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
      },
    });
  } catch (err) {
    return { ok: false, error: String(err), errorCode: "network_error" };
  }
  return parseResponse(response);
}

async function xaiPost(url: string, token: string, body: unknown): Promise<XAIFetchResult> {
  let response: Response;
  try {
    response = await providerFetch(PROVIDER, "api_post", url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
  } catch (err) {
    return { ok: false, error: String(err), errorCode: "network_error" };
  }
  return parseResponse(response);
}

async function parseResponse(response: Response): Promise<XAIFetchResult> {
  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    payload = undefined;
  }

  if (!response.ok) {
    const err = recordOrUndefined(payload);
    const nested = recordOrUndefined(err?.error);
    const message =
      (typeof nested?.message === "string" ? nested.message : undefined) ??
      (typeof err?.message === "string" ? err.message : undefined) ??
      `HTTP ${response.status}`;
    return {
      ok: false,
      status: response.status,
      error: message,
      errorCode:
        response.status === 401 || response.status === 403
          ? "auth_failed"
          : response.status === 404
            ? "endpoint_not_found"
            : "fetch_failed",
    };
  }

  return { ok: true, status: response.status, data: payload };
}

async function resolveTeamID(token: string): Promise<XAIFetchResult & { data?: string }> {
  const result = await xaiGet(TEAMS_URL, token);
  if (!result.ok) {
    return { ok: false, status: result.status, error: result.error, errorCode: result.errorCode };
  }
  const payload = recordOrUndefined(result.data);
  const teams = Array.isArray(payload?.teams) ? payload.teams : [];
  const firstTeam = recordOrUndefined(teams[0]);
  const id = typeof firstTeam?.id === "string" ? firstTeam.id.trim() : "";
  if (!id) {
    return {
      ok: false,
      status: result.status,
      error: "xAI Management Key authenticated but no team is associated.",
      errorCode: "no_team",
    };
  }
  return { ok: true, status: result.status, data: id };
}

export const xaiAdapter: ProviderAdapter = {
  provider: PROVIDER,

  async testCredential(credential: string): Promise<CredentialTestResult> {
    const trimmed = (credential ?? "").trim();
    if (trimmed.length < 8) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: "invalid_format",
        errorMessage: "xAI management key must be at least 8 characters.",
      };
    }

    const teamResult = await resolveTeamID(trimmed);
    if (!teamResult.ok) {
      return {
        valid: false,
        redactedLabel: redact(trimmed),
        credentialKind: "bearer",
        errorCode: teamResult.errorCode ?? "validation_failed",
        errorMessage: teamResult.error || "xAI Management API rejected the key.",
      };
    }

    return {
      valid: true,
      redactedLabel: redact(trimmed),
      credentialKind: "bearer",
    };
  },

  async fetchQuota(credential: string, sourceId: string): Promise<QuotaRefreshResult> {
    const trimmed = (credential ?? "").trim();
    const teamResult = await resolveTeamID(trimmed);
    if (!teamResult.ok) {
      return {
        ok: false,
        errorCode: teamResult.errorCode ?? "fetch_failed",
        errorMessage: teamResult.error || "xAI Management API rejected the key.",
      };
    }

    const teamID = teamResult.data;
    if (!teamID) {
      return {
        ok: false,
        errorCode: "no_team",
        errorMessage: "xAI Management Key authenticated but no team is associated.",
      };
    }
    const [balance, usage] = await Promise.all([
      xaiGet(`${MANAGEMENT_BASE_URL}/v1/billing/teams/${encodeURIComponent(teamID)}/prepaid/balance`, trimmed),
      xaiPost(`${MANAGEMENT_BASE_URL}/v1/billing/teams/${encodeURIComponent(teamID)}/usage`, trimmed, buildUsageBody()),
    ]);

    const buckets: QuotaBucket[] = [];
    if (balance.ok) buckets.push(...extractBalanceBuckets(recordOrUndefined(balance.data)));
    if (usage.ok) buckets.push(...extractUsageBuckets(recordOrUndefined(usage.data)));

    if (buckets.length === 0) {
      return {
        ok: false,
        errorCode: balance.errorCode ?? usage.errorCode ?? "no_data",
        errorMessage: balance.error || usage.error || "xAI Management API returned no credit balance or usage data.",
      };
    }

    return {
      ok: true,
      snapshot: {
        sourceKind: "provider",
        sourceId,
        provider: PROVIDER,
        fetchedAt: new Date().toISOString(),
        source: "xAI Management API",
        confidence: "high",
        statusMessage: "Fetched prepaid credit balance and rolling usage from the xAI Management API.",
        buckets,
      },
    };
  },
};

/** Build the body of `POST /v1/billing/teams/{team}/usage` for 30-day rollup. */
function buildUsageBody(): unknown {
  const now = new Date();
  const start = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
  return {
    analyticsRequest: {
      timeRange: {
        startTime: start.toISOString(),
        endTime: now.toISOString(),
        timezone: "UTC",
      },
      timeUnit: "TIME_UNIT_DAY",
      values: [{ name: "usd", aggregation: "AGGREGATION_SUM" }],
    },
  };
}

function extractBalanceBuckets(payload: Record<string, unknown> | undefined): QuotaBucket[] {
  const total = recordOrUndefined(payload?.total);
  const raw = total?.val;
  if (raw === undefined || raw === null) return [];
  const cents = Number(String(raw).trim());
  if (!Number.isFinite(cents)) return [];
  const remainingDollars = Math.max(0, -cents / 100);
  return [
    {
      name: "Prepaid credit balance",
      used: 0,
      limit: -1,
      remaining: remainingDollars,
      window: "lifetime",
      meta: { unit: "usd", source: "prepaid/balance" },
    },
  ];
}

function extractUsageBuckets(payload: Record<string, unknown> | undefined): QuotaBucket[] {
  const timeSeries = Array.isArray(payload?.timeSeries) ? payload.timeSeries : [];
  const points = timeSeries.flatMap((series) => {
    const row = recordOrUndefined(series);
    return Array.isArray(row?.dataPoints) ? row.dataPoints : [];
  });
  if (points.length === 0) return [];

  const now = Date.now();
  const cutoff24h = now - 24 * 60 * 60 * 1000;
  const cutoff7d = now - 7 * 24 * 60 * 60 * 1000;
  let total24h = 0;
  let total7d = 0;
  let total30d = 0;

  for (const point of points) {
    const row = recordOrUndefined(point);
    const ts = typeof row?.timestamp === "string" ? Date.parse(row.timestamp) : NaN;
    if (!Number.isFinite(ts)) continue;
    const values = Array.isArray(row?.values) ? row.values : [];
    let usd = 0;
    for (const value of values) {
      const entry = recordOrUndefined(value);
      if (entry?.name === "usd" && typeof entry.value === "number") {
        usd = entry.value;
        break;
      }
    }
    total30d += usd;
    if (ts >= cutoff7d) total7d += usd;
    if (ts >= cutoff24h) total24h += usd;
  }

  return [
    {
      name: "Spend (last 24h)",
      used: total24h,
      limit: -1,
      remaining: -1,
      window: "rolling_24h",
      meta: { unit: "usd" },
    },
    {
      name: "Spend (last 7 days)",
      used: total7d,
      limit: -1,
      remaining: -1,
      window: "rolling_7d",
      meta: { unit: "usd" },
    },
    {
      name: "Spend (last 30 days)",
      used: total30d,
      limit: -1,
      remaining: -1,
      window: "rolling_30d",
      meta: { unit: "usd" },
    },
  ];
}

export const __testing__ = {
  resolveTeamID,
  extractBalanceBuckets,
  extractUsageBuckets,
  MANAGEMENT_BASE_URL,
  TEAMS_URL,
};
