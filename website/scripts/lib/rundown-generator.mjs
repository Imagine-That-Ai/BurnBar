/**
 * @fileoverview Deterministic daily-rundown scoring & assembly.
 *
 * Consumes sanitized benchmark snapshots + source-status entries (the same
 * shape persisted by `functions/src/modelLandscape.ts`) and produces a
 * RouterDailyRundown object the website renders.
 *
 * Pure functions. No filesystem, no secrets, no network. The CLI wrapper
 * (`generate-rundown.mjs`) is responsible for reading inputs and writing
 * outputs. The test harness (`test-rundown.mjs`) drives this module
 * directly.
 *
 * Evidence model (deterministic, see WEIGHTS):
 *
 *   score =
 *      0.55 * benchmarkScore
 *    + 0.14 * benchmarkFreshness
 *    + 0.05 * sourceConfidence
 *    + 0.14 * reliability
 *    + 0.03 * latency
 *    + 0.06 * cost
 *    + 0.03 * contextFit
 *
 * Selection then applies the stable-favorite policy below. `score` remains
 * the benchmark-derived evidence value; `selectionScore` is the value used
 * for displayed ordering.
 *
 * All inputs are normalized to 0..1. If a signal is missing, it is excluded
 * from the weighted average (the weight is re-distributed across the
 * present signals — never silently treated as zero). Missing data lowers
 * `evidenceCoverage` instead, which is surfaced in the UI as a limitation.
 */

export const SCHEMA_VERSION = 1;

export const WEIGHTS = Object.freeze({
  benchmarkScore: 0.55,
  benchmarkFreshness: 0.14,
  sourceConfidence: 0.05,
  reliability: 0.14,
  latency: 0.03,
  cost: 0.06,
  contextFit: 0.03,
});

/**
 * Tier multipliers — applied to the final composite. A mini model with the
 * same benchmark numbers as its flagship sibling should not outrank it just
 * because it is cheaper and faster. The operator's intent when asking the
 * router to pick is almost always "give me the best capable model for this
 * task"; cost optimization is a deliberate separate posture.
 */
export const TIER_MULTIPLIER = Object.freeze({
  flagship: 1.0,
  mid: 0.96,
  mini: 0.88,
  unknown: 0.98,
});

/**
 * Routability multiplier — a model BurnBar can't actually reach through a
 * connected provider account is shown for visibility, never recommended for
 * execution. We rank these but they can never beat a healthy routable peer.
 */
export const ROUTABLE_MULTIPLIER = Object.freeze({
  yes: 1.0,
  no: 0.80,
});

export const FAVORITE_POLICY_VERSION = "2026-05-13.stable-favorites";
export const FAVORITE_MIN_FRESHNESS = 0.55;
export const EVIDENCE_DETHRONING_MARGIN = 0.08;
export const BENCHMARK_DETHRONING_MARGIN = 0.05;
export const SELECTION_SCORE_TOP = 0.99;
export const SELECTION_SCORE_STEP = 0.03;
export const SELECTION_SCORE_FLOOR = 0.05;

export const FAVORITE_LADDER = Object.freeze([
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
]);

const FAVORITE_BY_MODEL_ID = new Map(FAVORITE_LADDER.map((entry) => [entry.modelID, entry]));
const FAVORITE_BY_RANK = new Map(FAVORITE_LADDER.map((entry) => [entry.rank, entry]));
const BUILT_IN_ALIASES = Object.freeze({
  "gpt-5-5": ["openai/gpt-5.5", "openai/gpt-5-5", "openai/gpt-5.5-xhigh", "openai/gpt-5-5-xhigh", "gpt-5.5", "gpt-5.5-xhigh", "gpt-5-5-xhigh"],
  "claude-opus-4-7": ["anthropic/claude-opus-4-7", "anthropic/claude-opus-4.7", "claude-opus-4.7"],
  "glm-5-1": ["zai-org/GLM-5.1", "zai/glm-5.1", "zai/glm-5-1", "z-ai/glm-5.1", "zhipuai/glm-5.1", "glm-5.1"],
});

