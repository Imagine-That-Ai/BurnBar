/**
 * @fileoverview Shared in-flight marker for a full usage-counter rebuild.
 *
 * Cheap pending-delta drains and the refresh/worker entry points must agree
 * on "a rescan may still be replacing counters" so a mid-scan event cannot
 * be applied onto docs the rebuild is about to delete.
 */

import type { RollupJobDoc } from "./types.js";

/**
 * An in-flight marker older than this is a killed attempt. Must exceed
 * rebuildRollups' timeoutSeconds (540 s, scheduled.ts) plus scheduler slack so
 * an attempt still inside its own invocation window is never miscounted.
 */
export const FULL_REBUILD_ATTEMPT_STALE_MS = 12 * 60 * 1000;

/** Fresh in-flight marker: a full rebuild may still be replacing counters. */
export function isFreshFullRebuildInFlight(
  job: RollupJobDoc | undefined,
  nowMillis = Date.now(),
  staleAttemptMillis = FULL_REBUILD_ATTEMPT_STALE_MS,
): boolean {
  const attemptStartedAt = job?.fullRebuildAttemptInFlightAt;
  const attemptStartedAtMillis = attemptStartedAt != null ? Date.parse(attemptStartedAt) : Number.NaN;
  return Number.isFinite(attemptStartedAtMillis) && nowMillis - attemptStartedAtMillis < staleAttemptMillis;
}
