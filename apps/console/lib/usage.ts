/**
 * Live usage types + normalizers for the dashboard.
 *
 * These mirror the server's Firestore shapes 1:1 — keep the field names
 * identical to `functions/src/types/legacy/quota-usage.ts` so a server rename
 * surfaces here as a type error rather than a silent zero:
 *   - users/{uid}/usage_rollups/{window}   → UsageRollupDoc  (owner-readable)
 *   - users/{uid}/quota_snapshots/{id}      → QuotaSnapshotDoc (owner-readable)
 *   - users/{uid}/billing/allowances/months/{monthKey} → allowance meters
 *
 * Firestore returns untyped JSON (numbers may be missing, timestamps may be
 * Firestore Timestamp objects), so everything is funneled through defensive
 * coercion. A malformed or partial doc degrades to zeros, never throws.
 */

export type UsageWindowKey = "today" | "7d" | "30d" | "90d" | "all_time";

export const USAGE_WINDOWS: UsageWindowKey[] = ["today", "7d", "30d", "90d", "all_time"];

export const USAGE_WINDOW_LABEL: Record<UsageWindowKey, string> = {
  today: "Today",
  "7d": "7 days",
  "30d": "30 days",
  "90d": "90 days",
  all_time: "All time",
};

export interface UsageTotals {
  requests: number;
  tokens: number;
  costUsd: number;
}

export interface ProviderSummary {
  provider: string;
  providerID?: string;
  totalRequests: number;
  totalTokens: number;
  totalCost: number;
}

export interface ModelSummary {
  model: string;
  provider: string;
  requests: number;
  tokens: number;
  cost: number;
}

export interface DeviceSummary {
  deviceId: string;
  requests: number;
  tokens: number;
}

/** Agent-harness totals (Claude Code, Codex, Cursor, …) — the execution source. */
export interface ExecutionSourceSummary {
  sourceId: string;
  sourceName: string;
  totalRequests: number;
  totalTokens: number;
  totalCost: number;
}

/** Harness × model pairing, e.g. "Codex × gpt-5.2". */
export interface ComboSummary {
  sourceId: string;
  sourceName: string;
  provider: string;
  model: string;
  requests: number;
  tokens: number;
  cost: number;
}

/** One day of the daily series (server stores a YYYY-MM-DD → tokens map). */
export interface DailyPoint {
  day: string;
  tokens: number;
}

/** Normalized, render-ready usage window. */
export interface UsageRollup {
  window: UsageWindowKey;
  totals: UsageTotals;
  providerSummaries: ProviderSummary[];
  modelSummaries: ModelSummary[];
  deviceSummaries: DeviceSummary[];
  /** Harness totals. Empty until the server ships execution-source counters. */
  executionSourceSummaries: ExecutionSourceSummary[];
  /** Harness × model pairings. Empty until the server ships combo counters. */
  comboSummaries: ComboSummary[];
  /** Ascending by day. */
  dailyPoints: DailyPoint[];
  /**
   * Sparse per-day per-provider token split (all_time only):
   * "YYYY-MM-DD" → providerID → tokens. Powers the heatmap's day-hover
   * provider breakdown. Empty until the server ships counter schema v3;
   * absent days/providers mean zero, never zero-filled.
   */
  dailyProviderTokens: Record<string, Record<string, number>>;
  /** ISO timestamp the rollup was computed server-side, or null if unknown. */
  computedAt: string | null;
}

export interface QuotaBucket {
  name: string;
  used: number;
  /** -1 means unlimited/unknown. */
  limit: number;
  remaining: number;
  window?: string;
  unit?: string;
  resetAt?: string;
}

export interface QuotaSnapshot {
  provider: string;
  providerID?: string;
  accountLabel?: string;
  planTier?: string;
  confidence: "high" | "medium" | "low" | "stale";
  buckets: QuotaBucket[];
  updatedAt: string | null;
}

/**
 * Fusion ("The Wand" / Elder Wand) allowance for the current month, read from
 * users/{uid}/billing/allowances/months/{monthKey}. Field names mirror the
 * server's canonical reader (elderWandHostedSearch.ts → allowanceNumbersFromDoc):
 * includedFusionSearches / fusionSearchesUsed / topupFusionSearchesPurchased /
 * monthlyFusionSearchCap. (We model only the fusion meter — the verified one —
 * not the hosted-action/relay meters.)
 */