const SOURCE_LABELS = Object.freeze({
  artificial_analysis: { attribution: "Artificial Analysis", shortLabel: "AA", logo: "/brand/sources/artificial-analysis.svg", url: "https://artificialanalysis.ai/" },
  terminal_bench: { attribution: "Terminal-Bench (via Hugging Face)", shortLabel: "TB", logo: "/brand/sources/terminal-bench.png", url: "https://www.tbench.ai/" },
  design_arena: { attribution: "Design Arena", shortLabel: "DA", logo: "/brand/sources/design-arena.png", url: "https://www.designarena.ai/" },
  huggingface: { attribution: "Hugging Face", shortLabel: "HF", logo: "/brand/sources/huggingface.svg", url: "https://huggingface.co/" },
  manual_fixture: { attribution: "Manual OpenBurnBar fixture", shortLabel: "OBB", logo: "/brand/sources/manual-fixture.svg", url: "/router#sources" },
  cached_fixture: { attribution: "Cached fixture", shortLabel: "CF", logo: "/brand/sources/manual-fixture.svg", url: "/router#sources" },
});

const TASK_CATEGORIES = Object.freeze([
  { id: "coding", label: "Coding", blurb: "Refactors, multi-file edits, repo-grounded code generation." },
  { id: "terminal", label: "Terminal", blurb: "Shell-loop agents that execute, observe, and self-correct." },
  { id: "design", label: "Design", blurb: "Website / UI / SVG / slide generation evaluated head-to-head." },
  { id: "analysis", label: "Analysis", blurb: "Long-context reasoning, summarization, structured extraction." },
  { id: "agent", label: "Agent / Autopilot", blurb: "Tool-use loops with memory, planning, and recovery." },
  { id: "general", label: "General", blurb: "Mixed-intent chat / one-shot questions / catch-all routing." },
]);

const REDACTION_PATTERNS = [
  /\bsk-(?:ant-|cp-|or-|live-)[a-z0-9_-]{8,}\b/gi,
  /\bAIza[0-9A-Za-z_-]{16,}\b/g,
  /\bBearer\s+[A-Za-z0-9._-]{10,}\b/gi,
  /\bcookie[s]?\s*[:=]\s*[^\s;]{8,}/gi,
  /\bx-api-key\s*[:=]\s*[^\s;]{8,}/gi,
  /\bauthorization\s*[:=]\s*[^\s;]{8,}/gi,
];

function clamp01(x) {
  if (x == null || !Number.isFinite(x)) return undefined;
  return Math.max(0, Math.min(1, x));
}

function hoursBetween(later, earlier) {
  if (!later || !earlier) return undefined;
  const a = Date.parse(later);
  const b = Date.parse(earlier);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return undefined;
  return Math.max(0, (a - b) / 3_600_000);
}

/**
 * Confidence floor as a function of source age. Fresh = 1.0; 7d = 0.4; 30d
 * = 0.1; older = 0.05 (never zero — stale ≠ silent disappearance).
 */
function freshnessSignal(ageHours) {
  if (ageHours == null) return undefined;
  if (ageHours <= 24) return 1.0;
  if (ageHours <= 72) return 0.85;
  if (ageHours <= 7 * 24) return 0.55;
  if (ageHours <= 14 * 24) return 0.35;
  if (ageHours <= 30 * 24) return 0.18;
  return 0.05;
}

function contextFitSignal(contextWindowTokens, requiredTokens) {
  if (contextWindowTokens == null) return undefined;
  if (requiredTokens == null) return 0.7;
  if (contextWindowTokens >= requiredTokens) return 1.0;
  return Math.max(0, contextWindowTokens / requiredTokens);
}

/** Strip any obvious secret-looking material from free-text fields. */
export function redactExplanation(text) {
  if (typeof text !== "string") return text;
  let out = text;
  for (const pat of REDACTION_PATTERNS) {
    out = out.replace(pat, "[redacted]");
  }
  return out;
}

