/**
 * Anti-fingerprinting bucketing for the backend analytics stream.
 *
 * Raw counts/durations/amounts are never sent; they map to coarse, canonical
 * buckets identical on every platform. Boundaries are ported VERBATIM from
 * `AgentLens/Services/Analytics/AnalyticsBuckets.swift` and
 * `website/src/lib/analytics/buckets.ts`, and mirrored in
 * `docs/analytics/event-taxonomy.md` — the four must stay byte-identical.
 */

export function bucketDurationMs(ms: number): string {
  const n = Math.round(ms);
  if (n < 100) return "<100ms";
  if (n < 500) return "100-500ms";
  if (n < 1_000) return "500ms-1s";
  if (n < 3_000) return "1-3s";
  if (n < 10_000) return "3-10s";
  if (n < 30_000) return "10-30s";
  return ">30s";
}

export function bucketCount(n: number): string {
  if (n < 1) return "0"; // 0 and negatives clamp to "0"
  if (n === 1) return "1";
  if (n <= 5) return "2-5";
  if (n <= 20) return "6-20";
  if (n <= 100) return "21-100";
  if (n <= 500) return "101-500";
  return ">500";
}

export function bucketAmountUSD(usd: number): string {
  if (usd <= 0) return "0";
  if (usd < 1) return "<1";
  if (usd < 10) return "1-10";
  if (usd < 50) return "10-50";
  if (usd < 100) return "50-100";
  if (usd < 500) return "100-500";
  return ">500";
}

export function bucketPercent(p: number): string {
  if (p < 10) return "0-10";
  if (p < 25) return "10-25";
  if (p < 50) return "25-50";
  if (p < 75) return "50-75";
  if (p < 90) return "75-90";
  return "90-100";
}

export function bucketSizeBytes(b: number): string {
  if (b < 1_000) return "<1KB";
  if (b < 100_000) return "1-100KB";
  if (b < 1_000_000) return "100KB-1MB";
  if (b < 10_000_000) return "1-10MB";
  if (b < 100_000_000) return "10-100MB";
  return ">100MB";
}

export function bucketDurationSeconds(s: number): string {
  if (s < 5) return "<5s";
  if (s < 30) return "5-30s";
  if (s < 120) return "30s-2m";
  if (s < 600) return "2-10m";
  if (s < 3_600) return "10-60m";
  return ">60m";
}
