/**
 * @fileoverview Build, persist, and serve the daily Intelligent Router
 *               Rundown.
 *
 * This is the production source-of-truth for the rundown the website
 * displays. The static website includes a build-time fallback fixture, but
 * the live page hydrates from this endpoint so the recommendations always
 * reflect what the daily Cloud Function actually saw.
 *
 * Flow:
 *
 *   1. Daily Cloud Function `refreshModelLandscapeBenchmarks` (scheduled.ts)
 *      writes sanitized snapshots + statuses to Firestore.
 *   2. `buildAndPersistRouterRundown(db)` reads those, computes the rundown,
 *      and writes `router_rundowns/{date}` + `router_rundowns/latest`.
 *   3. The public HTTPS function `latestRouterRundown` serves
 *      `router_rundowns/latest` with CORS + cache headers.
 *
 * Inputs are sanitized by `modelLandscape.ts` before they reach this module.
 * No API keys, cookies, bearer tokens, or raw auth material ever land in
 * snapshots or the rundown output.
 */

import type { Firestore } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import type {
  ModelBenchmarkSnapshotDoc,
  ModelBenchmarkSourceStatusDoc,
  ModelBenchmarkSource,
  ModelBenchmarkTaskCategory,
} from "./types.js";
import { isRecord, parseModelBenchmarkSnapshotDoc, parseModelBenchmarkSourceStatusDoc } from "./guards.js";
import { logError, logWarn } from "./logging.js";
import { setPublicJsonSecurityHeaders } from "./publicHttpSecurityHeaders.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const ROUTER_RUNDOWN_SCHEMA_VERSION = 1;

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