function safeBullets(list) {
  return (list || []).filter((s) => typeof s === "string" && s.trim().length > 0).map(redactExplanation);
}

function weightedComposite(signals) {
  let weightSum = 0;
  let scoreSum = 0;
  let present = 0;
  let total = 0;
  for (const [key, weight] of Object.entries(WEIGHTS)) {
    total += 1;
    const value = signals[key];
    if (value == null || !Number.isFinite(value)) continue;
    weightSum += weight;
    scoreSum += weight * value;
    present += 1;
  }
  if (weightSum <= 0) return { score: 0, evidenceCoverage: 0 };
  const coverage = total > 0 ? present / total : 0;
  // Coverage discount: a model with fewer reported signals should not be
  // able to win on a partial composite. Missing data lowers confidence,
  // never silently inflates the rank.
  const coverageMultiplier = 0.75 + 0.25 * coverage;
  return {
    score: clamp01((scoreSum / weightSum) * coverageMultiplier) ?? 0,
    evidenceCoverage: coverage,
  };
}

function sourceMeta(source) {
  return SOURCE_LABELS[source] ?? SOURCE_LABELS.manual_fixture;
}

function normalizedModelID(modelID) {
  return typeof modelID === "string" ? modelID.trim().toLowerCase() : "";
}

function tailModelID(modelID) {
  const lower = normalizedModelID(modelID);
  return lower.split("/").filter(Boolean).pop() ?? lower;
}

function buildAliasIndex(models) {
  const idx = new Map();
  for (const model of models ?? []) {
    if (!model?.modelID) continue;
    const canonical = model.modelID;
    for (const candidate of [model.modelID, ...(model.aliases ?? []), ...(BUILT_IN_ALIASES[model.modelID] ?? [])]) {
      const normalized = normalizedModelID(candidate);
      if (!normalized) continue;
      idx.set(normalized, canonical);
      idx.set(tailModelID(normalized), canonical);
    }
  }
  return idx;
}

function canonicalizeModelID(modelID, aliasIndex) {
  const normalized = normalizedModelID(modelID);
  if (!normalized) return null;
  return aliasIndex.get(normalized) ?? aliasIndex.get(tailModelID(normalized)) ?? null;
}

function canonicalizeSnapshots(snapshots, models) {
  const aliasIndex = buildAliasIndex(models);
  return (snapshots ?? []).map((snapshot) => {
    const canonical = canonicalizeModelID(snapshot.modelID, aliasIndex);
    return canonical && canonical !== snapshot.modelID ? { ...snapshot, modelID: canonical } : snapshot;
  });
}

function canonicalizeRuntime(runtime, models) {
  const aliasIndex = buildAliasIndex(models);
  const out = { ...(runtime ?? {}) };
  for (const [modelID, meta] of Object.entries(runtime ?? {})) {
    const canonical = canonicalizeModelID(modelID, aliasIndex);
    if (canonical && out[canonical] == null) out[canonical] = meta;
  }
  return out;
}

function asPositiveInteger(value) {
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : undefined;
}

