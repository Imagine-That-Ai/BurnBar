/**
 * @fileoverview Public model-landscape benchmark normalization.
 *
 * The adapters in this module use documented APIs or cached/manual fixtures
 * only. They intentionally do not scrape private or authenticated dashboard
 * pages. Benchmark data is advisory metadata for routing explanations; account
 * auth, quota, availability, and user pinning remain hard constraints.
 */

import type { Firestore } from "firebase-admin/firestore";
import type {
  ModelBenchmarkSnapshotDoc,
  ModelBenchmarkSource,
  ModelBenchmarkSourceStatusDoc,
  ModelBenchmarkTaskCategory,
  ProviderID,
} from "./types.js";

const SNAPSHOT_SCHEMA_VERSION = 1;
const STATUS_SCHEMA_VERSION = 1;
const ARTIFICIAL_ANALYSIS_URL = "https://artificialanalysis.ai/api/v2/data/llms/models";
const TERMINAL_BENCH_HF_LEADERBOARD_URL =
  "https://huggingface.co/api/datasets/harborframework/terminal-bench-2.0/leaderboard";

type UnknownRecord = Record<string, unknown>;

export interface ModelLandscapeRefreshResult {
  snapshots: ModelBenchmarkSnapshotDoc[];
  statuses: ModelBenchmarkSourceStatusDoc[];
}

function asRecord(value: unknown): UnknownRecord | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as UnknownRecord)
    : undefined;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function clamp01(value: number | undefined): number | undefined {
  if (value == null || !Number.isFinite(value)) return undefined;
  return Math.max(0, Math.min(1, value));
}

function scoreToUnit(value: number | undefined): number | undefined {
  if (value == null) return undefined;
  return clamp01(value > 1 ? value / 100 : value);
}

function stableSnapshotID(
  source: ModelBenchmarkSource,
  modelID: string,
  taskCategory: ModelBenchmarkTaskCategory,
  fetchedAt: string
): string {
  const day = fetchedAt.slice(0, 10);
  return [source, modelID, taskCategory, day]
    .join("_")
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .slice(0, 240);
}

function providerIDFromName(value: string | undefined): ProviderID | undefined {
  if (!value) return undefined;
  return value.toLowerCase().trim().replace(/[_\s]+/g, "-");
}

function status(
  source: ModelBenchmarkSource,
  state: ModelBenchmarkSourceStatusDoc["status"],
  message: string,
  now: string,
  fetchedAt?: string,
  attribution?: string
): ModelBenchmarkSourceStatusDoc {
  return {
    source,
    status: state,
    fetchedAt,
    message,
    attribution,
    schemaVersion: STATUS_SCHEMA_VERSION,
    updatedAt: now,
  };
}

export function normalizeArtificialAnalysisModels(
  payload: unknown,
  fetchedAt: string
): ModelBenchmarkSnapshotDoc[] {
  const root = asRecord(payload);
  const rows = asArray(root?.data);
  return rows.flatMap((row): ModelBenchmarkSnapshotDoc[] => {
    const item = asRecord(row);
    if (!item) return [];
    const modelID = asString(item.slug) ?? asString(item.name) ?? asString(item.id);
    if (!modelID) return [];

    const creator = asRecord(item.model_creator);
    const providerID = providerIDFromName(asString(creator?.slug) ?? asString(creator?.name));
    const evaluations = asRecord(item.evaluations);
    const pricing = asRecord(item.pricing);
    const codingScore = scoreToUnit(asNumber(evaluations?.artificial_analysis_coding_index)
      ?? asNumber(evaluations?.livecodebench));
    const generalScore = scoreToUnit(asNumber(evaluations?.artificial_analysis_intelligence_index)
      ?? asNumber(evaluations?.mmlu_pro));
    const inputPrice = asNumber(pricing?.price_1m_input_tokens);
    const outputPrice = asNumber(pricing?.price_1m_output_tokens);
    const blended = asNumber(pricing?.price_1m_blended_3_to_1)
      ?? (inputPrice != null && outputPrice != null ? inputPrice * 0.75 + outputPrice * 0.25 : undefined);
    const costSignal = blended == null ? undefined : clamp01(1 / (1 + blended));
    const tps = asNumber(item.median_output_tokens_per_second);
    const ttft = asNumber(item.median_time_to_first_token_seconds);
    const latencySignal = tps == null && ttft == null
      ? undefined
      : clamp01((tps ?? 0) / 250 * 0.5 + (ttft == null ? 0.25 : Math.max(0, 1 - ttft / 30) * 0.5));

    const base = {
      source: "artificial_analysis" as const,
      sourceURL: ARTIFICIAL_ANALYSIS_URL,
      attribution: "Artificial Analysis",
      fetchedAt,
      modelID,
      providerID,
      costSignal,
      latencySignal,
      confidence: 0.8,
      freshness: "fresh" as const,
      schemaVersion: SNAPSHOT_SCHEMA_VERSION,
      updatedAt: fetchedAt,
    };

    return [
      {
        ...base,
        id: stableSnapshotID("artificial_analysis", modelID, "general", fetchedAt),
        taskCategory: "general" as const,
        score: generalScore,
      },
      {
        ...base,
        id: stableSnapshotID("artificial_analysis", modelID, "coding", fetchedAt),
        taskCategory: "coding" as const,
        score: codingScore,
      },
    ].filter((snapshot) => snapshot.score != null || snapshot.costSignal != null || snapshot.latencySignal != null);
  });
}

