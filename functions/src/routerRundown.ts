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

export const ROUTER_RUNDOWN_SCHEMA_VERSION = 1;

type TaskCategoryID = ModelBenchmarkTaskCategory;

interface ModelMeta {
  modelID: string;
  modelDisplay: string;
  providerID: string;
  providerDisplay: string;
  providerFamily: string;
  providerLogo?: string;
  /** Capability tier: flagship | mid | mini. Drives the tier multiplier. */
  tier: "flagship" | "mid" | "mini";
  contextWindowTokens?: number;
  /** Normalized cost signal, 0..1 (1 = very cheap). */
  costSignal?: number;
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

const REDACTION_PATTERNS = [
  /\bsk-(?:ant-|cp-|or-|live-)[a-z0-9_-]{8,}\b/gi,
  /\bAIza[0-9A-Za-z_-]{16,}\b/g,
  /\bBearer\s+[A-Za-z0-9._-]{10,}\b/gi,
  /\bcookie[s]?\s*[:=]\s*[^\s;]{8,}/gi,
  /\bx-api-key\s*[:=]\s*[^\s;]{8,}/gi,
  /\bauthorization\s*[:=]\s*[^\s;]{8,}/gi,
];

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
}

export function buildRouterRundown(input: RundownInput) {
  const { date, generatedAt, models, snapshots, statuses, runtime, notes } = input;
  const now = generatedAt;

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
    for (const snap of snapshots) {
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
      .map((m) => buildRecommendation({
        model: m,
        snapshots: taskSnapshotsByModel.get(m.modelID) ?? [],
        runtime: runtime[m.modelID],
        now,
      }));

    recs.sort((a, b) => b.score - a.score);
    recs.forEach((r, i) => { r.rank = i + 1; });

    const top = recs[0];
    const alternatives = recs.slice(1, 3);
    const rejected = recs.slice(3).map((r) => ({
      modelID: r.modelID,
      modelDisplay: r.modelDisplay,
      providerID: r.providerID,
      providerDisplay: r.providerDisplay,
      providerLogo: r.providerLogo,
      reason: rejectionReason(r),
      evidence: r.signals.benchmarkScore == null
        ? "No benchmark score from any active source for this task."
        : `Composite ${(r.score * 100).toFixed(0)}/100 vs. leader ${(top.score * 100).toFixed(0)}/100.`,
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
  const tierMul = TIER_MULTIPLIER[tier as keyof typeof TIER_MULTIPLIER] ?? TIER_MULTIPLIER.unknown;
  const routable = runtime?.routable !== false;
  const routeMul = routable ? ROUTABLE_MULTIPLIER.yes : ROUTABLE_MULTIPLIER.no;
  const score = clamp01(rawScore * tierMul * routeMul) ?? 0;

  const explanation: string[] = [];
  if (signals.benchmarkScore != null) {
    explanation.push(`Composite benchmark score ${(signals.benchmarkScore * 100).toFixed(0)}/100 across ${citations.length} source${citations.length === 1 ? "" : "s"}.`);
  }
  if (signals.benchmarkFreshness != null) {
    explanation.push(`Freshest evidence rated ${(signals.benchmarkFreshness * 100).toFixed(0)}/100 — older sources are weighted down, not dropped.`);
  }
  if (signals.cost != null) {
    explanation.push(signals.cost > 0.66 ? "Cost-efficient at typical blended pricing." : signals.cost > 0.33 ? "Mid-tier per-token cost." : "Premium-tier per-token cost.");
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
  if (!routable) {
    explanation.push("Not currently routable through a BurnBar-connected account — shown for visibility, ranked behind routable peers, never auto-selected.");
  }
  if (tier === "mini" || tier === "mid") {
    explanation.push(`Tier · ${tier}. Counted behind flagship siblings at equivalent benchmark; pin the tier explicitly to invert this.`);
  }

  return {
    rank: 0,
    modelID: model.modelID,
    modelDisplay: model.modelDisplay,
    providerID: model.providerID,
    providerDisplay: model.providerDisplay,
    providerLogo: model.providerLogo,
    providerFamily: model.providerFamily,
    tier,
    score,
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
  if (rec.signals.benchmarkFreshness != null && rec.signals.benchmarkFreshness < 0.4) return "Benchmark evidence is too old to outrank fresher peers.";
  if (rec.signals.routable === false) return "Not routable through a connected BurnBar provider account.";
  if (rec.signals.cost != null && rec.signals.cost < 0.2) return "Per-token cost is materially higher than the leader at comparable score.";
  return "Composite score did not clear the leader's margin for this task.";
}

function topPickRationale(top: ReturnType<typeof buildRecommendation> | undefined, runners: Array<ReturnType<typeof buildRecommendation>>): string {
  if (!top) return "No model met the floor today; routing falls back to user-pinned defaults.";
  const reasons: string[] = [];
  if (top.signals.benchmarkScore != null) reasons.push(`led the benchmark composite at ${(top.signals.benchmarkScore * 100).toFixed(0)}/100`);
  if (top.signals.benchmarkFreshness != null && top.signals.benchmarkFreshness >= 0.8) reasons.push("evidence is fresh");
  else if (top.signals.benchmarkFreshness != null) reasons.push("evidence is the freshest available, even though older than ideal");
  if (top.signals.cost != null && top.signals.cost > 0.5) reasons.push("cost is competitive");
  if (top.signals.contextWindowTokens != null && top.signals.contextWindowTokens >= 200_000) reasons.push(`context window of ${(top.signals.contextWindowTokens / 1000).toFixed(0)}k clears typical large-context work`);
  if (runners.length > 0) reasons.push(`runner-up ${runners[0].modelDisplay} is held in reserve for instant failover`);
  return redact(reasons.length > 0
    ? `Today's pick: ${top.modelDisplay} — ${reasons.join("; ")}.`
    : `Today's pick: ${top.modelDisplay}.`);
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
export async function loadRundownCatalog(db: Firestore): Promise<{
  models: ModelMeta[];
  runtime: Record<string, RuntimeMeta>;
}> {
  const ref = db.doc("router_rundown_catalog/current");
  const snap = await ref.get();
  if (snap.exists) {
    const data = snap.data() ?? {};
    return {
      models: Array.isArray(data.models) ? (data.models as ModelMeta[]) : [],
      runtime: typeof data.runtime === "object" && data.runtime != null ? data.runtime as Record<string, RuntimeMeta> : {},
    };
  }
  return DEFAULT_CATALOG;
}

/**
 * Default catalog seeded on first deploy. Operators can update Firestore at
 * `router_rundown_catalog/current` without redeploying functions.
 */
export const DEFAULT_CATALOG: { models: ModelMeta[]; runtime: Record<string, RuntimeMeta> } = {
  models: [],
  runtime: {},
};

export async function buildAndPersistRouterRundown(db: Firestore, now: Date = new Date()): Promise<void> {
  const date = now.toISOString().slice(0, 10);
  const generatedAt = now.toISOString();

  const [snapshotsSnap, statusesSnap, catalog] = await Promise.all([
    db.collection("model_benchmark_snapshots").get(),
    db.collection("model_benchmark_source_status").get(),
    loadRundownCatalog(db),
  ]);

  const snapshots: ModelBenchmarkSnapshotDoc[] = snapshotsSnap.docs.map((d) => d.data() as ModelBenchmarkSnapshotDoc);
  const statuses: ModelBenchmarkSourceStatusDoc[] = statusesSnap.docs.map((d) => d.data() as ModelBenchmarkSourceStatusDoc);

  if (catalog.models.length === 0) {
    console.warn("[routerRundown] router_rundown_catalog/current is empty; rundown will be empty until populated.");
  }

  const rundown = buildRouterRundown({
    date,
    generatedAt,
    models: catalog.models,
    snapshots,
    statuses,
    runtime: catalog.runtime,
  });

  const batch = db.batch();
  batch.set(db.doc(`router_rundowns/${date}`), rundown);
  batch.set(db.doc("router_rundowns/latest"), rundown);
  await batch.commit();
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
    region: "us-central1",
    cors: true,
  },
  async (req, res) => {
    if (req.method !== "GET") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }
    try {
      const { getFirestore } = await import("firebase-admin/firestore");
      const db = getFirestore();
      // Accept the date from either ?date=YYYY-MM-DD or the trailing path
      // segment (e.g. /api/router-rundown/2026-05-13).
      const pathSegment = (req.path ?? "").split("/").filter(Boolean).pop() ?? "";
      const candidate = typeof req.query.date === "string"
        ? req.query.date
        : pathSegment;
      const date = /^\d{4}-\d{2}-\d{2}$/.test(candidate) ? candidate : "latest";
      const docRef = db.doc(`router_rundowns/${date}`);
      const snap = await docRef.get();
      if (!snap.exists) {
        res.status(404).json({ error: "not_found", date });
        return;
      }
      res.set("Cache-Control", "public, max-age=300, s-maxage=300");
      res.status(200).json(snap.data());
    } catch (err) {
      console.error("[latestRouterRundown] failed", err);
      res.status(500).json({ error: "internal" });
    }
  }
);