function favoriteSpecForModel(model) {
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

function hasHardGateSignals(rec) {
  return rec.signals.routable !== false
    && rec.tier === "flagship"
    && rec.signals.benchmarkScore != null
    && rec.signals.benchmarkFreshness != null
    && rec.signals.benchmarkFreshness >= FAVORITE_MIN_FRESHNESS;
}

function favoriteIsProtected(rec) {
  return rec.favoriteRank != null && hasHardGateSignals(rec);
}

function currentMarginsClear(challenger, incumbent) {
  if (!hasHardGateSignals(challenger)) return false;
  if (incumbent.signals.benchmarkScore == null) return true;
  const challengerBenchmark = challenger.signals.benchmarkScore ?? -Infinity;
  const incumbentBenchmark = incumbent.signals.benchmarkScore ?? Infinity;
  return challenger.score >= incumbent.score + EVIDENCE_DETHRONING_MARGIN
    && challengerBenchmark >= incumbentBenchmark + BENCHMARK_DETHRONING_MARGIN;
}

function previousCandidate(previousTaskRanking, modelID) {
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

function previousMarginsClear(challenger, incumbent, previousTaskRanking) {
  const previousChallenger = previousCandidate(previousTaskRanking, challenger.modelID);
  const previousIncumbent = previousCandidate(previousTaskRanking, incumbent.modelID);
  if (!previousChallenger || !previousIncumbent) return false;
  if (previousChallenger.score == null || previousIncumbent.score == null) return false;
  if (previousChallenger.benchmarkScore == null || previousIncumbent.benchmarkScore == null) return false;
  return previousChallenger.score >= previousIncumbent.score + EVIDENCE_DETHRONING_MARGIN
    && previousChallenger.benchmarkScore >= previousIncumbent.benchmarkScore + BENCHMARK_DETHRONING_MARGIN;
}

function canDethrone(challenger, incumbent, previousTaskRanking) {
  if (!currentMarginsClear(challenger, incumbent)) return false;
  if (!favoriteIsProtected(incumbent)) return true;
  return previousMarginsClear(challenger, incumbent, previousTaskRanking);
}

function selectionReason(rec, protectedFavorite) {
  if (protectedFavorite) {
    return `Stable favorite policy ${rec.favoritePolicyVersion}: favorite rank #${rec.favoriteRank} receives a deterministic ${(rec.favoritePrior * 100).toFixed(0)} point prior until a challenger clears both dethroning margins on consecutive rundowns; the final selection score is calibrated after policy ordering so the public number matches the chosen rank.`;
  }
  if (rec.favoriteRank != null) {
    return `Stable favorite policy ${rec.favoritePolicyVersion}: favorite prior withheld until the model is routable, flagship-tier, and backed by fresh benchmark evidence.`;
  }
  return "Evidence score only; to outrank a protected favorite, a challenger must clear both evidence and benchmark dethroning margins across consecutive rundowns.";
}

function annotateSelection(rec) {
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

function ordinalSelectionScore(index) {
  return clamp01(Math.max(SELECTION_SCORE_FLOOR, SELECTION_SCORE_TOP - index * SELECTION_SCORE_STEP));
}

function finalizeSelectionScores(ranked) {
  return ranked.map((rec, idx) => ({
    ...rec,
    selectionScore: ordinalSelectionScore(idx) ?? rec.selectionScore,
  }));
}

function compareEvidence(a, b) {
  if (b.selectionScore !== a.selectionScore) return b.selectionScore - a.selectionScore;
  if (b.score !== a.score) return b.score - a.score;
  return String(a.modelID).localeCompare(String(b.modelID));
}

function compareSelection(a, b, previousTaskRanking) {
  const aProtected = favoriteIsProtected(a);
  const bProtected = favoriteIsProtected(b);

  if (aProtected && bProtected && a.favoriteRank !== b.favoriteRank) {
    if (a.favoriteRank < b.favoriteRank) return canDethrone(b, a, previousTaskRanking) ? 1 : -1;
    return canDethrone(a, b, previousTaskRanking) ? -1 : 1;
  }
  if (aProtected && !bProtected) return canDethrone(b, a, previousTaskRanking) ? 1 : -1;
  if (!aProtected && bProtected) return canDethrone(a, b, previousTaskRanking) ? -1 : 1;

  return compareEvidence(a, b);
}

/**
 * Build a Recommendation from a model's snapshot bundle for a task.
 *
 * @param {object} model            - canonical model metadata
 * @param {object[]} snapshots      - snapshots that match (model, taskCategory)
 * @param {object[]} statuses       - source statuses
 * @param {object} runtime          - runtime/availability metadata
 * @param {string} now              - ISO timestamp
 * @param {number} requiredTokens?  - optional context-window requirement
 */
function buildRecommendation({ model, snapshots, statuses, runtime, now, requiredTokens }) {
  const favorite = favoriteSpecForModel(model);
  const usableSnapshots = snapshots.filter((s) => s.score != null || s.rank != null || s.latencySignal != null || s.reliabilitySignal != null);

  const citations = [];
  const benchmarkScores = [];
  const benchmarkFreshnesses = [];
  const sourceConfidences = [];
  const reliabilities = [];
  const latencies = [];
  const limitations = [];

  for (const snap of usableSnapshots) {
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
      ageHours,
      freshness: snap.freshness ?? "fresh",
    });
    if (snap.score != null) benchmarkScores.push(snap.score);
    if (fresh != null) benchmarkFreshnesses.push(fresh);
    if (snap.confidence != null) sourceConfidences.push(snap.confidence);
    if (snap.reliabilitySignal != null) reliabilities.push(snap.reliabilitySignal);
    if (snap.latencySignal != null) latencies.push(snap.latencySignal);
  }

  // Cost / availability come from the canonical model metadata (driven by
  // Artificial Analysis pricing or operator overrides), not per-source.
  const cost = clamp01(model.costSignal);
  if (cost == null) limitations.push("Cost not reported by any active source.");

  const ctx = contextFitSignal(model.contextWindowTokens, requiredTokens);
  if (model.contextWindowTokens == null) limitations.push("Context window not reported.");

  const signals = {
    benchmarkScore: benchmarkScores.length ? average(benchmarkScores) : undefined,
    benchmarkFreshness: benchmarkFreshnesses.length ? Math.max(...benchmarkFreshnesses) : undefined,
    sourceConfidence: sourceConfidences.length ? average(sourceConfidences) : undefined,
    reliability: reliabilities.length ? average(reliabilities) : runtime?.reliability,
    latency: latencies.length ? average(latencies) : runtime?.latencySignal,
    cost,
    contextFit: ctx,
  };
  if (signals.benchmarkScore == null) limitations.push("No benchmark score from any active source today.");
  if (signals.benchmarkFreshness != null && signals.benchmarkFreshness < 0.4) {
    limitations.push("Benchmark evidence is older than a week — confidence is reduced, not silently inherited.");
  }

  const { score: rawScore, evidenceCoverage } = weightedComposite(signals);
  const tier = (model.tier ?? "unknown");
  const tierMul = TIER_MULTIPLIER[tier] ?? TIER_MULTIPLIER.unknown;
  const routable = runtime?.routable !== false;
  const routeMul = routable ? ROUTABLE_MULTIPLIER.yes : ROUTABLE_MULTIPLIER.no;
  const score = clamp01(rawScore * tierMul * routeMul) ?? 0;

  const explanation = [];
  if (signals.benchmarkScore != null) {
    explanation.push(`Composite benchmark score ${(signals.benchmarkScore * 100).toFixed(0)}/100 across ${citations.length} source${citations.length === 1 ? "" : "s"}.`);
  }
  if (signals.benchmarkFreshness != null) {
    const freshPct = (signals.benchmarkFreshness * 100).toFixed(0);
    explanation.push(`Freshest evidence rated ${freshPct}/100 — older sources are weighted down, not dropped.`);
  }
  if (signals.cost != null) {
    explanation.push(cost > 0.66 ? "Cost-efficient at typical blended pricing." : cost > 0.33 ? "Mid-tier per-token cost." : "Premium-tier per-token cost.");
  }
  if (signals.latency != null) {
    explanation.push(signals.latency > 0.66 ? "Latency profile is fast (high TPS, low TTFT)." : signals.latency > 0.33 ? "Latency is acceptable for non-interactive work." : "Latency is slow; consider for batch / nightly use.");
  }
  if (model.contextWindowTokens != null) {
    explanation.push(`Context window: ${(model.contextWindowTokens / 1000).toFixed(0)}k tokens.`);
  }
  if (model.providerFamily) {
    explanation.push(`Wire-format family: ${model.providerFamily}.`);
  }
  if (runtime?.routable === false) {
    explanation.push("Not currently routable through a BurnBar-connected account — shown for visibility, ranked behind routable peers, never auto-selected.");
  }
  if (tier === "mini" || tier === "mid") {
    explanation.push(`Tier · ${tier}. Counted behind flagship siblings at equivalent benchmark; pin the tier explicitly to invert this.`);
  }

  return {
    rank: 0, // assigned after sort
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
      benchmarkScore: signals.benchmarkScore,
      benchmarkFreshness: signals.benchmarkFreshness,
      sourceConfidence: signals.sourceConfidence,
      reliability: signals.reliability,
      latency: signals.latency,
      cost: signals.cost,
      contextWindowTokens: model.contextWindowTokens,
      availability: runtime?.availability ?? "unknown",
      routable: runtime?.routable !== false,
    },
    freshness: pickFreshness(usableSnapshots, statuses),
    explanation: safeBullets(explanation),
    citations,
    limitations: safeBullets(limitations),
  };
}