export function normalizeHuggingFaceLeaderboard(
  payload: unknown,
  fetchedAt: string,
  source: ModelBenchmarkSource = "terminal_bench"
): ModelBenchmarkSnapshotDoc[] {
  const rows = Array.isArray(payload)
    ? payload
    : asArray(asRecord(payload)?.leaderboard ?? asRecord(payload)?.data);
  return rows.flatMap((row): ModelBenchmarkSnapshotDoc[] => {
    const item = asRecord(row);
    if (!item) return [];
    const modelID = asString(item.model_id) ?? asString(item.modelId) ?? asString(item.model);
    if (!modelID) return [];
    const rank = asNumber(item.rank);
    const value = asNumber(item.value) ?? asNumber(item.score);
    return [{
      id: stableSnapshotID(source, modelID, "terminal", fetchedAt),
      source,
      sourceURL: TERMINAL_BENCH_HF_LEADERBOARD_URL,
      attribution: "Terminal-Bench / Hugging Face",
      fetchedAt,
      modelID,
      taskCategory: "terminal",
      score: scoreToUnit(value),
      rank: rank == null ? undefined : Math.trunc(rank),
      reliabilitySignal: item.verified === true ? 0.9 : 0.65,
      confidence: item.verified === true ? 0.9 : 0.65,
      freshness: "fresh",
      schemaVersion: SNAPSHOT_SCHEMA_VERSION,
      updatedAt: fetchedAt,
    }];
  });
}

export function normalizeDesignArenaFixture(
  payload: unknown,
  fetchedAt: string
): ModelBenchmarkSnapshotDoc[] {
  const rows = Array.isArray(payload)
    ? payload
    : asArray(asRecord(payload)?.data ?? asRecord(payload)?.leaderboard);
  return rows.flatMap((row): ModelBenchmarkSnapshotDoc[] => {
    const item = asRecord(row);
    if (!item) return [];
    const modelID = asString(item.modelID) ?? asString(item.model_id) ?? asString(item.name);
    if (!modelID) return [];
    const category = (asString(item.taskCategory) ?? "design") as ModelBenchmarkTaskCategory;
    return [{
      id: stableSnapshotID("design_arena", modelID, category, fetchedAt),
      source: "design_arena",
      sourceURL: asString(item.sourceURL) ?? "https://docs.designarena.ai/introduction",
      attribution: "Design Arena",
      fetchedAt,
      modelID,
      providerID: providerIDFromName(asString(item.providerID) ?? asString(item.provider)),
      taskCategory: category,
      score: scoreToUnit(asNumber(item.score) ?? asNumber(item.elo)),
      rank: asNumber(item.rank) == null ? undefined : Math.trunc(asNumber(item.rank)!),
      confidence: clamp01(asNumber(item.confidence)) ?? 0.7,
      freshness: "manual",
      schemaVersion: SNAPSHOT_SCHEMA_VERSION,
      updatedAt: fetchedAt,
    }];
  });
}

async function fetchJSON(url: string, headers: Record<string, string> = {}): Promise<unknown> {
  const response = await fetch(url, {
    method: "GET",
    headers: {
      Accept: "application/json",
      ...headers,
    },
  });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }
  return response.json();
}

