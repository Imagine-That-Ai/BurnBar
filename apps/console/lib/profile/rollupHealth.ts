import type { UsageRollup } from "@/lib/usage";

/**
 * Whether the profile should kick a *full* `rebuildUsageRollups({ force: true })`.
 *
 * A missing doc, or a pre-v3 `all_time` doc (lifetime activity but no
 * execution-source / combo / per-day provider split), cannot be repaired by
 * the cheap counters-only path — those counters were never written.
 */
export function profileRollupNeedsFullRebuild(rollup: UsageRollup | null): boolean {
  if (!rollup) return true;
  const hasActivity = rollup.dailyPoints.length > 0 || rollup.totals.tokens > 0;
  if (!hasActivity) return false;
  const hasV3Breakdown =
    Object.keys(rollup.dailyProviderTokens).length > 0 ||
    rollup.comboSummaries.length > 0 ||
    rollup.executionSourceSummaries.length > 0;
  return !hasV3Breakdown;
}

type RebuildErrorDetails = {
  reason?: string;
  retryAt?: string;
};

function errorCode(err: unknown): string {
  if (err && typeof err === "object" && "code" in err) {
    return String((err as { code: unknown }).code);
  }
  return "";
}

function errorMessage(err: unknown): string {
  if (err instanceof Error && err.message.trim()) return err.message;
  if (err && typeof err === "object" && "message" in err) {
    const message = (err as { message?: unknown }).message;
    if (typeof message === "string" && message.trim()) return message;
  }
  return "";
}

function errorDetails(err: unknown): RebuildErrorDetails | undefined {
  if (!err || typeof err !== "object" || !("details" in err)) return undefined;
  const details = (err as { details?: unknown }).details;
  if (!details || typeof details !== "object") return undefined;
  const record = details as RebuildErrorDetails;
  return {
    reason: typeof record.reason === "string" ? record.reason : undefined,
    retryAt: typeof record.retryAt === "string" ? record.retryAt : undefined,
  };
}

/**
 * Map a `rebuildUsageRollups` refusal/failure onto a sentence the profile
 * can show. Gate refusals (`circuit_open` / `in_flight` / `force_cooldown`)
 * are expected control flow; a timeout/OOM is the 2026-09-19 production
 * failure mode (60s / 256MiB envelope).
 */
export function rebuildUsageErrorMessage(err: unknown): string {
  const code = errorCode(err);
  const details = errorDetails(err);
  const reason = details?.reason;
  const retryAt = details?.retryAt;
  const message = errorMessage(err);

  if (reason === "circuit_open" || code.endsWith("/unavailable")) {
    return retryAt
      ? `Usage repair is paused until ${retryAt} after repeated failures.`
      : "Usage repair is paused after repeated failures. Try again in an hour.";
  }
  if (reason === "in_flight" || code.endsWith("/aborted")) {
    return "A usage rebuild is already running. This page fills in when it finishes.";
  }
  if (reason === "force_cooldown" || code.endsWith("/resource-exhausted")) {
    return retryAt
      ? `A full rebuild just ran. Try again after ${retryAt}.`
      : "A full rebuild just ran. Try again in a few minutes.";
  }
  if (
    code.endsWith("/deadline-exceeded") ||
    /timeout|memory limit|out of memory/i.test(message)
  ) {
    return "Usage rebuild ran out of time or memory. Refresh in a minute — a background repair may still be running.";
  }
  return message || "Could not rebuild usage.";
}
