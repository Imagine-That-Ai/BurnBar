import type { QuotaSnapshotDoc } from "./types.js";
import { logInfo } from "./logging.js";
import { QuotaRefreshPolicy, type QuotaRefreshWindowKind } from "./quotaRefreshPolicy.js";

export function quotaSnapshotAgeMsBucket(fetchedAt: string | undefined, now: Date = new Date()): string {
  if (!fetchedAt) return "unknown";
  const fetchedAtMs = Date.parse(fetchedAt);
  if (!Number.isFinite(fetchedAtMs)) return "unknown";
  const ageMs = now.getTime() - fetchedAtMs;
  if (ageMs < 0) return "future";
  if (ageMs < 60_000) return "<1m";
  if (ageMs < 5 * 60_000) return "1-5m";
  if (ageMs < 20 * 60_000) return "5-20m";
  if (ageMs < 60 * 60_000) return "20-60m";
  if (ageMs < 4 * 60 * 60_000) return "1-4h";
  return ">=4h";
}

export function emitQuotaSnapshotWritten(snapshot: QuotaSnapshotDoc, now: Date): void {
  logInfo({
    event: "quota.snapshot_written",
    provider: snapshot.providerID ?? snapshot.provider,
    source: snapshot.sourceKind,
    age_ms_bucket: quotaSnapshotAgeMsBucket(snapshot.fetchedAt, now),
  });
}

export function quotaAccountRefreshMetadata(snapshot: QuotaSnapshotDoc, now: Date): Record<string, unknown> {
  const buckets = Array.isArray(snapshot.buckets) ? snapshot.buckets : [];
  let remainingFraction: number | null = null;
  let windowKind: QuotaRefreshWindowKind = "custom";
  let resetsAt: string | null = snapshot.resetAt ?? null;

  for (const bucket of buckets) {
    const limit = typeof bucket.limit === "number" && Number.isFinite(bucket.limit) ? bucket.limit : undefined;
    const remaining =
      typeof bucket.remaining === "number" && Number.isFinite(bucket.remaining) ? bucket.remaining : undefined;
    if (limit !== undefined && limit > 0 && remaining !== undefined) {
      const candidate = Math.min(Math.max(remaining / limit, 0), 1);
      remainingFraction = remainingFraction === null ? candidate : Math.min(remainingFraction, candidate);
    }
    if (!resetsAt) {
      const resetCandidate = bucket.resetAt ?? bucket.resetsAt;
      if (typeof resetCandidate === "string") {
        resetsAt = resetCandidate;
      }
    }
    if (windowKind === "custom") {
      windowKind = quotaWindowKindFromBucket(bucket.window);
    }
  }

  let quotaNextRefreshAt: string;
  try {
    quotaNextRefreshAt = QuotaRefreshPolicy.nextRefreshAfter(
      {
        fetchedAt: snapshot.fetchedAt,
        remainingFraction,
        windowKind,
        resetsAt,
      },
      now,
    ).toISOString();
  } catch {
    quotaNextRefreshAt = now.toISOString();
  }

  return {
    quotaSnapshotFetchedAt: snapshot.fetchedAt,
    quotaRemainingFraction: remainingFraction,
    quotaWindowKind: windowKind,
    quotaResetsAt: resetsAt,
    quotaNextRefreshAt,
  };
}

function quotaWindowKindFromBucket(window: unknown): QuotaRefreshWindowKind {
  if (typeof window !== "string") return "custom";
  const normalized = window.toLowerCase();
  if (normalized.includes("hour") || normalized.endsWith("h")) return "rollingHours";
  if (normalized.includes("day") || normalized.endsWith("d")) return "rollingDays";
  if (normalized.includes("week")) return "weekly";
  if (normalized.includes("month")) return "monthly";
  if (normalized.includes("life")) return "lifetime";
  return "custom";
}