export interface FusionAllowance {
  monthKey: string;
  /** Plan-included monthly searches. */
  included: number;
  /** Top-up searches purchased this month. */
  purchased: number;
  /** Searches consumed this month. */
  used: number;
  /** included + purchased. */
  available: number;
  /** max(0, available - used). */
  remaining: number;
  /** Hard monthly ceiling. */
  monthlyCap: number;
}

/** Plan defaults when the allowance doc has no overrides (Cloud Pro tier). */
const DEFAULT_FUSION_INCLUDED = 100;
const DEFAULT_FUSION_MONTHLY_CAP = 1000;

// --- coercion helpers -------------------------------------------------------

function num(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

function str(v: unknown, fallback = ""): string {
  return typeof v === "string" ? v : fallback;
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null;
}

function arr(v: unknown): unknown[] {
  return Array.isArray(v) ? v : [];
}

/** Firestore Timestamp | ISO string | null → ISO string | null. */
function toIso(v: unknown): string | null {
  if (typeof v === "string") return v;
  if (isRecord(v) && typeof (v as { toDate?: unknown }).toDate === "function") {
    try {
      return (v as { toDate: () => Date }).toDate().toISOString();
    } catch {
      return null;
    }
  }
  // Firestore Timestamp also serializes as { seconds, nanoseconds }.
  if (isRecord(v) && typeof v.seconds === "number") {
    return new Date(v.seconds * 1000).toISOString();
  }
  return null;
}

// --- normalizers ------------------------------------------------------------

export function emptyRollup(window: UsageWindowKey): UsageRollup {
  return {
    window,
    totals: { requests: 0, tokens: 0, costUsd: 0 },
    providerSummaries: [],
    modelSummaries: [],
    deviceSummaries: [],
    executionSourceSummaries: [],
    comboSummaries: [],
    dailyPoints: [],
    dailyProviderTokens: {},
    computedAt: null,
  };
}

export function normalizeRollup(raw: unknown, window: UsageWindowKey): UsageRollup {
  if (!isRecord(raw)) return emptyRollup(window);

  const totalsRaw = isRecord(raw.totals) ? raw.totals : {};
  const totals: UsageTotals = {
    requests: num(totalsRaw.requests),
    tokens: num(totalsRaw.tokens),
    costUsd: num(totalsRaw.costUsd),
  };

  const providerSummaries: ProviderSummary[] = arr(raw.providerSummaries)
    .filter(isRecord)
    .map((p) => ({
      provider: str(p.provider, "unknown"),
      providerID: typeof p.providerID === "string" ? p.providerID : undefined,
      totalRequests: num(p.totalRequests),
      totalTokens: num(p.totalTokens),
      totalCost: num(p.totalCost),
    }))
    .sort((a, b) => b.totalCost - a.totalCost || b.totalTokens - a.totalTokens);

  const modelSummaries: ModelSummary[] = arr(raw.modelSummaries)
    .filter(isRecord)
    .map((m) => ({
      model: str(m.model, "unknown"),
      provider: str(m.provider, "unknown"),
      requests: num(m.requests),
      tokens: num(m.tokens),
      cost: num(m.cost),
    }))
    .sort((a, b) => b.cost - a.cost || b.tokens - a.tokens);

  const deviceSummaries: DeviceSummary[] = arr(raw.deviceSummaries)
    .filter(isRecord)
    .map((d) => ({
      deviceId: str(d.deviceId, "unknown"),
      requests: num(d.requests),
      tokens: num(d.tokens),
    }))
    .sort((a, b) => b.tokens - a.tokens);

  const executionSourceSummaries: ExecutionSourceSummary[] = arr(raw.executionSourceSummaries)
    .filter(isRecord)
    .map((s) => ({
      sourceId: str(s.sourceId, "unknown"),
      sourceName: str(s.sourceName, str(s.sourceId, "unknown")),
      totalRequests: num(s.totalRequests),
      totalTokens: num(s.totalTokens),
      totalCost: num(s.totalCost),
    }))
    .sort((a, b) => b.totalTokens - a.totalTokens || b.totalRequests - a.totalRequests);

  const comboSummaries: ComboSummary[] = arr(raw.comboSummaries)
    .filter(isRecord)
    .map((c) => ({
      sourceId: str(c.sourceId, "unknown"),
      sourceName: str(c.sourceName, str(c.sourceId, "unknown")),
      provider: str(c.provider, "unknown"),
      model: str(c.model, "unknown"),
      requests: num(c.requests),
      tokens: num(c.tokens),
      cost: num(c.cost),
    }))
    .sort((a, b) => b.tokens - a.tokens || b.requests - a.requests);

  // dailyPoints is a { "YYYY-MM-DD": tokens } map; flatten to a sorted array.
  const dailyRaw = isRecord(raw.dailyPoints) ? raw.dailyPoints : {};
  const dailyPoints: DailyPoint[] = Object.entries(dailyRaw)
    .map(([day, tokens]) => ({ day, tokens: num(tokens) }))
    .sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : 0));

  // dailyProviderTokens is a sparse { "YYYY-MM-DD": { providerID: tokens } }
  // map (all_time only, counter schema v3+). Keep only positive counts.
  const dailyProviderTokens: Record<string, Record<string, number>> = {};
  if (isRecord(raw.dailyProviderTokens)) {
    for (const [day, split] of Object.entries(raw.dailyProviderTokens)) {
      if (!isRecord(split)) continue;
      const cleaned: Record<string, number> = {};
      for (const [provider, tokens] of Object.entries(split)) {
        const n = num(tokens);
        if (n > 0) cleaned[provider] = n;
      }
      if (Object.keys(cleaned).length > 0) dailyProviderTokens[day] = cleaned;
    }
  }

  return {
    window,
    totals,
    providerSummaries,
    modelSummaries,
    deviceSummaries,
    executionSourceSummaries,
    comboSummaries,
    dailyPoints,
    dailyProviderTokens,
    computedAt: toIso(raw.computedAt),
  };
}