function pickFreshness(snapshots, statuses) {
  if (snapshots.length === 0) return "unavailable";
  if (snapshots.some((s) => s.freshness === "fresh")) {
    return statuses.some((s) => s.status === "error") ? "stale" : "fresh";
  }
  if (snapshots.some((s) => s.freshness === "stale")) return "stale";
  if (snapshots.some((s) => s.freshness === "cached")) return "cached";
  return "manual";
}

function average(arr) {
  return arr.reduce((a, b) => a + b, 0) / arr.length;
}

function stableSort(list) {
  return [...list]
    .map((item, idx) => ({ item, idx }))
    .sort((a, b) => {
      if (b.item.score !== a.item.score) return b.item.score - a.item.score;
      return a.idx - b.idx; // stable
    })
    .map((entry) => entry.item);
}

function topPickRationale(top, runners) {
  if (!top) return "No model met the floor today; routing falls back to user-pinned defaults.";
  const reasons = [];
  if (top.favoriteRank != null && top.favoritePrior > 0) {
    reasons.push(`stable favorite rank #${top.favoriteRank} under ${top.favoritePolicyVersion}`);
  }
  if (top.preferredReasoningEffort) {
    reasons.push(`preferred reasoning effort ${top.preferredReasoningEffort}`);
  }
  if (top.signals.benchmarkScore != null) {
    reasons.push(`led the benchmark composite at ${(top.signals.benchmarkScore * 100).toFixed(0)}/100`);
  }
  if (top.signals.benchmarkFreshness != null && top.signals.benchmarkFreshness >= 0.8) {
    reasons.push("evidence is fresh");
  } else if (top.signals.benchmarkFreshness != null) {
    reasons.push("evidence is the freshest available, even though older than ideal");
  }
  if (top.signals.cost != null && top.signals.cost > 0.5) {
    reasons.push("cost is competitive");
  }
  if (top.signals.contextWindowTokens != null && top.signals.contextWindowTokens >= 200_000) {
    reasons.push(`context window of ${(top.signals.contextWindowTokens / 1000).toFixed(0)}k clears typical large-context work`);
  }
  if (runners.length > 0) {
    reasons.push(`runner-up ${runners[0].modelDisplay} is held in reserve for instant failover`);
  }
  const sentence = reasons.length > 0
    ? `Today's pick: ${top.modelDisplay} — ${reasons.join("; ")}.`
    : `Today's pick: ${top.modelDisplay}.`;
  return redactExplanation(sentence);
}

