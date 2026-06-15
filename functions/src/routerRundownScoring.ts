/**
 * @fileoverview Scoring, favorite policy, dethroning margins, and rundown
 *               assembly for the Intelligent Router Rundown.
 *
 * `buildRouterRundown` composes per-task recommendations from sanitized
 * benchmark snapshots, applies the stable-favorite selection policy, and emits
 * the public rundown shape. The signal aggregation and explanation builders are
 * pure relocations of the original inline logic — identical inputs produce
 * identical outputs and side-effects.
 *
 * Inputs are sanitized by `modelLandscape.ts` before they reach this module.
 * No API keys, cookies, bearer tokens, or raw auth material ever land in
 * snapshots or the rundown output.
 */

import type { ModelBenchmarkSnapshotDoc, ModelBenchmarkSource } from "./types.js";
import {
  ROUTER_RUNDOWN_SCHEMA_VERSION,
  TASK_CATEGORIES,
  ROUTABLE_MULTIPLIER,
  FAVORITE_POLICY_VERSION,
  FAVORITE_MIN_FRESHNESS,
  EVIDENCE_DETHRONING_MARGIN,
  BENCHMARK_DETHRONING_MARGIN,
  SELECTION_SCORE_TOP,
  SELECTION_SCORE_STEP,
  SELECTION_SCORE_FLOOR,
  tierMultiplier,
  redact,
  clamp01,
  hoursBetween,
  freshnessSignal,
  avg,
  sourceMeta,
  weightedComposite,
  canonicalizeSnapshots,
  canonicalizeRuntime,
  favoriteSpecForModel,
} from "./routerRundownTypes.js";
import type { ModelMeta, RuntimeMeta, RundownInput, PreviousTaskRanking, FavoriteSpec } from "./routerRundownTypes.js";

type BuiltRecommendation = ReturnType<typeof buildRecommendation>;

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

type RecommendationCitation = {
  source: ModelBenchmarkSource;
  attribution: string;
  shortLabel: string;
  logo: string;
  sourceURL: string;
  rank?: number;
  score?: number;
  ageHours: number | null;
  freshness: string;
};

type AggregatedSnapshots = {
  citations: RecommendationCitation[];
  benchmarkScores: number[];
  benchmarkFreshnesses: number[];
  sourceConfidences: number[];
  reliabilities: number[];
  latencies: number[];
};

function aggregateSnapshots(snapshots: ModelBenchmarkSnapshotDoc[], now: string): AggregatedSnapshots {
  const citations: RecommendationCitation[] = [];
  const benchmarkScores: number[] = [];
  const benchmarkFreshnesses: number[] = [];
  const sourceConfidences: number[] = [];
  const reliabilities: number[] = [];
  const latencies: number[] = [];

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

  return { citations, benchmarkScores, benchmarkFreshnesses, sourceConfidences, reliabilities, latencies };
}

function composeSignals(
  model: ModelMeta,
  aggregated: AggregatedSnapshots,
  runtime: RuntimeMeta | undefined,
  limitations: string[],
): Record<string, number | undefined> {
  const cost = clamp01(model.costSignal);
  if (cost == null) limitations.push("Cost not reported by any active source.");
  const ctx = model.contextWindowTokens == null ? undefined : 0.7;
  if (model.contextWindowTokens == null) limitations.push("Context window not reported.");

  const signals: Record<string, number | undefined> = {
    benchmarkScore: aggregated.benchmarkScores.length ? avg(aggregated.benchmarkScores) : undefined,
    benchmarkFreshness: aggregated.benchmarkFreshnesses.length
      ? Math.max(...aggregated.benchmarkFreshnesses)
      : undefined,
    sourceConfidence: aggregated.sourceConfidences.length ? avg(aggregated.sourceConfidences) : undefined,
    reliability: aggregated.reliabilities.length ? avg(aggregated.reliabilities) : runtime?.reliability,
    latency: aggregated.latencies.length ? avg(aggregated.latencies) : runtime?.latencySignal,
    cost,
    contextFit: ctx,
  };
  if (signals.benchmarkScore == null) limitations.push("No benchmark score from any active source today.");
  if (signals.benchmarkFreshness != null && signals.benchmarkFreshness < 0.4) {
    limitations.push("Benchmark evidence is older than a week — confidence is reduced, not silently inherited.");
  }
  return signals;
}

function costExplanation(cost: number): string {
  if (cost > 0.66) return "Cost-efficient at typical blended pricing.";
  if (cost > 0.33) return "Mid-tier per-token cost.";
  return "Premium-tier per-token cost.";
}

function latencyExplanation(latency: number): string {
  if (latency > 0.66) return "Latency profile is fast (high TPS, low TTFT).";
  if (latency > 0.33) return "Latency is acceptable for non-interactive work.";
  return "Latency is slow; consider for batch / nightly use.";
}

function buildExplanation(
  model: ModelMeta,
  signals: Record<string, number | undefined>,
  citationCount: number,
  tier: string,
  routable: boolean,
): string[] {
  const explanation: string[] = [];
  if (signals.benchmarkScore != null) {
    explanation.push(
      `Composite benchmark score ${(signals.benchmarkScore * 100).toFixed(0)}/100 across ${citationCount} source${citationCount === 1 ? "" : "s"}.`,
    );
  }
  if (signals.benchmarkFreshness != null) {
    explanation.push(
      `Freshest evidence rated ${(signals.benchmarkFreshness * 100).toFixed(0)}/100 — older sources are weighted down, not dropped.`,
    );
  }
  if (signals.cost != null) explanation.push(costExplanation(signals.cost));
  if (signals.latency != null) explanation.push(latencyExplanation(signals.latency));
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
  return explanation;
}

