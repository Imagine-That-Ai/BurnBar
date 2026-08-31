import type { UsageRollup } from "@/lib/usage";

/**
 * Whether the profile page should force a `rebuildUsageRollups` pass.
 *
 * A missing document is the original first-sync case. A *present but empty*
 * `all_time` document is the more common lie: the cheap scheduled path can
 * write zeros before any device has published usage, and a pre-v3 document
 * can exist with lifetime totals but no harness/combo/provider-day split.
 * Both look "live" to a naive exists() check and leave the page sitting on
 * a truthful-looking zero forever.
 */
export function needsProfileRebuild(candidate: UsageRollup | null): boolean {
  if (!candidate) return true;

  const hasActivity =
    candidate.dailyPoints.length > 0 || candidate.totals.tokens > 0;
  if (!hasActivity) return true;

  const hasV3Breakdown =
    Object.keys(candidate.dailyProviderTokens).length > 0 ||
    candidate.comboSummaries.length > 0 ||
    candidate.executionSourceSummaries.length > 0;
  return !hasV3Breakdown;
}
