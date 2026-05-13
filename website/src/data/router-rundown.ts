/**
 * @fileoverview Daily Intelligent Router Rundown — website data shape.
 *
 * The router daemon's `refreshModelLandscapeBenchmarks` job (see
 * `functions/src/modelLandscape.ts`) writes sanitized benchmark snapshots and
 * source statuses to Firestore on a 24-hour cadence. The website rundown is
 * the operator-facing distillation of that data: per-task ordering, plain-
 * English rationale, source attribution, and freshness — never the raw
 * snapshot stream, never any provider key, cookie, or auth material.
 *
 * Benchmark signals are advisory only. Provider-family constraints, user
 * pinning, account auth, quota state, safety policy, and availability are
 * always evaluated at runtime and can override any ranking shown here.
 */

export const ROUTER_RUNDOWN_SCHEMA_VERSION = 1;

/** Aligned with `ModelBenchmarkTaskCategory` in functions/src/types.ts. */
export type TaskCategoryID =
  | "coding"
  | "terminal"
  | "design"
  | "analysis"
  | "agent"
  | "general";

/** Aligned with `ModelBenchmarkSource` in functions/src/types.ts. */
export type SourceID =
  | "artificial_analysis"
  | "terminal_bench"
  | "design_arena"
  | "huggingface"
  | "manual_fixture"
  | "cached_fixture";

export type SourceStatusKind = "fresh" | "stale" | "unavailable" | "error";

/** Per-snapshot freshness — distinct from `SourceStatusKind`. */
export type FreshnessTag = "fresh" | "stale" | "unavailable" | "cached" | "manual";

/** Display metadata for a benchmark source. */
export interface SourceMeta {
  id: SourceID;
  attribution: string;
  shortLabel: string;
  blurb: string;
  logo: string;
  url: string;
}

export const SOURCE_REGISTRY: Record<SourceID, SourceMeta> = {
  artificial_analysis: {
    id: "artificial_analysis",
    attribution: "Artificial Analysis",
    shortLabel: "AA",
    blurb: "Independent intelligence + coding indices, pricing, and TPS/TTFT samples.",
    logo: "/brand/sources/artificial-analysis.svg",
    url: "https://artificialanalysis.ai/",
  },
  terminal_bench: {
    id: "terminal_bench",
    attribution: "Terminal-Bench (via Hugging Face)",
    shortLabel: "TB",
    blurb: "Public Terminal-Bench leaderboard, verified runs weighted higher.",
    logo: "/brand/sources/terminal-bench.svg",
    url: "https://www.tbench.ai/",
  },
  design_arena: {
    id: "design_arena",
    attribution: "Design Arena",
    shortLabel: "DA",
    blurb: "Pairwise design-task evals with Elo + win-rate, by arena and category.",
    logo: "/brand/sources/design-arena.svg",
    url: "https://www.designarena.ai/",
  },
  huggingface: {
    id: "huggingface",
    attribution: "Hugging Face",
    shortLabel: "HF",
    blurb: "Public dataset leaderboards; used as Terminal-Bench's transport.",
    logo: "/brand/sources/huggingface.svg",
    url: "https://huggingface.co/",
  },
  manual_fixture: {
    id: "manual_fixture",
    attribution: "Manual OpenBurnBar fixture",
    shortLabel: "OBB",
    blurb: "Cached / hand-curated snapshot for sources without a live API.",
    logo: "/brand/sources/manual-fixture.svg",
    url: "/router#sources",
  },
  cached_fixture: {
    id: "cached_fixture",
    attribution: "Cached fixture",
    shortLabel: "CF",
    blurb: "Last-known-good snapshot used while live fetch is unavailable.",
    logo: "/brand/sources/manual-fixture.svg",
    url: "/router#sources",
  },
};

export const TASK_CATEGORIES: Array<{
  id: TaskCategoryID;
  label: string;
  blurb: string;
}> = [
  {
    id: "coding",
    label: "Coding",
    blurb: "Refactors, multi-file edits, repo-grounded code generation.",
  },
  {
    id: "terminal",
    label: "Terminal",
    blurb: "Shell-loop agents that execute, observe, and self-correct.",
  },
  {
    id: "design",
    label: "Design",
    blurb: "Website / UI / SVG / slide generation evaluated head-to-head.",
  },
  {
    id: "analysis",
    label: "Analysis",
    blurb: "Long-context reasoning, summarization, structured extraction.",
  },
  {
    id: "agent",
    label: "Agent / Autopilot",
    blurb: "Tool-use loops with memory, planning, and recovery.",
  },
  {
    id: "general",
    label: "General",
    blurb: "Mixed-intent chat / one-shot questions / catch-all routing.",
  },
];