function assembleRecommendation(args: {
  model: ModelMeta;
  favorite: FavoriteSpec | null;
  snapshots: ModelBenchmarkSnapshotDoc[];
  runtime: RuntimeMeta | undefined;
  aggregated: AggregatedSnapshots;
  signals: Record<string, number | undefined>;
  limitations: string[];
  explanation: string[];
  rawScore: number;
  evidenceCoverage: number;
  tier: string;
  tierMul: number;
  routeMul: number;
  routable: boolean;
  score: number;
}) {
  const {
    model,
    favorite,
    snapshots,
    runtime,
    aggregated,
    signals,
    limitations,
    explanation,
    rawScore,
    evidenceCoverage,
    tier,
    tierMul,
    routeMul,
    routable,
    score,
  } = args;
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
    citations: aggregated.citations,
    limitations: limitations.map(redact),
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
  const limitations: string[] = [];
  const aggregated = aggregateSnapshots(snapshots, now);
  const signals = composeSignals(model, aggregated, runtime, limitations);

  const { score: rawScore, evidenceCoverage } = weightedComposite(signals);
  const tier = model.tier ?? "unknown";
  const tierMul = tierMultiplier(tier);
  const routable = runtime?.routable !== false;
  const routeMul = routable ? ROUTABLE_MULTIPLIER.yes : ROUTABLE_MULTIPLIER.no;
  const score = clamp01(rawScore * tierMul * routeMul) ?? 0;

  const explanation = buildExplanation(model, signals, aggregated.citations.length, tier, routable);

  return assembleRecommendation({
    model,
    favorite,
    snapshots,
    runtime,
    aggregated,
    signals,
    limitations,
    explanation,
    rawScore,
    evidenceCoverage,
    tier,
    tierMul,
    routeMul,
    routable,
    score,
  });
}

function pickFreshness(snapshots: ModelBenchmarkSnapshotDoc[]): string {
  if (snapshots.length === 0) return "unavailable";
  if (snapshots.some((s) => s.freshness === "fresh")) return "fresh";
  if (snapshots.some((s) => s.freshness === "stale")) return "stale";
  if (snapshots.some((s) => s.freshness === "cached")) return "cached";
  return "manual";
}

function rejectionReason(rec: BuiltRecommendation): string {
  if (rec.signals.benchmarkScore == null) return "No benchmark evidence for this task category today.";
  if (rec.signals.benchmarkFreshness != null && rec.signals.benchmarkFreshness < 0.4)
    return "Benchmark evidence is too old to outrank fresher peers.";
  if (rec.signals.routable === false) return "Not routable through a connected BurnBar provider account.";
  if (rec.signals.cost != null && rec.signals.cost < 0.2)
    return "Per-token cost is materially higher than the leader at comparable score.";
  return "Selection policy did not clear the leader's margin for this task.";
}

function topPickRationale(top: BuiltRecommendation | undefined, runners: Array<BuiltRecommendation>): string {
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

function buildEmptyTaskRanking(
  task: { id: string; label: string; blurb: string },
  note: string,
): {
  taskID: string;
  taskLabel: string;
  taskBlurb: string;
  recommendations: BuiltRecommendation[];
  rejectedAlternatives: never[];
  note: string;
  topPickRationale: string;
} {
  return {
    taskID: task.id,
    taskLabel: task.label,
    taskBlurb: task.blurb,
    recommendations: [],
    rejectedAlternatives: [],
    note,
    topPickRationale: "Insufficient evidence to recommend a top pick today.",
  };
}

function groupSnapshotsByModel(
  snapshots: ModelBenchmarkSnapshotDoc[],
  taskID: string,
): Map<string, ModelBenchmarkSnapshotDoc[]> {
  const taskSnapshotsByModel = new Map<string, ModelBenchmarkSnapshotDoc[]>();
  for (const snap of snapshots) {
    if (snap.taskCategory !== taskID) continue;
    const list = taskSnapshotsByModel.get(snap.modelID) ?? [];
    list.push(snap);
    taskSnapshotsByModel.set(snap.modelID, list);
  }
  return taskSnapshotsByModel;
}

function buildTaskRanking(args: {
  task: { id: string; label: string; blurb: string };
  models: ModelMeta[];
  canonicalSnapshots: ModelBenchmarkSnapshotDoc[];
  canonicalRuntime: Record<string, RuntimeMeta>;
  previousTaskRanking: PreviousTaskRanking | undefined;
  now: string;
}) {
  const { task, models, canonicalSnapshots, canonicalRuntime, previousTaskRanking, now } = args;
  const taskSnapshotsByModel = groupSnapshotsByModel(canonicalSnapshots, task.id);

  if (taskSnapshotsByModel.size === 0) {
    return buildEmptyTaskRanking(
      task,
      `No benchmark evidence reported for ${task.label} today — ranking is suppressed rather than guessed.`,
    );
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
    return buildEmptyTaskRanking(
      task,
      `No catalogued model matched benchmark evidence for ${task.label} today — ranking is suppressed rather than guessed.`,
    );
  }

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

  const taskRankings = TASK_CATEGORIES.map((task) =>
    buildTaskRanking({
      task,
      models,
      canonicalSnapshots,
      canonicalRuntime,
      previousTaskRanking: previousTaskRankings.get(task.id),
      now,
    }),
  ).filter((r) => r.recommendations.length > 0);

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
