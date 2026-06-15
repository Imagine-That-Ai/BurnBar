/**
 * @fileoverview Shared types, constants, parsing, and pure-signal helpers for
 *               the Intelligent Router Rundown.
 *
 * This module holds the data shapes and side-effect-free utilities that both
 * the scoring pipeline (`routerRundownScoring.ts`) and the public endpoint
 * (`routerRundown.ts`) build on. Splitting these out keeps each rundown source
 * file cohesive and under the per-file line budget. Symbols re-exported from
 * `routerRundown.ts` keep every external import resolving unchanged.
 *
 * Inputs are sanitized by `modelLandscape.ts` before they reach this module.
 * No API keys, cookies, bearer tokens, or raw auth material ever land in
 * snapshots or the rundown output.
 */

import type {
  ModelBenchmarkSnapshotDoc,
  ModelBenchmarkSourceStatusDoc,
  ModelBenchmarkSource,
  ModelBenchmarkTaskCategory,
} from "./types.js";
import { isRecord } from "./guards.js";

export const ROUTER_RUNDOWN_SCHEMA_VERSION = 1;

type TaskCategoryID = ModelBenchmarkTaskCategory;

interface ModelMeta {
  modelID: string;
  modelDisplay: string;
  selectionDisplayName?: string;
  providerID: string;
  providerDisplay: string;
  providerFamily: string;
  providerLogo?: string;
  /** Capability tier: flagship | mid | mini. Drives the tier multiplier. */
  tier: "flagship" | "mid" | "mini";
  contextWindowTokens?: number;
  /** Normalized cost signal, 0..1 (1 = very cheap). */
  costSignal?: number;
  aliases?: string[];
  operatorPreferenceRank?: number;
  operatorPreferencePrior?: number;
  favoritePolicyVersion?: string;
  preferredReasoningEffort?: string;
}

interface RuntimeMeta {
  availability?: "common" | "limited" | "unknown";
  routable?: boolean;
  reliability?: number;
  latencySignal?: number;
}

/** Source registry mirrored from the website module — same logos/URLs. */
const SOURCE_LABELS: Record<
  ModelBenchmarkSource,
  { attribution: string; shortLabel: string; logo: string; url: string }
> = {
  artificial_analysis: {
    attribution: "Artificial Analysis",
    shortLabel: "AA",
    logo: "/brand/sources/artificial-analysis.svg",
    url: "https://artificialanalysis.ai/",
  },
  terminal_bench: {
    attribution: "Terminal-Bench (via Hugging Face)",
    shortLabel: "TB",
    logo: "/brand/sources/terminal-bench.png",
    url: "https://www.tbench.ai/",
  },
  design_arena: {
    attribution: "Design Arena",
    shortLabel: "DA",
    logo: "/brand/sources/design-arena.png",
    url: "https://www.designarena.ai/",
  },
  huggingface: {
    attribution: "Hugging Face",
    shortLabel: "HF",
    logo: "/brand/sources/huggingface.svg",
    url: "https://huggingface.co/",
  },
  manual_fixture: {
    attribution: "Manual OpenBurnBar fixture",
    shortLabel: "OBB",
    logo: "/brand/sources/manual-fixture.svg",
    url: "/router#sources",
  },
  cached_fixture: {
    attribution: "Cached fixture",
    shortLabel: "CF",
    logo: "/brand/sources/manual-fixture.svg",
    url: "/router#sources",
  },
};

export const TASK_CATEGORIES: Array<{
  id: TaskCategoryID;
  label: string;
  blurb: string;
}> = [
  { id: "coding", label: "Coding", blurb: "Refactors, multi-file edits, repo-grounded code generation." },
  { id: "terminal", label: "Terminal", blurb: "Shell-loop agents that execute, observe, and self-correct." },
  { id: "design", label: "Design", blurb: "Website / UI / SVG / slide generation evaluated head-to-head." },
  { id: "analysis", label: "Analysis", blurb: "Long-context reasoning, summarization, structured extraction." },
  { id: "agent", label: "Agent / Autopilot", blurb: "Tool-use loops with memory, planning, and recovery." },
  { id: "general", label: "General", blurb: "Mixed-intent chat / one-shot questions / catch-all routing." },
];

export const WEIGHTS = {
  benchmarkScore: 0.55,
  benchmarkFreshness: 0.14,
  sourceConfidence: 0.05,
  reliability: 0.14,
  latency: 0.03,
  cost: 0.06,
  contextFit: 0.03,
} as const;