function rejectedFor(task, all, top) {
  return all
    .filter((m) => !top || m.modelID !== top.modelID)
    .slice(2) // first two go in alternatives; the rest become rejected
    .map((rec) => ({
      modelID: rec.modelID,
      modelDisplay: rec.modelDisplay,
      providerID: rec.providerID,
      providerDisplay: rec.providerDisplay,
      providerLogo: rec.providerLogo,
      evidenceScore: rec.score,
      selectionScore: rec.selectionScore,
      benchmarkScore: rec.signals.benchmarkScore,
      reason: rejectionReason(rec),
      evidence: rec.signals.benchmarkScore == null
        ? "No benchmark score from any active source for this task."
        : `Evidence ${(rec.score * 100).toFixed(0)}/100; selection ${(rec.selectionScore * 100).toFixed(0)}/100 vs. leader ${(top.selectionScore * 100).toFixed(0)}/100.`,
    }));
}

function rejectionReason(rec) {
  if (rec.signals.benchmarkScore == null) {
    return "No benchmark evidence for this task category today.";
  }
  if (rec.signals.benchmarkFreshness != null && rec.signals.benchmarkFreshness < 0.4) {
    return "Benchmark evidence is too old to outrank fresher peers.";
  }
  if (rec.signals.routable === false) {
    return "Not routable through a connected BurnBar provider account.";
  }
  if (rec.signals.cost != null && rec.signals.cost < 0.2) {
    return "Per-token cost is materially higher than the leader at comparable score.";
  }
  return "Selection policy did not clear the leader's margin for this task.";
}

