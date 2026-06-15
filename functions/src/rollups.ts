/**
 * @fileoverview Usage rollup computation.
 *
 * Maintains compact daily usage counters, computes per-window aggregates, and
 * writes `usage_rollups/{windowKey}` documents. The scheduled path reads only
 * counter documents; raw usage scans are reserved for explicit repair/backfill.
 *
 * The implementation is split across cohesive sibling modules; this file is the
 * stable barrel preserving every existing `from "./rollups.js"` import:
 *   - rollupCounters.ts     — counter primitives + single-event transition
 *   - rollupPendingDeltas.ts — contention-free pending-delta queue + drain
 *   - rollupCompute.ts      — counters -> usage_rollups + full-rebuild repair
 *   - rollupJobs.ts         — attempt gate / breaker, refresh callable, writer
 */

export { applyUsageCounterDelta } from "./rollupCounters.js";
export type { WindowKey, UsageCounterContribution, UsageCounterCandidate } from "./rollupCounters.js";

export {
  isPendingCounterDelta,
  buildPendingCounterDelta,
  pendingCounterDeltaDocID,
  enqueueUsageCounterDelta,
  planPendingDeltaDrain,
  drainPendingCounterDeltas,
} from "./rollupPendingDeltas.js";
export type { PendingCounterDelta } from "./rollupPendingDeltas.js";

export { computeUserRollups, computeUserRollupsFromCounters, rebuildUserRollupCounters } from "./rollupCompute.js";

export {
  readRollupJobDirtiedAt,
  FULL_REBUILD_ATTEMPT_STALE_MS,
  RollupRebuildUnavailableError,
  beginFullRebuildAttempt,
  recordRollupRebuildFailure,
  refreshUserRollups,
  writeUserRollups,
} from "./rollupJobs.js";