const TIER_MULTIPLIER = { flagship: 1.0, mid: 0.96, mini: 0.88, unknown: 0.98 } as const;
export const ROUTABLE_MULTIPLIER = { yes: 1.0, no: 0.8 } as const;
export const FAVORITE_POLICY_VERSION = "2026-05-13.stable-favorites";
export const FAVORITE_MIN_FRESHNESS = 0.55;
export const EVIDENCE_DETHRONING_MARGIN = 0.08;
export const BENCHMARK_DETHRONING_MARGIN = 0.05;
export const SELECTION_SCORE_TOP = 0.99;
export const SELECTION_SCORE_STEP = 0.03;
export const SELECTION_SCORE_FLOOR = 0.05;

const FAVORITE_LADDER: FavoriteEntry[] = [
  {
    modelID: "gpt-5-5",
    rank: 1,
    prior: 0.12,
    displayName: "GPT-5.5 xhigh",
    preferredReasoningEffort: "xhigh",
  },
  {
    modelID: "claude-opus-4-7",
    rank: 2,
    prior: 0.08,
    displayName: "Claude Opus 4.7",
    preferredReasoningEffort: null,
  },
  {
    modelID: "glm-5-1",
    rank: 3,
    prior: 0.05,
    displayName: "GLM 5.1",
    preferredReasoningEffort: null,
  },
];

type FavoriteEntry = {
  modelID: string;
  rank: number;
  prior: number;
  displayName: string;
  preferredReasoningEffort: string | null;
};
const FAVORITE_BY_MODEL_ID: Map<string, FavoriteEntry> = new Map(
  FAVORITE_LADDER.map((entry) => [entry.modelID, entry]),
);
const FAVORITE_BY_RANK: Map<number, FavoriteEntry> = new Map(FAVORITE_LADDER.map((entry) => [entry.rank, entry]));
const BUILT_IN_ALIASES: Record<string, string[]> = {
  "gpt-5-5": [
    "openai/gpt-5.5",
    "openai/gpt-5-5",
    "openai/gpt-5.5-xhigh",
    "openai/gpt-5-5-xhigh",
    "gpt-5.5",
    "gpt-5.5-xhigh",
    "gpt-5-5-xhigh",
  ],
  "claude-opus-4-7": ["anthropic/claude-opus-4-7", "anthropic/claude-opus-4.7", "claude-opus-4.7"],
  "glm-5-1": ["zai-org/GLM-5.1", "zai/glm-5.1", "zai/glm-5-1", "z-ai/glm-5.1", "zhipuai/glm-5.1", "glm-5.1"],
};

const REDACTION_PATTERNS = [
  /\bsk-(?:ant-|cp-|or-|live-)[a-z0-9_-]{8,}\b/gi,
  /\bAIza[0-9A-Za-z_-]{16,}\b/g,
  /\bBearer\s+[A-Za-z0-9._-]{10,}\b/gi,
  /\bcookie[s]?\s*[:=]\s*[^\s;]{8,}/gi,
  /\bx-api-key\s*[:=]\s*[^\s;]{8,}/gi,
  /\bauthorization\s*[:=]\s*[^\s;]{8,}/gi,
];

export function tierMultiplier(tier: string): number {
  switch (tier) {
    case "flagship":
      return TIER_MULTIPLIER.flagship;
    case "mid":
      return TIER_MULTIPLIER.mid;
    case "mini":
      return TIER_MULTIPLIER.mini;
    case "unknown":
      return TIER_MULTIPLIER.unknown;
    default:
      return TIER_MULTIPLIER.unknown;
  }
}

function parseModelTier(value: unknown): ModelMeta["tier"] | undefined {
  switch (value) {
    case "flagship":
    case "mid":
    case "mini":
      return value;
    default:
      return undefined;
  }
}

export function parseModelMeta(raw: unknown): ModelMeta | undefined {
  if (!isRecord(raw) || typeof raw.modelID !== "string") return undefined;
  const tier = parseModelTier(raw.tier);
  if (
    !tier ||
    typeof raw.modelDisplay !== "string" ||
    typeof raw.providerID !== "string" ||
    typeof raw.providerDisplay !== "string" ||
    typeof raw.providerFamily !== "string"
  ) {
    return undefined;
  }
  return {
    modelID: raw.modelID,
    modelDisplay: raw.modelDisplay,
    selectionDisplayName: typeof raw.selectionDisplayName === "string" ? raw.selectionDisplayName : undefined,
    providerID: raw.providerID,
    providerDisplay: raw.providerDisplay,
    providerFamily: raw.providerFamily,
    providerLogo: typeof raw.providerLogo === "string" ? raw.providerLogo : undefined,
    tier,
    contextWindowTokens: typeof raw.contextWindowTokens === "number" ? raw.contextWindowTokens : undefined,
    costSignal: typeof raw.costSignal === "number" ? raw.costSignal : undefined,
    aliases: Array.isArray(raw.aliases)
      ? raw.aliases.filter((item): item is string => typeof item === "string")
      : undefined,
    operatorPreferenceRank: typeof raw.operatorPreferenceRank === "number" ? raw.operatorPreferenceRank : undefined,
    operatorPreferencePrior: typeof raw.operatorPreferencePrior === "number" ? raw.operatorPreferencePrior : undefined,
    favoritePolicyVersion: typeof raw.favoritePolicyVersion === "string" ? raw.favoritePolicyVersion : undefined,
    preferredReasoningEffort:
      typeof raw.preferredReasoningEffort === "string" ? raw.preferredReasoningEffort : undefined,
  };
}