/**
 * Build a TaskRanking for a single task category.
 *
 * @param {object} params
 * @param {string} params.taskID
 * @param {object[]} params.models             - canonical model metadata list
 * @param {object[]} params.snapshots          - all snapshots for the day
 * @param {object[]} params.statuses           - source statuses for the day
 * @param {object<string,object>} params.runtime - by modelID
 * @param {string} params.now
 * @param {number} [params.requiredTokens]
 * @param {object} [params.previousTaskRanking]
 */
export function buildTaskRanking({ taskID, models, snapshots, statuses, runtime, now, requiredTokens, previousTaskRanking }) {
  const taskMeta = TASK_CATEGORIES.find((t) => t.id === taskID);
  const canonicalSnapshots = canonicalizeSnapshots(snapshots, models);
  const canonicalRuntime = canonicalizeRuntime(runtime, models);
  const taskSnapshotsByModel = new Map();
  for (const snap of canonicalSnapshots) {
    if (snap.taskCategory !== taskID) continue;
    const list = taskSnapshotsByModel.get(snap.modelID) ?? [];
    list.push(snap);
    taskSnapshotsByModel.set(snap.modelID, list);
  }

  // If no model has any benchmark evidence for this task category today,
  // we surface no ranking at all — better to show an honest empty state
  // than fabricate ordinality from runtime metadata alone.
  if (taskSnapshotsByModel.size === 0) {
    return {
      taskID,
      taskLabel: taskMeta?.label ?? taskID,
      taskBlurb: taskMeta?.blurb ?? "",
      recommendations: [],
      rejectedAlternatives: [],
      note: `No benchmark evidence reported for ${taskMeta?.label ?? taskID} today — ranking is suppressed rather than guessed.`,
      topPickRationale: "Insufficient evidence to recommend a top pick today.",
    };
  }

  // Only rank models that have at least one benchmark snapshot for this
  // task category. Otherwise we'd be ranking models on runtime metadata
  // alone, which silently inflates models with good cost/latency profiles
  // but no actual benchmark evidence for the task at hand.
  const recs = models
    .filter((m) => (taskSnapshotsByModel.get(m.modelID) ?? []).length > 0)
    .map((m) => buildRecommendation({
      model: m,
      snapshots: taskSnapshotsByModel.get(m.modelID),
      statuses,
      runtime: canonicalRuntime?.[m.modelID],
      now,
      requiredTokens,
    }));

  if (recs.length === 0) {
    return {
      taskID,
      taskLabel: taskMeta?.label ?? taskID,
      taskBlurb: taskMeta?.blurb ?? "",
      recommendations: [],
      rejectedAlternatives: [],
      note: `No benchmark evidence reported for ${taskMeta?.label ?? taskID} today — ranking is suppressed rather than guessed.`,
      topPickRationale: "Insufficient evidence to recommend a top pick today.",
    };
  }

  const ranked = finalizeSelectionScores([...recs]
    .map(annotateSelection)
    .sort((a, b) => compareSelection(a, b, previousTaskRanking))
    .map((rec, idx) => ({ ...rec, rank: idx + 1 })));
  const top = ranked[0];
  const alternatives = ranked.slice(1, 3);
  const rejected = rejectedFor(taskID, ranked, top);

  const hasAnyFreshEvidence = ranked.some((r) => r.signals.benchmarkScore != null && r.signals.benchmarkFreshness != null && r.signals.benchmarkFreshness >= 0.55);

  return {
    taskID,
    taskLabel: taskMeta?.label ?? taskID,
    taskBlurb: taskMeta?.blurb ?? "",
    recommendations: [top, ...alternatives].filter(Boolean),
    rejectedAlternatives: rejected,
    note: hasAnyFreshEvidence
      ? undefined
      : `Limited fresh evidence for ${taskMeta?.label ?? taskID} today — confidence is intentionally reduced, never inferred.`,
    topPickRationale: topPickRationale(top, alternatives),
  };
}