export function normalizeQuotaSnapshot(raw: unknown): QuotaSnapshot | null {
  if (!isRecord(raw)) return null;
  const buckets: QuotaBucket[] = arr(raw.buckets)
    .filter(isRecord)
    .map((b) => {
      const limit = typeof b.limit === "number" ? b.limit : -1;
      const used = num(b.used);
      const remaining =
        typeof b.remaining === "number"
          ? b.remaining
          : limit >= 0
            ? Math.max(0, limit - used)
            : -1;
      return {
        name: str(b.name, "quota"),
        used,
        limit,
        remaining,
        window: typeof b.window === "string" ? b.window : undefined,
        unit: typeof b.unit === "string" ? b.unit : undefined,
        resetAt: typeof b.resetAt === "string" ? b.resetAt : undefined,
      };
    });
  const confidence = ["high", "medium", "low", "stale"].includes(str(raw.confidence))
    ? (raw.confidence as QuotaSnapshot["confidence"])
    : "stale";
  return {
    provider: str(raw.provider, "unknown"),
    providerID: typeof raw.providerID === "string" ? raw.providerID : undefined,
    accountLabel: typeof raw.accountLabel === "string" ? raw.accountLabel : undefined,
    planTier: typeof raw.planTier === "string" ? raw.planTier : undefined,
    confidence,
    buckets,
    updatedAt: toIso(raw.updatedAt) ?? (typeof raw.fetchedAt === "string" ? raw.fetchedAt : null),
  };
}

function numOr(v: unknown, fallback: number): number {
  return typeof v === "number" && Number.isFinite(v) ? v : fallback;
}

export function normalizeAllowance(raw: unknown, monthKey: string): FusionAllowance {
  const r = isRecord(raw) ? raw : {};
  const included = numOr(r.includedFusionSearches, DEFAULT_FUSION_INCLUDED);
  const purchased = num(r.topupFusionSearchesPurchased);
  const used = num(r.fusionSearchesUsed);
  const monthlyCap = numOr(r.monthlyFusionSearchCap, DEFAULT_FUSION_MONTHLY_CAP);
  // Match the server's displayed quota (elderWandHostedSearch.ts quotaResponse):
  // the grantable limit is capped at the monthly ceiling, so top-ups beyond the
  // cap don't inflate what the dashboard shows.
  const available = Math.min(monthlyCap, included + purchased);
  return {
    monthKey,
    included,
    purchased,
    used,
    available,
    remaining: Math.max(0, available - used),
    monthlyCap,
  };
}

/** Current month key (YYYY-MM) in UTC, matching the server's monthKeyForDate. */
export function currentMonthKey(now: Date): string {
  const y = now.getUTCFullYear();
  const m = String(now.getUTCMonth() + 1).padStart(2, "0");
  return `${y}-${m}`;
}