export function parseRuntimeMeta(raw: unknown): RuntimeMeta | undefined {
  if (!isRecord(raw)) return undefined;
  const availability = raw.availability;
  return {
    availability:
      availability === "common" || availability === "limited" || availability === "unknown" ? availability : undefined,
    routable: typeof raw.routable === "boolean" ? raw.routable : undefined,
    reliability: typeof raw.reliability === "number" ? raw.reliability : undefined,
    latencySignal: typeof raw.latencySignal === "number" ? raw.latencySignal : undefined,
  };
}

export function parsePreviousRundown(raw: unknown): RundownInput["previousRundown"] | undefined {
  if (!isRecord(raw) || !Array.isArray(raw.taskRankings)) return undefined;
  const taskRankings: NonNullable<RundownInput["previousRundown"]>["taskRankings"] = [];
  for (const task of raw.taskRankings) {
    if (!isRecord(task)) continue;
    taskRankings.push({
      taskID: typeof task.taskID === "string" ? task.taskID : undefined,
      recommendations: Array.isArray(task.recommendations)
        ? task.recommendations.flatMap((rec) => {
            if (!isRecord(rec) || typeof rec.modelID !== "string") return [];
            return [
              {
                modelID: rec.modelID,
                score: typeof rec.score === "number" ? rec.score : undefined,
                signals: isRecord(rec.signals)
                  ? {
                      benchmarkScore:
                        typeof rec.signals.benchmarkScore === "number"
                          ? rec.signals.benchmarkScore
                          : rec.signals.benchmarkScore === null
                            ? null
                            : undefined,
                    }
                  : undefined,
              },
            ];
          })
        : undefined,
      rejectedAlternatives: Array.isArray(task.rejectedAlternatives)
        ? task.rejectedAlternatives.flatMap((alt) => {
            if (!isRecord(alt) || typeof alt.modelID !== "string") return [];
            return [
              {
                modelID: alt.modelID,
                score: typeof alt.score === "number" ? alt.score : undefined,
                evidenceScore: typeof alt.evidenceScore === "number" ? alt.evidenceScore : undefined,
                benchmarkScore:
                  typeof alt.benchmarkScore === "number"
                    ? alt.benchmarkScore
                    : alt.benchmarkScore === null
                      ? null
                      : undefined,
              },
            ];
          })
        : undefined,
    });
  }
  return { taskRankings };
}

export function redact(text: string | undefined): string {
  if (typeof text !== "string") return "";
  let out = text;
  for (const pat of REDACTION_PATTERNS) out = out.replace(pat, "[redacted]");
  return out;
}

export function clamp01(x: number | undefined): number | undefined {
  if (x == null || !Number.isFinite(x)) return undefined;
  return Math.max(0, Math.min(1, x));
}

export function hoursBetween(now: string, earlier?: string | null): number | undefined {
  if (!now || !earlier) return undefined;
  const a = Date.parse(now);
  const b = Date.parse(earlier);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return undefined;
  return Math.max(0, (a - b) / 3_600_000);
}

export function freshnessSignal(ageHours: number | undefined): number | undefined {
  if (ageHours == null) return undefined;
  if (ageHours <= 24) return 1.0;
  if (ageHours <= 72) return 0.85;
  if (ageHours <= 7 * 24) return 0.55;
  if (ageHours <= 14 * 24) return 0.35;
  if (ageHours <= 30 * 24) return 0.18;
  return 0.05;
}

export function avg(arr: number[]): number {
  return arr.reduce((a, b) => a + b, 0) / arr.length;
}

export function sourceMeta(s: ModelBenchmarkSource) {
  return SOURCE_LABELS[s] ?? SOURCE_LABELS.manual_fixture;
}