export async function collectModelLandscapeBenchmarks(
  env: NodeJS.ProcessEnv = process.env,
  now: Date = new Date()
): Promise<ModelLandscapeRefreshResult> {
  const fetchedAt = now.toISOString();
  const snapshots: ModelBenchmarkSnapshotDoc[] = [];
  const statuses: ModelBenchmarkSourceStatusDoc[] = [];

  const artificialAnalysisKey = env.ARTIFICIAL_ANALYSIS_API_KEY?.trim();
  if (artificialAnalysisKey) {
    try {
      const payload = await fetchJSON(ARTIFICIAL_ANALYSIS_URL, { "x-api-key": artificialAnalysisKey });
      const normalized = normalizeArtificialAnalysisModels(payload, fetchedAt);
      snapshots.push(...normalized);
      statuses.push(status(
        "artificial_analysis",
        normalized.length > 0 ? "fresh" : "stale",
        `Normalized ${normalized.length} Artificial Analysis benchmark rows.`,
        fetchedAt,
        fetchedAt,
        "Artificial Analysis"
      ));
    } catch (err) {
      statuses.push(status("artificial_analysis", "error", `Artificial Analysis refresh failed: ${(err as Error).message}`, fetchedAt));
    }
  } else {
    statuses.push(status("artificial_analysis", "unavailable", "ARTIFICIAL_ANALYSIS_API_KEY is not configured.", fetchedAt, undefined, "Artificial Analysis"));
  }

  try {
    const payload = await fetchJSON(TERMINAL_BENCH_HF_LEADERBOARD_URL);
    const normalized = normalizeHuggingFaceLeaderboard(payload, fetchedAt);
    snapshots.push(...normalized);
    statuses.push(status(
      "terminal_bench",
      normalized.length > 0 ? "fresh" : "stale",
      `Normalized ${normalized.length} Terminal-Bench leaderboard rows.`,
      fetchedAt,
      fetchedAt,
      "Terminal-Bench / Hugging Face"
    ));
  } catch (err) {
    statuses.push(status("terminal_bench", "error", `Terminal-Bench refresh failed: ${(err as Error).message}`, fetchedAt, undefined, "Terminal-Bench / Hugging Face"));
  }

  const designFixture = env.DESIGN_ARENA_FIXTURE_JSON?.trim();
  if (designFixture) {
    try {
      const normalized = normalizeDesignArenaFixture(JSON.parse(designFixture), fetchedAt);
      snapshots.push(...normalized);
      statuses.push(status(
        "design_arena",
        "fresh",
        `Normalized ${normalized.length} Design Arena fixture rows.`,
        fetchedAt,
        fetchedAt,
        "Design Arena"
      ));
    } catch (err) {
      statuses.push(status("design_arena", "error", `Design Arena fixture failed: ${(err as Error).message}`, fetchedAt, undefined, "Design Arena"));
    }
  } else {
    statuses.push(status(
      "design_arena",
      "unavailable",
      "Design Arena API access requires an approved key; no fixture is configured, so the adapter is idle.",
      fetchedAt,
      undefined,
      "Design Arena"
    ));
  }

  const manualFixture = env.MODEL_LANDSCAPE_MANUAL_FIXTURES_JSON?.trim();
  if (manualFixture) {
    try {
      const normalized = normalizeDesignArenaFixture(JSON.parse(manualFixture), fetchedAt).map((snapshot) => ({
        ...snapshot,
        id: stableSnapshotID("manual_fixture", snapshot.modelID, snapshot.taskCategory, fetchedAt),
        source: "manual_fixture" as const,
        sourceURL: snapshot.sourceURL ?? "manual",
        attribution: snapshot.attribution ?? "Manual OpenBurnBar fixture",
        freshness: "manual" as const,
      }));
      snapshots.push(...normalized);
      statuses.push(status("manual_fixture", "fresh", `Normalized ${normalized.length} manual fixture rows.`, fetchedAt, fetchedAt, "Manual OpenBurnBar fixture"));
    } catch (err) {
      statuses.push(status("manual_fixture", "error", `Manual fixture failed: ${(err as Error).message}`, fetchedAt));
    }
  }

  return { snapshots, statuses };
}

export async function writeModelLandscapeBenchmarks(
  db: Firestore,
  result: ModelLandscapeRefreshResult
): Promise<void> {
  const batch = db.batch();
  for (const snapshot of result.snapshots.slice(0, 400)) {
    batch.set(db.doc(`model_benchmark_snapshots/${snapshot.id}`), snapshot, { merge: true });
  }
  for (const sourceStatus of result.statuses) {
    batch.set(db.doc(`model_benchmark_source_status/${sourceStatus.source}`), sourceStatus, { merge: true });
  }
  await batch.commit();
}