function buildSourceStatuses(statuses, now) {
  return statuses.map((entry) => {
    const meta = sourceMeta(entry.source);
    const ageHours = hoursBetween(now, entry.fetchedAt);
    return {
      source: entry.source,
      attribution: meta.attribution,
      shortLabel: meta.shortLabel,
      logo: meta.logo,
      url: meta.url,
      status: entry.status,
      fetchedAt: entry.fetchedAt,
      ageHours,
      message: redactExplanation(entry.message ?? ""),
    };
  });
}

/**
 * Top-level assembly. Pure function. Deterministic for a given input.
 *
 * @param {object} input
 * @param {string} input.date            YYYY-MM-DD
 * @param {string} [input.generatedAt]   ISO; defaults to T12:00 of date.
 * @param {object[]} input.models        canonical model metadata
 * @param {object[]} input.snapshots     benchmark snapshots
 * @param {object[]} input.statuses      source statuses
 * @param {object} [input.runtime]       runtime/availability by modelID
 * @param {string[]} [input.notes]       operator notes for the day
 * @param {object} [input.previousRundown] previous dated rundown for dethroning confirmation
 */
export function buildRundown(input) {
  const date = input.date;
  const generatedAt = input.generatedAt ?? `${date}T12:00:00.000Z`;
  const now = generatedAt;
  const statuses = Array.isArray(input.statuses) ? input.statuses : [];
  const snapshots = Array.isArray(input.snapshots) ? input.snapshots : [];
  const models = Array.isArray(input.models) ? input.models : [];
  const runtime = input.runtime ?? {};
  const previousTaskRankings = new Map((input.previousRundown?.taskRankings ?? []).map((task) => [task.taskID, task]));

  const taskRankings = TASK_CATEGORIES.map((t) => buildTaskRanking({
    taskID: t.id,
    models,
    snapshots,
    statuses,
    runtime,
    now,
    previousTaskRanking: previousTaskRankings.get(t.id),
  })).filter((r) => r.recommendations.length > 0);

  const sourceStatuses = buildSourceStatuses(statuses, now);

  const globalLimitations = [
    "Benchmark snapshots are advisory only — runtime constraints (provider-family mode, user pinning, auth, quota, safety, and availability) override any ranking shown here.",
    `Displayed order uses stable favorite policy ${FAVORITE_POLICY_VERSION}: GPT-5.5 xhigh, Claude Opus 4.7, then GLM 5.1 stay preferred while routable and freshly benchmarked; a challenger must beat both evidence and benchmark margins across consecutive rundowns to dethrone them.`,
    "BurnBar does not fabricate benchmark numbers. Missing data is reported as 'not reported', never guessed.",
    "Daily snapshots are sampled from public or documented sources; raw provider keys, cookies, and bearer tokens are never written into snapshots or this rundown.",
  ];

  if (sourceStatuses.some((s) => s.status === "error" || s.status === "unavailable")) {
    globalLimitations.push("One or more sources were unavailable for this day; the rundown reflects only the sources that responded.");
  }

  return {
    date,
    generatedAt,
    schemaVersion: SCHEMA_VERSION,
    sourceStatuses,
    taskRankings,
    globalLimitations,
    notes: safeBullets(input.notes),
  };
}

export { TASK_CATEGORIES, SOURCE_LABELS };