export function weightedComposite(signals: Record<string, number | undefined>): {
  score: number;
  evidenceCoverage: number;
} {
  let weightSum = 0;
  let scoreSum = 0;
  let present = 0;
  let total = 0;
  for (const [k, w] of Object.entries(WEIGHTS)) {
    total += 1;
    const v = signals[k];
    if (v == null || !Number.isFinite(v)) continue;
    weightSum += w;
    scoreSum += w * v;
    present += 1;
  }
  if (weightSum <= 0) return { score: 0, evidenceCoverage: 0 };
  const coverage = total > 0 ? present / total : 0;
  const coverageMul = 0.75 + 0.25 * coverage;
  return { score: clamp01((scoreSum / weightSum) * coverageMul) ?? 0, evidenceCoverage: coverage };
}

interface RundownInput {
  date: string;
  generatedAt: string;
  models: ModelMeta[];
  snapshots: ModelBenchmarkSnapshotDoc[];
  statuses: ModelBenchmarkSourceStatusDoc[];
  runtime: Record<string, RuntimeMeta>;
  notes?: string[];
  previousRundown?: {
    taskRankings?: Array<{
      taskID?: string;
      recommendations?: Array<{
        modelID?: string;
        score?: number;
        signals?: { benchmarkScore?: number | null };
      }>;
      rejectedAlternatives?: Array<{
        modelID?: string;
        score?: number;
        evidenceScore?: number;
        benchmarkScore?: number | null;
      }>;
    }>;
  };
}

type PreviousTaskRanking = NonNullable<NonNullable<RundownInput["previousRundown"]>["taskRankings"]>[number];

interface FavoriteSpec {
  rank: number;
  prior: number;
  displayName: string;
  preferredReasoningEffort: string | null;
  policyVersion: string;
}

function normalizedModelID(modelID: string | null | undefined): string {
  return typeof modelID === "string" ? modelID.trim().toLowerCase() : "";
}

function tailModelID(modelID: string | null | undefined): string {
  const normalized = normalizedModelID(modelID);
  return normalized.split("/").filter(Boolean).pop() ?? normalized;
}

function buildAliasIndex(models: ModelMeta[]): Map<string, string> {
  const idx = new Map<string, string>();
  for (const model of models) {
    const candidates = [model.modelID, ...(model.aliases ?? []), ...(BUILT_IN_ALIASES[model.modelID] ?? [])];
    for (const candidate of candidates) {
      const normalized = normalizedModelID(candidate);
      if (!normalized) continue;
      idx.set(normalized, model.modelID);
      idx.set(tailModelID(normalized), model.modelID);
    }
  }
  return idx;
}

function canonicalizeModelID(modelID: string | null | undefined, aliasIndex: Map<string, string>): string | null {
  const normalized = normalizedModelID(modelID);
  if (!normalized) return null;
  return aliasIndex.get(normalized) ?? aliasIndex.get(tailModelID(normalized)) ?? null;
}

export function canonicalizeSnapshots(
  snapshots: ModelBenchmarkSnapshotDoc[],
  models: ModelMeta[],
): ModelBenchmarkSnapshotDoc[] {
  const aliasIndex = buildAliasIndex(models);
  return snapshots.map((snapshot) => {
    const canonical = canonicalizeModelID(snapshot.modelID, aliasIndex);
    return canonical && canonical !== snapshot.modelID ? { ...snapshot, modelID: canonical } : snapshot;
  });
}

export function canonicalizeRuntime(
  runtime: Record<string, RuntimeMeta>,
  models: ModelMeta[],
): Record<string, RuntimeMeta> {
  const aliasIndex = buildAliasIndex(models);
  const out: Record<string, RuntimeMeta> = { ...runtime };
  for (const [modelID, meta] of Object.entries(runtime)) {
    const canonical = canonicalizeModelID(modelID, aliasIndex);
    if (canonical && out[canonical] == null) out[canonical] = meta;
  }
  return out;
}

function asPositiveInteger(value: number | undefined): number | undefined {
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : undefined;
}

export function favoriteSpecForModel(model: ModelMeta): FavoriteSpec | null {
  const builtIn = FAVORITE_BY_MODEL_ID.get(model.modelID);
  const rank = asPositiveInteger(model.operatorPreferenceRank) ?? builtIn?.rank;
  if (rank == null) return null;
  const rankDefault = FAVORITE_BY_RANK.get(rank);
  return {
    rank,
    prior: clamp01(model.operatorPreferencePrior) ?? rankDefault?.prior ?? builtIn?.prior ?? 0,
    displayName: model.selectionDisplayName ?? builtIn?.displayName ?? model.modelDisplay,
    preferredReasoningEffort: model.preferredReasoningEffort ?? builtIn?.preferredReasoningEffort ?? null,
    policyVersion: model.favoritePolicyVersion ?? FAVORITE_POLICY_VERSION,
  };
}

export type { ModelMeta, RuntimeMeta, RundownInput, PreviousTaskRanking, FavoriteSpec, TaskCategoryID };