const TASK_CATEGORIES: Array<{
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

const WEIGHTS = {
  benchmarkScore: 0.55,
  benchmarkFreshness: 0.14,
  sourceConfidence: 0.05,
  reliability: 0.14,
  latency: 0.03,
  cost: 0.06,
  contextFit: 0.03,
} as const;

const TIER_MULTIPLIER = { flagship: 1.0, mid: 0.96, mini: 0.88, unknown: 0.98 } as const;
const ROUTABLE_MULTIPLIER = { yes: 1.0, no: 0.8 } as const;
export const FAVORITE_POLICY_VERSION = "2026-05-13.stable-favorites";
const FAVORITE_MIN_FRESHNESS = 0.55;
const EVIDENCE_DETHRONING_MARGIN = 0.08;
const BENCHMARK_DETHRONING_MARGIN = 0.05;
const SELECTION_SCORE_TOP = 0.99;
const SELECTION_SCORE_STEP = 0.03;
const SELECTION_SCORE_FLOOR = 0.05;

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

function tierMultiplier(tier: string): number {
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

function parseModelMeta(raw: unknown): ModelMeta | undefined {
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

function parseRuntimeMeta(raw: unknown): RuntimeMeta | undefined {
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

function parsePreviousRundown(raw: unknown): RundownInput["previousRundown"] | undefined {
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

function redact(text: string | undefined): string {
  if (typeof text !== "string") return "";
  let out = text;
  for (const pat of REDACTION_PATTERNS) out = out.replace(pat, "[redacted]");
  return out;
}

function clamp01(x: number | undefined): number | undefined {
  if (x == null || !Number.isFinite(x)) return undefined;
  return Math.max(0, Math.min(1, x));
}

function hoursBetween(now: string, earlier?: string | null): number | undefined {
  if (!now || !earlier) return undefined;
  const a = Date.parse(now);
  const b = Date.parse(earlier);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return undefined;
  return Math.max(0, (a - b) / 3_600_000);
}

function freshnessSignal(ageHours: number | undefined): number | undefined {
  if (ageHours == null) return undefined;
  if (ageHours <= 24) return 1.0;
  if (ageHours <= 72) return 0.85;
  if (ageHours <= 7 * 24) return 0.55;
  if (ageHours <= 14 * 24) return 0.35;
  if (ageHours <= 30 * 24) return 0.18;
  return 0.05;
}

function avg(arr: number[]): number {
  return arr.reduce((a, b) => a + b, 0) / arr.length;
}

function sourceMeta(s: ModelBenchmarkSource) {
  return SOURCE_LABELS[s] ?? SOURCE_LABELS.manual_fixture;
}

function weightedComposite(signals: Record<string, number | undefined>): {
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

type BuiltRecommendation = ReturnType<typeof buildRecommendation>;
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

function canonicalizeSnapshots(
  snapshots: ModelBenchmarkSnapshotDoc[],
  models: ModelMeta[],
): ModelBenchmarkSnapshotDoc[] {
  const aliasIndex = buildAliasIndex(models);
  return snapshots.map((snapshot) => {
    const canonical = canonicalizeModelID(snapshot.modelID, aliasIndex);
    return canonical && canonical !== snapshot.modelID ? { ...snapshot, modelID: canonical } : snapshot;
  });
}

function canonicalizeRuntime(runtime: Record<string, RuntimeMeta>, models: ModelMeta[]): Record<string, RuntimeMeta> {
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

function favoriteSpecForModel(model: ModelMeta): FavoriteSpec | null {
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

function hasHardGateSignals(rec: BuiltRecommendation): boolean {
  return (
    rec.signals.routable !== false &&
    rec.tier === "flagship" &&
    rec.signals.benchmarkScore != null &&
    rec.signals.benchmarkFreshness != null &&
    rec.signals.benchmarkFreshness >= FAVORITE_MIN_FRESHNESS
  );
}

function favoriteIsProtected(rec: BuiltRecommendation): boolean {
  return rec.favoriteRank != null && hasHardGateSignals(rec);
}

function currentMarginsClear(challenger: BuiltRecommendation, incumbent: BuiltRecommendation): boolean {
  if (!hasHardGateSignals(challenger)) return false;
  if (incumbent.signals.benchmarkScore == null) return true;
  const challengerBenchmark = challenger.signals.benchmarkScore ?? -Infinity;
  const incumbentBenchmark = incumbent.signals.benchmarkScore ?? Infinity;
  return (
    challenger.score >= incumbent.score + EVIDENCE_DETHRONING_MARGIN &&
    challengerBenchmark >= incumbentBenchmark + BENCHMARK_DETHRONING_MARGIN
  );
}

function previousCandidate(
  previousTaskRanking: PreviousTaskRanking | undefined,
  modelID: string,
): {
  score?: number;
  benchmarkScore?: number | null;
} | null {
  if (!previousTaskRanking) return null;
  for (const rec of previousTaskRanking.recommendations ?? []) {
    if (rec.modelID !== modelID) continue;
    return {
      score: rec.score,
      benchmarkScore: rec.signals?.benchmarkScore,
    };
  }
  for (const rec of previousTaskRanking.rejectedAlternatives ?? []) {
    if (rec.modelID !== modelID) continue;
    return {
      score: rec.evidenceScore ?? rec.score,
      benchmarkScore: rec.benchmarkScore,
    };
  }
  return null;
}

function previousMarginsClear(
  challenger: BuiltRecommendation,
  incumbent: BuiltRecommendation,
  previousTaskRanking: PreviousTaskRanking | undefined,
): boolean {
  const previousChallenger = previousCandidate(previousTaskRanking, challenger.modelID);
  const previousIncumbent = previousCandidate(previousTaskRanking, incumbent.modelID);
  if (!previousChallenger || !previousIncumbent) return false;
  if (previousChallenger.score == null || previousIncumbent.score == null) return false;
  if (previousChallenger.benchmarkScore == null || previousIncumbent.benchmarkScore == null) return false;
  return (
    previousChallenger.score >= previousIncumbent.score + EVIDENCE_DETHRONING_MARGIN &&
    previousChallenger.benchmarkScore >= previousIncumbent.benchmarkScore + BENCHMARK_DETHRONING_MARGIN
  );
}

function canDethrone(
  challenger: BuiltRecommendation,
  incumbent: BuiltRecommendation,
  previousTaskRanking: PreviousTaskRanking | undefined,
): boolean {
  if (!currentMarginsClear(challenger, incumbent)) return false;
  if (!favoriteIsProtected(incumbent)) return true;
  return previousMarginsClear(challenger, incumbent, previousTaskRanking);
}

function selectionReason(rec: BuiltRecommendation, protectedFavorite: boolean): string {
  if (protectedFavorite) {
    return `Stable favorite policy ${rec.favoritePolicyVersion}: favorite rank #${rec.favoriteRank} receives a deterministic ${(rec.favoritePrior * 100).toFixed(0)} point prior until a challenger clears both dethroning margins on consecutive rundowns; the final selection score is calibrated after policy ordering so the public number matches the chosen rank.`;
  }
  if (rec.favoriteRank != null) {
    return `Stable favorite policy ${rec.favoritePolicyVersion}: favorite prior withheld until the model is routable, flagship-tier, and backed by fresh benchmark evidence.`;
  }
  return "Evidence score only; to outrank a protected favorite, a challenger must clear both evidence and benchmark dethroning margins across consecutive rundowns.";
}

function annotateSelection(rec: BuiltRecommendation): BuiltRecommendation {
  const protectedFavorite = favoriteIsProtected(rec);
  const favoritePrior = protectedFavorite ? rec.favoritePrior : 0;
  const selectionScore = clamp01(rec.score + favoritePrior) ?? rec.score;
  return {
    ...rec,
    favoritePrior,
    selectionScore,
    selectionReason: selectionReason(rec, protectedFavorite),
  };
}

function ordinalSelectionScore(index: number): number | undefined {
  return clamp01(Math.max(SELECTION_SCORE_FLOOR, SELECTION_SCORE_TOP - index * SELECTION_SCORE_STEP));
}

function finalizeSelectionScores(ranked: BuiltRecommendation[]): BuiltRecommendation[] {
  return ranked.map((rec, idx) => ({
    ...rec,
    selectionScore: ordinalSelectionScore(idx) ?? rec.selectionScore,
  }));
}

function compareEvidence(a: BuiltRecommendation, b: BuiltRecommendation): number {
  if (b.selectionScore !== a.selectionScore) return b.selectionScore - a.selectionScore;
  if (b.score !== a.score) return b.score - a.score;
  return a.modelID.localeCompare(b.modelID);
}

function compareSelection(
  a: BuiltRecommendation,
  b: BuiltRecommendation,
  previousTaskRanking: PreviousTaskRanking | undefined,
): number {
  const aProtected = favoriteIsProtected(a);
  const bProtected = favoriteIsProtected(b);

  if (aProtected && bProtected && a.favoriteRank !== b.favoriteRank) {
    if ((a.favoriteRank ?? Infinity) < (b.favoriteRank ?? Infinity)) {
      return canDethrone(b, a, previousTaskRanking) ? 1 : -1;
    }
    return canDethrone(a, b, previousTaskRanking) ? -1 : 1;
  }
  if (aProtected && !bProtected) return canDethrone(b, a, previousTaskRanking) ? 1 : -1;
  if (!aProtected && bProtected) return canDethrone(a, b, previousTaskRanking) ? -1 : 1;
  return compareEvidence(a, b);
}

export function buildRouterRundown(input: RundownInput) {
  const { date, generatedAt, models, snapshots, statuses, runtime, notes, previousRundown } = input;
  const now = generatedAt;
  const canonicalSnapshots = canonicalizeSnapshots(snapshots, models);
  const canonicalRuntime = canonicalizeRuntime(runtime, models);
  const previousTaskRankings = new Map((previousRundown?.taskRankings ?? []).map((task) => [task.taskID, task]));

  const sourceStatuses = statuses.map((s) => {
    const meta = sourceMeta(s.source);
    const ageHours = hoursBetween(now, s.fetchedAt);
    return {
      source: s.source,
      attribution: meta.attribution,
      shortLabel: meta.shortLabel,
      logo: meta.logo,
      url: meta.url,
      status: s.status,
      fetchedAt: s.fetchedAt ?? null,
      ageHours: ageHours ?? null,
      message: redact(s.message),
    };
  });

  const taskRankings = TASK_CATEGORIES.map((task) => {
    const taskSnapshotsByModel = new Map<string, ModelBenchmarkSnapshotDoc[]>();
    for (const snap of canonicalSnapshots) {
      if (snap.taskCategory !== task.id) continue;
      const list = taskSnapshotsByModel.get(snap.modelID) ?? [];
      list.push(snap);
      taskSnapshotsByModel.set(snap.modelID, list);
    }

    if (taskSnapshotsByModel.size === 0) {
      return {
        taskID: task.id,
        taskLabel: task.label,
        taskBlurb: task.blurb,
        recommendations: [],
        rejectedAlternatives: [],
        note: `No benchmark evidence reported for ${task.label} today — ranking is suppressed rather than guessed.`,
        topPickRationale: "Insufficient evidence to recommend a top pick today.",
      };
    }

    const recs = models
      .filter((m) => (taskSnapshotsByModel.get(m.modelID) ?? []).length > 0)
      .map((m) =>
        buildRecommendation({
          model: m,
          snapshots: taskSnapshotsByModel.get(m.modelID) ?? [],
          runtime: canonicalRuntime[m.modelID],
          now,
        }),
      );

    if (recs.length === 0) {
      return {
        taskID: task.id,
        taskLabel: task.label,
        taskBlurb: task.blurb,
        recommendations: [],
        rejectedAlternatives: [],
        note: `No catalogued model matched benchmark evidence for ${task.label} today — ranking is suppressed rather than guessed.`,
        topPickRationale: "Insufficient evidence to recommend a top pick today.",
      };
    }

    const previousTaskRanking = previousTaskRankings.get(task.id);
    const ranked = finalizeSelectionScores(
      recs
        .map(annotateSelection)
        .sort((a, b) => compareSelection(a, b, previousTaskRanking))
        .map((r, i) => ({ ...r, rank: i + 1 })),
    );

    const top = ranked[0];
    const alternatives = ranked.slice(1, 3);
    const rejected = ranked.slice(3).map((r) => ({
      modelID: r.modelID,
      modelDisplay: r.modelDisplay,
      providerID: r.providerID,
      providerDisplay: r.providerDisplay,
      providerLogo: r.providerLogo,
      evidenceScore: r.score,
      selectionScore: r.selectionScore,
      benchmarkScore: r.signals.benchmarkScore,
      reason: rejectionReason(r),
      evidence:
        r.signals.benchmarkScore == null
          ? "No benchmark score from any active source for this task."
          : `Evidence ${(r.score * 100).toFixed(0)}/100; selection ${(r.selectionScore * 100).toFixed(0)}/100 vs. leader ${(top.selectionScore * 100).toFixed(0)}/100.`,
    }));

    return {
      taskID: task.id,
      taskLabel: task.label,
      taskBlurb: task.blurb,
      recommendations: [top, ...alternatives],
      rejectedAlternatives: rejected,
      note: undefined,
      topPickRationale: topPickRationale(top, alternatives),
    };
  }).filter((r) => r.recommendations.length > 0);

  const globalLimitations = [
    "Benchmark snapshots are advisory only — runtime constraints (provider-family mode, user pinning, auth, quota, safety, and availability) override any ranking shown here.",
    `Displayed order uses stable favorite policy ${FAVORITE_POLICY_VERSION}: GPT-5.5 xhigh, Claude Opus 4.7, then GLM 5.1 stay preferred while routable and freshly benchmarked; a challenger must beat both evidence and benchmark margins across consecutive rundowns to dethrone them.`,
    "BurnBar does not fabricate benchmark numbers. Missing data is reported as 'not reported', never guessed.",
    "Daily snapshots are sampled from public or documented sources; raw provider keys, cookies, and bearer tokens are never written into snapshots or this rundown.",
  ];

  return {
    date,
    generatedAt,
    schemaVersion: ROUTER_RUNDOWN_SCHEMA_VERSION,
    sourceStatuses,
    taskRankings,
    globalLimitations,
    notes: (notes ?? []).map(redact).filter((n) => n.length > 0),
  };
}

function buildRecommendation({
  model,
  snapshots,
  runtime,
  now,
}: {
  model: ModelMeta;
  snapshots: ModelBenchmarkSnapshotDoc[];
  runtime?: RuntimeMeta;
  now: string;
}) {
  const favorite = favoriteSpecForModel(model);
  const citations: Array<{
    source: ModelBenchmarkSource;
    attribution: string;
    shortLabel: string;
    logo: string;
    sourceURL: string;
    rank?: number;
    score?: number;
    ageHours: number | null;
    freshness: string;
  }> = [];
  const benchmarkScores: number[] = [];
  const benchmarkFreshnesses: number[] = [];
  const sourceConfidences: number[] = [];
  const reliabilities: number[] = [];
  const latencies: number[] = [];
  const limitations: string[] = [];

  for (const snap of snapshots) {
    const ageHours = hoursBetween(now, snap.fetchedAt);
    const fresh = freshnessSignal(ageHours);
    const meta = sourceMeta(snap.source);
    citations.push({
      source: snap.source,
      attribution: meta.attribution,
      shortLabel: meta.shortLabel,
      logo: meta.logo,
      sourceURL: snap.sourceURL ?? meta.url,
      rank: snap.rank,
      score: snap.score,
      ageHours: ageHours ?? null,
      freshness: snap.freshness ?? "fresh",
    });
    if (snap.score != null) benchmarkScores.push(snap.score);
    if (fresh != null) benchmarkFreshnesses.push(fresh);
    if (snap.confidence != null) sourceConfidences.push(snap.confidence);
    if (snap.reliabilitySignal != null) reliabilities.push(snap.reliabilitySignal);
    if (snap.latencySignal != null) latencies.push(snap.latencySignal);
  }

  const cost = clamp01(model.costSignal);
  if (cost == null) limitations.push("Cost not reported by any active source.");
  const ctx = model.contextWindowTokens == null ? undefined : 0.7;
  if (model.contextWindowTokens == null) limitations.push("Context window not reported.");

  const signals: Record<string, number | undefined> = {
    benchmarkScore: benchmarkScores.length ? avg(benchmarkScores) : undefined,
    benchmarkFreshness: benchmarkFreshnesses.length ? Math.max(...benchmarkFreshnesses) : undefined,
    sourceConfidence: sourceConfidences.length ? avg(sourceConfidences) : undefined,
    reliability: reliabilities.length ? avg(reliabilities) : runtime?.reliability,
    latency: latencies.length ? avg(latencies) : runtime?.latencySignal,
    cost,
    contextFit: ctx,
  };
  if (signals.benchmarkScore == null) limitations.push("No benchmark score from any active source today.");
  if (signals.benchmarkFreshness != null && signals.benchmarkFreshness < 0.4) {
    limitations.push("Benchmark evidence is older than a week — confidence is reduced, not silently inherited.");
  }

  const { score: rawScore, evidenceCoverage } = weightedComposite(signals);
  const tier = model.tier ?? "unknown";
  const tierMul = tierMultiplier(tier);
  const routable = runtime?.routable !== false;
  const routeMul = routable ? ROUTABLE_MULTIPLIER.yes : ROUTABLE_MULTIPLIER.no;
  const score = clamp01(rawScore * tierMul * routeMul) ?? 0;

  const explanation: string[] = [];
  if (signals.benchmarkScore != null) {
    explanation.push(
      `Composite benchmark score ${(signals.benchmarkScore * 100).toFixed(0)}/100 across ${citations.length} source${citations.length === 1 ? "" : "s"}.`,
    );
  }
  if (signals.benchmarkFreshness != null) {
    explanation.push(
      `Freshest evidence rated ${(signals.benchmarkFreshness * 100).toFixed(0)}/100 — older sources are weighted down, not dropped.`,
    );
  }
  if (signals.cost != null) {
    explanation.push(
      signals.cost > 0.66
        ? "Cost-efficient at typical blended pricing."
        : signals.cost > 0.33
          ? "Mid-tier per-token cost."
          : "Premium-tier per-token cost.",
    );
  }
  if (signals.latency != null) {
    explanation.push(
      signals.latency > 0.66
        ? "Latency profile is fast (high TPS, low TTFT)."
        : signals.latency > 0.33
          ? "Latency is acceptable for non-interactive work."
          : "Latency is slow; consider for batch / nightly use.",
    );
  }
  if (model.contextWindowTokens != null) {
    explanation.push(`Context window: ${(model.contextWindowTokens / 1000).toFixed(0)}k tokens.`);
  }
  if (model.providerFamily) {
    explanation.push(`Wire-format family: ${model.providerFamily}.`);
  }
  if (!routable) {
    explanation.push(
      "Not currently routable through a BurnBar-connected account — shown for visibility, ranked behind routable peers, never auto-selected.",
    );
  }
  if (tier === "mini" || tier === "mid") {
    explanation.push(
      `Tier · ${tier}. Counted behind flagship siblings at equivalent benchmark; pin the tier explicitly to invert this.`,
    );
  }

  return {
    rank: 0,
    modelID: model.modelID,
    modelDisplay: favorite?.displayName ?? model.modelDisplay,
    canonicalModelDisplay: model.modelDisplay,
    providerID: model.providerID,
    providerDisplay: model.providerDisplay,
    providerLogo: model.providerLogo,
    providerFamily: model.providerFamily,
    tier,
    score,
    selectionScore: score,
    favoriteRank: favorite?.rank ?? null,
    favoritePrior: favorite?.prior ?? 0,
    favoritePolicyVersion: favorite?.policyVersion ?? null,
    preferredReasoningEffort: favorite?.preferredReasoningEffort ?? null,
    selectionReason: "Evidence score only.",
    rawScore,
    tierMultiplier: tierMul,
    routableMultiplier: routeMul,
    evidenceCoverage,
    signals: {
      benchmarkScore: signals.benchmarkScore ?? null,
      benchmarkFreshness: signals.benchmarkFreshness ?? null,
      sourceConfidence: signals.sourceConfidence ?? null,
      reliability: signals.reliability ?? null,
      latency: signals.latency ?? null,
      cost: signals.cost ?? null,
      contextWindowTokens: model.contextWindowTokens ?? null,
      availability: runtime?.availability ?? "unknown",
      routable: routable,
    },
    freshness: pickFreshness(snapshots),
    explanation: explanation.map(redact),
    citations,
    limitations: limitations.map(redact),
  };
}

function pickFreshness(snapshots: ModelBenchmarkSnapshotDoc[]): string {
  if (snapshots.length === 0) return "unavailable";
  if (snapshots.some((s) => s.freshness === "fresh")) return "fresh";
  if (snapshots.some((s) => s.freshness === "stale")) return "stale";
  if (snapshots.some((s) => s.freshness === "cached")) return "cached";
  return "manual";
}

function rejectionReason(rec: ReturnType<typeof buildRecommendation>): string {
  if (rec.signals.benchmarkScore == null) return "No benchmark evidence for this task category today.";
  if (rec.signals.benchmarkFreshness != null && rec.signals.benchmarkFreshness < 0.4)
    return "Benchmark evidence is too old to outrank fresher peers.";
  if (rec.signals.routable === false) return "Not routable through a connected BurnBar provider account.";
  if (rec.signals.cost != null && rec.signals.cost < 0.2)
    return "Per-token cost is materially higher than the leader at comparable score.";
  return "Selection policy did not clear the leader's margin for this task.";
}

function topPickRationale(
  top: ReturnType<typeof buildRecommendation> | undefined,
  runners: Array<ReturnType<typeof buildRecommendation>>,
): string {
  if (!top) return "No model met the floor today; routing falls back to user-pinned defaults.";
  const reasons: string[] = [];
  if (top.favoriteRank != null && top.favoritePrior > 0)
    reasons.push(`stable favorite rank #${top.favoriteRank} under ${top.favoritePolicyVersion}`);
  if (top.preferredReasoningEffort) reasons.push(`preferred reasoning effort ${top.preferredReasoningEffort}`);
  if (top.signals.benchmarkScore != null)
    reasons.push(`led the benchmark composite at ${(top.signals.benchmarkScore * 100).toFixed(0)}/100`);
  if (top.signals.benchmarkFreshness != null && top.signals.benchmarkFreshness >= 0.8)
    reasons.push("evidence is fresh");
  else if (top.signals.benchmarkFreshness != null)
    reasons.push("evidence is the freshest available, even though older than ideal");
  if (top.signals.cost != null && top.signals.cost > 0.5) reasons.push("cost is competitive");
  if (top.signals.contextWindowTokens != null && top.signals.contextWindowTokens >= 200_000)
    reasons.push(
      `context window of ${(top.signals.contextWindowTokens / 1000).toFixed(0)}k clears typical large-context work`,
    );
  if (runners.length > 0) reasons.push(`runner-up ${runners[0].modelDisplay} is held in reserve for instant failover`);
  return redact(
    reasons.length > 0
      ? `Today's pick: ${top.modelDisplay} — ${reasons.join("; ")}.`
      : `Today's pick: ${top.modelDisplay}.`,
  );
}

// ───────────────────────────── persistence ─────────────────────────────────

/**
 * Load operator-maintained model + runtime metadata from Firestore. Falls
 * back to a built-in best-effort default catalog if the doc doesn't exist
 * yet (first deploy). The doc shape is:
 *
 *   router_rundown_catalog/current
 *     models: ModelMeta[]
 *     runtime: Record<modelID, RuntimeMeta>
 *
 * Operators bump this doc whenever the model landscape shifts.
 */
async function loadRundownCatalog(db: Firestore): Promise<{
  models: ModelMeta[];
  runtime: Record<string, RuntimeMeta>;
}> {
  const ref = db.doc("router_rundown_catalog/current");
  const snap = await ref.get();
  if (snap.exists) {
    const data = snap.data() ?? {};
    return {
      models: Array.isArray(data.models)
        ? data.models.map(parseModelMeta).filter((model): model is ModelMeta => model != null)
        : [],
      runtime: isRecord(data.runtime)
        ? Object.fromEntries(
            Object.entries(data.runtime).flatMap(([modelID, value]) => {
              const parsed = parseRuntimeMeta(value);
              return parsed ? [[modelID, parsed]] : [];
            }),
          )
        : {},
    };
  }
  return DEFAULT_CATALOG;
}

/**
 * Default catalog seeded on first deploy. Operators can update Firestore at
 * `router_rundown_catalog/current` without redeploying functions.
 */
const DEFAULT_CATALOG: { models: ModelMeta[]; runtime: Record<string, RuntimeMeta> } = {
  models: [],
  runtime: {},
};

export async function buildAndPersistRouterRundown(db: Firestore, now: Date = new Date()): Promise<void> {
  const date = now.toISOString().slice(0, 10);
  const generatedAt = now.toISOString();

  const [snapshotsSnap, statusesSnap, catalog, previousLatestSnap] = await Promise.all([
    db.collection("model_benchmark_snapshots").get(),
    db.collection("model_benchmark_source_status").get(),
    loadRundownCatalog(db),
    db.doc("router_rundowns/latest").get(),
  ]);

  const snapshots = snapshotsSnap.docs
    .map((d) => parseModelBenchmarkSnapshotDoc(d.data()))
    .filter((snapshot): snapshot is ModelBenchmarkSnapshotDoc => snapshot != null);
  const statuses = statusesSnap.docs
    .map((d) => parseModelBenchmarkSourceStatusDoc(d.data()))
    .filter((status): status is ModelBenchmarkSourceStatusDoc => status != null);
  const previousLatest = previousLatestSnap.exists ? previousLatestSnap.data() : undefined;
  const previousRundown =
    previousLatest && typeof previousLatest.date === "string" && previousLatest.date !== date
      ? parsePreviousRundown(previousLatest)
      : undefined;

  if (catalog.models.length === 0) {
    logWarn({
      event: "router_rundown.catalog_empty",
    });
  }

  const rundown = buildRouterRundown({
    date,
    generatedAt,
    models: catalog.models,
    snapshots,
    statuses,
    runtime: catalog.runtime,
    previousRundown,
  });

  const batch = db.batch();
  batch.set(db.doc(`router_rundowns/${date}`), rundown);
  batch.set(db.doc("router_rundowns/latest"), rundown);
  await batch.commit();
}

/**
 * Cost/abuse hardening for the public endpoint below.
 *
 * The raw cloudfunctions.net URL bypasses the Hosting CDN, so without an
 * in-process cache every GET is an invocation + a Firestore read. The cache is
 * keyed by rundown date ("latest" included) and bounded; `latest` and today's
 * doc are overwritten by every scheduled run so they get a short TTL, while
 * past dates are immutable after the day rolls over and can cache long.
 * 404s are negative-cached so missing-doc probes stop costing reads.
 */
const RUNDOWN_CACHE_MUTABLE_TTL_MS = 60_000;
const RUNDOWN_CACHE_IMMUTABLE_TTL_MS = 24 * 60 * 60 * 1000;
const RUNDOWN_CACHE_NEGATIVE_TTL_MS = 60_000;
const RUNDOWN_CACHE_MAX_ENTRIES = 64;

/** No rundown can exist before the feature shipped; earlier dates 404 without a read. */
const RUNDOWN_EARLIEST_DATE = "2025-01-01";

interface RundownCacheEntry {
  status: 200 | 404;
  body: unknown;
  expiresAtMillis: number;
}

const rundownResponseCache = new Map<string, RundownCacheEntry>();

/**
 * True when `candidate` (already regex-shaped YYYY-MM-DD) is a real calendar
 * date inside the window rundowns can exist in. The regex alone admits an
 * unbounded key space (e.g. 9999-99-99) that would defeat both the Hosting CDN
 * cache and this in-memory cache while still costing a Firestore read per key.
 */
function isPlausibleRundownDate(candidate: string, now: Date): boolean {
  const [year, month, day] = candidate.split("-").map(Number);
  const utc = new Date(Date.UTC(year, month - 1, day));
  if (utc.getUTCFullYear() !== year || utc.getUTCMonth() !== month - 1 || utc.getUTCDate() !== day) return false;
  if (candidate < RUNDOWN_EARLIEST_DATE) return false;
  // Allow one day ahead of server UTC "today" for clock skew; anything later
  // cannot have been written yet.
  const upperBound = new Date(now.getTime() + 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  return candidate <= upperBound;
}

function cachedRundownResponse(key: string, now: Date): RundownCacheEntry | undefined {
  const entry = rundownResponseCache.get(key);
  if (!entry) return undefined;
  if (now.getTime() >= entry.expiresAtMillis) {
    rundownResponseCache.delete(key);
    return undefined;
  }
  return entry;
}

function storeRundownResponse(key: string, status: 200 | 404, body: unknown, now: Date): void {
  // Delete-then-set keeps Map insertion order usable as an eviction queue.
  rundownResponseCache.delete(key);
  if (rundownResponseCache.size >= RUNDOWN_CACHE_MAX_ENTRIES) {
    const oldest = rundownResponseCache.keys().next().value;
    if (oldest !== undefined) rundownResponseCache.delete(oldest);
  }
  const today = now.toISOString().slice(0, 10);
  const ttlMillis =
    status !== 200
      ? RUNDOWN_CACHE_NEGATIVE_TTL_MS
      : key === "latest" || key === today
        ? RUNDOWN_CACHE_MUTABLE_TTL_MS
        : RUNDOWN_CACHE_IMMUTABLE_TTL_MS;
  rundownResponseCache.set(key, { status, body, expiresAtMillis: now.getTime() + ttlMillis });
}

/**
 * Public HTTPS endpoint serving the latest rundown as JSON.
 *
 * - GET /latestRouterRundown            → router_rundowns/latest
 * - GET /latestRouterRundown?date=YYYY-MM-DD → that day's rundown
 *
 * CORS open (this is public data by design). Cache 5 minutes.
 */
export const latestRouterRundown = onRequest(
  {
    region: FUNCTIONS_REGION,
    cors: true,
    // Unauthenticated endpoint: maxInstances is the only hard cap on
    // invocation spend if someone hammers the raw function URL.
    maxInstances: 10,
  },
  async (req, res) => {
    setPublicJsonSecurityHeaders(res);
    if (req.method !== "GET") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }
    try {
      // Accept the date from either ?date=YYYY-MM-DD or the trailing path
      // segment (e.g. /api/router-rundown/2026-05-13).
      const pathSegment = (req.path ?? "").split("/").filter(Boolean).pop() ?? "";
      const candidate = typeof req.query.date === "string" ? req.query.date : pathSegment;
      const date = /^\d{4}-\d{2}-\d{2}$/.test(candidate) ? candidate : "latest";
      const now = new Date();
      if (date !== "latest" && !isPlausibleRundownDate(date, now)) {
        // Same response a missing doc would get, without the Firestore read.
        res.status(404).json({ error: "not_found", date });
        return;
      }
      const cached = cachedRundownResponse(date, now);
      if (cached) {
        if (cached.status === 200) res.set("Cache-Control", "public, max-age=300, s-maxage=300");
        res.status(cached.status).json(cached.body);
        return;
      }
      const { getFirestore } = await import("firebase-admin/firestore");
      const db = getFirestore();
      const docRef = db.doc(`router_rundowns/${date}`);
      const snap = await docRef.get();
      if (!snap.exists) {
        const body = { error: "not_found", date };
        storeRundownResponse(date, 404, body, now);
        res.status(404).json(body);
        return;
      }
      const body = snap.data();
      storeRundownResponse(date, 200, body, now);
      res.set("Cache-Control", "public, max-age=300, s-maxage=300");
      res.status(200).json(body);
    } catch (err) {
      logError({ event: "router_rundown.latest_failed", error: String(err) });
      res.status(500).json({ error: "internal" });
    }
  },
);