/**
 * Numeric signals on the recommendation. All units are normalized to 0..1
 * unless the field name says otherwise. `undefined` means "the source did
 * not report it" — the UI must render that honestly as "not reported".
 */
export interface SignalBundle {
  /** Per-source benchmark score, 0..1 normalized. */
  benchmarkScore?: number;
  /** 1.0 = same-day, decays with age. */
  benchmarkFreshness?: number;
  /** Source's own self-reported confidence, 0..1. */
  sourceConfidence?: number;
  /** Stream reliability / tool-success proxy, 0..1. */
  reliability?: number;
  /** Latency signal: 1.0 = very fast, 0 = very slow. */
  latency?: number;
  /** Cost signal: 1.0 = very cheap, 0 = very expensive. */
  cost?: number;
  /** Context window in tokens, raw. */
  contextWindowTokens?: number;
  /** Provider availability classification. */
  availability?: "common" | "limited" | "unknown" | "not_reported";
  /** Whether the model is reachable from at least one routed provider family. */
  routable?: boolean;
}

export interface BenchmarkRankCite {
  source: SourceID;
  attribution: string;
  shortLabel?: string;
  logo: string;
  rank?: number;
  score?: number;
  ageHours?: number;
  freshness: FreshnessTag;
  sourceURL?: string;
}

/** A single ranked recommendation inside a task category. */
export interface Recommendation {
  rank: number;
  modelID: string;
  modelDisplay: string;
  providerID: string;
  providerDisplay: string;
  providerLogo?: string;
  /** Wire-format family the model speaks: "openai_compat" | "anthropic". */
  providerFamily?: string;
  /** Composite weighted score 0..1. */
  score: number;
  /** Fraction of expected signals that were actually reported (0..1). */
  evidenceCoverage: number;
  signals: SignalBundle;
  /** Snapshot freshness for the per-recommendation benchmark evidence. */
  freshness: FreshnessTag;
  /** Plain-English bullets the website renders as the explanation. */
  explanation: string[];
  /** Per-source citation rows shown in the UI with logos + age. */
  citations: BenchmarkRankCite[];
  /** Things this rec is missing or qualified by. */
  limitations: string[];
}

export interface RejectedAlternative {
  modelID: string;
  modelDisplay: string;
  providerID: string;
  providerDisplay: string;
  providerLogo?: string;
  reason: string;
  evidence?: string;
}

export interface TaskRanking {
  taskID: TaskCategoryID;
  taskLabel: string;
  taskBlurb: string;
  /** Ordered. The first entry is the day's top pick. */
  recommendations: Recommendation[];
  rejectedAlternatives: RejectedAlternative[];
  /** One-line operator note for the category, e.g. "no fresh source today". */
  note?: string;
  /** Why the #1 won today, in one or two sentences. */
  topPickRationale: string;
}

export interface SourceStatusEntry {
  source: SourceID;
  attribution: string;
  shortLabel: string;
  status: SourceStatusKind;
  fetchedAt?: string;
  ageHours?: number;
  message: string;
  logo: string;
  url: string;
}

/** Top-level shape persisted as JSON per day. */
export interface RouterDailyRundown {
  date: string;
  generatedAt: string;
  schemaVersion: number;
  sourceStatuses: SourceStatusEntry[];
  taskRankings: TaskRanking[];
  /** Global limitations / disclaimers for the whole day. */
  globalLimitations: string[];
  /** Operator notes for the day, free-text 0..N lines. */
  notes: string[];
}

export function sourceMeta(id: SourceID): SourceMeta {
  return SOURCE_REGISTRY[id];
}

export function freshnessTone(
  freshness: FreshnessTag | SourceStatusKind
): "fresh" | "warn" | "stale" | "off" {
  switch (freshness) {
    case "fresh":
      return "fresh";
    case "stale":
    case "cached":
      return "warn";
    case "manual":
      return "stale";
    case "unavailable":
    case "error":
      return "off";
    default:
      return "stale";
  }
}

/** Format an `ageHours` value into a compact label. */
export function formatAge(hours: number | undefined): string {
  if (hours == null || !Number.isFinite(hours) || hours < 0) {
    return "age unknown";
  }
  if (hours < 1) {
    const minutes = Math.max(1, Math.round(hours * 60));
    return `${minutes}m old`;
  }
  if (hours < 48) {
    return `${Math.round(hours)}h old`;
  }
  return `${Math.round(hours / 24)}d old`;
}
