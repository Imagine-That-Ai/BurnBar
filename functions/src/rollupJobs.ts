/**
 * @fileoverview Rollup job state: the full-rebuild attempt gate / circuit
 * breaker, failure bookkeeping, the client-facing refresh callable core, and
 * the rollup-doc writer that clears the dirty flag.
 */

import { randomUUID } from "node:crypto";
import { FieldValue, type DocumentData, type Firestore } from "firebase-admin/firestore";
import type { RollupJobDoc, UsageRollupDoc } from "./types.js";
import { errorMessage, parseRollupJobDoc } from "./guards.js";
import { getConfig } from "./config.js";
import { logError } from "./logging.js";
import { WINDOW_KEYS, stripUndefinedDocument, type WindowKey } from "./rollupCounters.js";
import { computeUserRollups, computeUserRollupsFromCounters } from "./rollupCompute.js";
import { drainPendingCounterDeltas } from "./rollupPendingDeltas.js";

/**
 * Reads the rollup job's current `dirtiedAt` marker.
 *
 * Callers capture this BEFORE computing rollups and pass it to
 * {@link writeUserRollups}, which only clears the dirty flag when the marker
 * is unchanged — i.e. no usage event landed while the compute was running.
 */
export async function readRollupJobDirtiedAt(db: Firestore, uid: string): Promise<string | undefined> {
  const snap = await db.doc(`users/${uid}/rollup_jobs/current`).get();
  const job = snap.exists ? parseRollupJobDoc(snap.data()) : undefined;
  return job?.dirtiedAt;
}

// ---------------------------------------------------------------------------
// Full-rebuild attempt gate (P0-7)
//
// The destructive repair path (recursiveDelete of four counter collections +
// a full raw-usage rescan) used to account for failures only in an in-process
// catch handler, so a timeout/OOM-killed invocation never advanced the
// circuit breaker: the worker re-deleted and re-died every 5 minutes forever.
// The gate below persists an attempt marker transactionally BEFORE the
// expensive work begins.
//
// Invariant: every full-rebuild attempt is preceded by a marker write, and
// the marker is cleared only by the success path (writeUserRollups with
// `clearFullRebuildAttempt`) or the in-process failure path
// (recordRollupRebuildFailure). A killed invocation therefore leaves the
// marker behind; once it is stale the next pass counts it as a consecutive
// failure — the breaker advances even when no catch handler ever ran. A
// still-fresh marker doubles as an in-flight dedupe: no second destructive
// rebuild starts while one may still be running.
// ---------------------------------------------------------------------------

/**
 * An in-flight marker older than this is a killed attempt. Must exceed
 * rebuildRollups' timeoutSeconds (540 s, scheduled.ts) plus scheduler slack so
 * an attempt still inside its own invocation window is never miscounted.
 */
export const FULL_REBUILD_ATTEMPT_STALE_MS = 12 * 60 * 1000;

/** lastErrorCode recorded when a stale marker is counted: the killed attempt
 * may have deleted the counters before dying mid-scan, so they must stay
 * marked untrusted and route the next pass through the repair path. */
const FULL_REBUILD_KILLED_ERROR_CODE = "full_rebuild_attempt_killed";

type FullRebuildGateOptions = {
  maxConsecutiveFullRebuildFailures: number;
  circuitBreakerMinutes: number;
  /** Defaults to {@link FULL_REBUILD_ATTEMPT_STALE_MS}. */
  staleAttemptMillis?: number;
  /** Set for client `force` rebuilds: enforces the per-user cooldown. */
  forceMinIntervalMillis?: number;
};

type FullRebuildAttemptGate =
  | { status: "started"; countedStaleAttempt: boolean }
  | { status: "circuit_open"; openUntil: string }
  | { status: "in_flight"; attemptStartedAt: string }
  | { status: "force_cooldown"; retryAt: string };

/** Thrown by {@link refreshUserRollups} when the gate refuses a full rebuild;
 * the callable maps `reason` onto a typed HttpsError. */
export class RollupRebuildUnavailableError extends Error {
  constructor(
    readonly reason: "circuit_open" | "in_flight" | "force_cooldown",
    readonly retryAt?: string,
  ) {
    super(
      reason === "circuit_open"
        ? `Usage counter repair is paused${retryAt ? ` until ${retryAt}` : ""} after repeated failures.`
        : reason === "in_flight"
          ? "A usage counter rebuild is already running for this user."
          : `Forced rebuilds are rate limited; retry${retryAt ? ` after ${retryAt}` : " later"}.`,
    );
    this.name = "RollupRebuildUnavailableError";
  }
}

/**
 * Stale-marker accounting: a still-fresh in-flight marker is an in_flight
 * refusal; a stale (or absent-but-finite) one is counted as a consecutive
 * failure and re-stamped so the breaker advances on the next pass.
 */
type StaleAttemptResolution = {
  inFlight?: { status: "in_flight"; attemptStartedAt: string };
  countedStaleAttempt: boolean;
  failures: number;
  stalePatch: DocumentData;
};

function resolveStaleAttempt(
  job: RollupJobDoc | undefined,
  options: FullRebuildGateOptions,
  nowMillis: number,
): StaleAttemptResolution {
  const staleAttemptMillis = options.staleAttemptMillis ?? FULL_REBUILD_ATTEMPT_STALE_MS;
  const attemptStartedAt = job?.fullRebuildAttemptInFlightAt;
  const attemptStartedAtMillis = attemptStartedAt != null ? Date.parse(attemptStartedAt) : Number.NaN;
  if (attemptStartedAt != null && Number.isFinite(attemptStartedAtMillis)) {
    if (nowMillis - attemptStartedAtMillis < staleAttemptMillis) {
      return {
        inFlight: { status: "in_flight", attemptStartedAt },
        countedStaleAttempt: false,
        failures: 0,
        stalePatch: {},
      };
    }
  }
  const countedStaleAttempt = Number.isFinite(attemptStartedAtMillis);
  const failures = (job?.consecutiveFullRebuildFailures ?? 0) + (countedStaleAttempt ? 1 : 0);
  const stalePatch: DocumentData = countedStaleAttempt
    ? {
        consecutiveFullRebuildFailures: failures,
        lastErrorCode: job?.lastErrorCode ?? FULL_REBUILD_KILLED_ERROR_CODE,
        fullRebuildAttemptInFlightAt: FieldValue.delete(),
      }
    : {};
  return { countedStaleAttempt, failures, stalePatch };
}

/** A circuit that is still open returns its terminal result; otherwise undefined. */
function resolveOpenCircuit(
  job: RollupJobDoc | undefined,
  nowMillis: number,
): { status: "circuit_open"; openUntil: string } | undefined {
  const openUntil = job?.fullRebuildCircuitOpenUntil;
  const openUntilMillis = openUntil != null ? Date.parse(openUntil) : Number.NaN;
  if (openUntil != null && Number.isFinite(openUntilMillis) && openUntilMillis > nowMillis) {
    return { status: "circuit_open", openUntil };
  }
  return undefined;
}

/** A force rebuild still inside its cooldown returns its terminal result. */
function resolveForceCooldown(
  job: RollupJobDoc | undefined,
  options: FullRebuildGateOptions,
  nowMillis: number,
): { status: "force_cooldown"; retryAt: string } | undefined {
  if (typeof options.forceMinIntervalMillis !== "number") return undefined;
  const lastForceAtMillis = job?.lastForceRebuildAt != null ? Date.parse(job.lastForceRebuildAt) : Number.NaN;
  if (Number.isFinite(lastForceAtMillis) && nowMillis - lastForceAtMillis < options.forceMinIntervalMillis) {
    return {
      status: "force_cooldown",
      retryAt: new Date(lastForceAtMillis + options.forceMinIntervalMillis).toISOString(),
    };
  }
  return undefined;
}

/**
 * Transactionally claims the right to run a full counter rebuild for `uid`.
 * See the section comment above for the marker/breaker invariant.
 */
export async function beginFullRebuildAttempt(
  db: Firestore,
  uid: string,
  options: FullRebuildGateOptions,
): Promise<FullRebuildAttemptGate> {
  const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);

  return db.runTransaction(async (transaction) => {
    const snap = await transaction.get(jobRef);
    const job = snap.exists ? parseRollupJobDoc(snap.data()) : undefined;
    const nowMillis = Date.now();

    // parseRollupJobDoc rejects docs without a boolean `dirty`, so every gate
    // write must keep one: without this, a gate-created doc for a brand-new
    // user (or a corrupt doc) parses to undefined on the NEXT pass and its
    // attempt marker turns invisible — no in-flight dedupe, and a killed
    // attempt never advances the breaker.
    const ensureParseable = { dirty: job?.dirty ?? false };

    const stale = resolveStaleAttempt(job, options, nowMillis);
    if (stale.inFlight) return stale.inFlight;
    const { countedStaleAttempt, failures, stalePatch } = stale;
    const setStalePatch = (): void => {
      if (countedStaleAttempt) {
        transaction.set(jobRef, { ...ensureParseable, ...stalePatch }, { merge: true });
      }
    };

    const openCircuit = resolveOpenCircuit(job, nowMillis);
    if (openCircuit) {
      setStalePatch();
      return openCircuit;
    }

    if (countedStaleAttempt && failures >= options.maxConsecutiveFullRebuildFailures) {
      const reopenedUntil = new Date(nowMillis + options.circuitBreakerMinutes * 60 * 1000).toISOString();
      transaction.set(
        jobRef,
        { ...ensureParseable, ...stalePatch, fullRebuildCircuitOpenUntil: reopenedUntil },
        { merge: true },
      );
      return { status: "circuit_open", openUntil: reopenedUntil };
    }

    const forceCooldown = resolveForceCooldown(job, options, nowMillis);
    if (forceCooldown) {
      setStalePatch();
      return forceCooldown;
    }

    const startPatch: DocumentData = {
      ...ensureParseable,
      ...stalePatch,
      fullRebuildAttemptInFlightAt: new Date(nowMillis).toISOString(),
    };
    if (typeof options.forceMinIntervalMillis === "number") {
      startPatch.lastForceRebuildAt = new Date(nowMillis).toISOString();
    }
    transaction.set(jobRef, startPatch, { merge: true });
    return { status: "started", countedStaleAttempt };
  });
}

/**
 * Failure-path bookkeeping shared by the scheduled worker and the refresh
 * callable. Only failures of the full-rebuild repair path advance the
 * consecutive counter (a first cheap-path failure merely records
 * `lastErrorCode` to route the NEXT pass to repair — the worker's original
 * rule), and the breaker opens once the counter reaches the configured
 * maximum. When the caller's failed attempt went through the gate
 * (`clearAttemptMarker`, the default), its in-flight marker is cleared here
 * because this failure is being counted now; leaving it would double-count
 * the attempt as a stale kill on the next pass. Callers whose failure came
 * from the CHEAP path pass `clearAttemptMarker: false` — they never wrote a
 * marker, and clearing one would hide a concurrent full rebuild's kill from
 * the breaker.
 */
export async function recordRollupRebuildFailure(
  db: Firestore,
  uid: string,
  errorCode: string,
  options: {
    maxConsecutiveFullRebuildFailures: number;
    circuitBreakerMinutes: number;
    clearAttemptMarker?: boolean;
  },
): Promise<{ breakerOpened: boolean }> {
  const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
  return db.runTransaction(async (transaction) => {
    const snap = await transaction.get(jobRef);
    const job = snap.exists ? parseRollupJobDoc(snap.data()) : undefined;
    const wasFullRebuildFailure = job?.lastErrorCode != null;
    const consecutiveFullRebuildFailures = wasFullRebuildFailure
      ? (job?.consecutiveFullRebuildFailures ?? 0) + 1
      : FieldValue.delete();
    const breakerShouldOpen =
      typeof consecutiveFullRebuildFailures === "number" &&
      consecutiveFullRebuildFailures >= options.maxConsecutiveFullRebuildFailures;
    const attemptPatch =
      options.clearAttemptMarker === false ? {} : { fullRebuildAttemptInFlightAt: FieldValue.delete() };
    transaction.set(
      jobRef,
      {
        // Keep the doc parseable for the gate (see beginFullRebuildAttempt).
        dirty: job?.dirty ?? false,
        lastErrorCode: errorCode,
        consecutiveFullRebuildFailures,
        fullRebuildCircuitOpenUntil: breakerShouldOpen
          ? new Date(Date.now() + options.circuitBreakerMinutes * 60 * 1000).toISOString()
          : FieldValue.delete(),
        ...attemptPatch,
      },
      { merge: true },
    );
    return { breakerOpened: breakerShouldOpen };
  });
}

function fullRebuildGateOptionsFromConfig(): FullRebuildGateOptions {
  const cfg = getConfig();
  return {
    maxConsecutiveFullRebuildFailures: cfg.rollupMaxConsecutiveFullRebuildFailures,
    circuitBreakerMinutes: cfg.rollupFullRebuildCircuitBreakerMinutes,
  };
}

type RefreshUserRollupsResult = {
  rollups: Record<WindowKey, UsageRollupDoc>;
  rebuiltCounters: boolean;
};

type RollupUserRebuildSkipReason =
  | "not_dirty"
  | "stale_dirty_epoch"
  | "full_rebuild_circuit_open"
  | "full_rebuild_in_flight";

type RollupUserRebuildProcessResult =
  | { status: "processed"; uid: string; rebuiltCounters: boolean; keepDirty?: boolean }
  | {
      status: "skipped";
      uid: string;
      reason: RollupUserRebuildSkipReason;
      taskDirtiedAt?: string;
      currentDirtiedAt?: string;
    };

/** Runs the gated full-rebuild path for {@link refreshUserRollups}. */
async function refreshViaFullRebuild(
  db: Firestore,
  uid: string,
  job: RollupJobDoc | undefined,
  options: { force?: boolean; gate?: Partial<FullRebuildGateOptions> },
): Promise<Record<WindowKey, UsageRollupDoc>> {
  // Every full-rebuild entry point — explicit `force` repair included — goes
  // through the attempt gate: it enforces the circuit breaker the scheduled
  // worker honors (the callable used to bypass it entirely), dedupes
  // concurrent rebuilds via the in-flight marker, and rate-limits force
  // repairs per user. A rebuild killed mid-flight here is counted by the next
  // pass through the stale marker, exactly like the worker's.
  const cfg = getConfig();
  const gateOptions = {
    ...fullRebuildGateOptionsFromConfig(),
    forceMinIntervalMillis: options.force === true ? cfg.rollupForceRebuildMinIntervalMinutes * 60 * 1000 : undefined,
    ...options.gate,
  };
  const gate = await beginFullRebuildAttempt(db, uid, gateOptions);
  if (gate.status === "circuit_open") {
    throw new RollupRebuildUnavailableError("circuit_open", gate.openUntil);
  }
  if (gate.status === "in_flight") {
    throw new RollupRebuildUnavailableError("in_flight");
  }
  if (gate.status === "force_cooldown") {
    throw new RollupRebuildUnavailableError("force_cooldown", gate.retryAt);
  }
  try {
    const rollups = await computeUserRollups(db, uid);
    await writeUserRollups(db, uid, rollups, job?.dirtiedAt, { clearFullRebuildAttempt: true });
    return rollups;
  } catch (err) {
    // In-process failure bookkeeping, mirroring the scheduled worker's catch:
    // record the failure (advancing the consecutive counter / breaker) and
    // clear this attempt's in-flight marker NOW. Without this, the marker
    // dangles until it goes stale — every retry inside that window is refused
    // as "in_flight" with nothing running, and the failure itself goes
    // uncounted until the stale-marker pass.
    await recordRollupRebuildFailure(db, uid, errorMessage(err), gateOptions).catch(() => undefined);
    throw err;
  }
}

/**
 * Serves a client-initiated rollup refresh (the `rebuildUsageRollups`
 * callable) without unconditionally paying for a full counter rebuild.
 *
 * The full path ({@link computeUserRollups}) recursively deletes all three
 * counter collections and rescans the user's entire usage history, so it only
 * runs when the counters cannot be trusted: an explicit `force` (the clients'
 * repair entry point), a missing/unparseable job doc, or a recorded
 * incremental-delta failure (`lastErrorCode`) — the same fallback rule as the
 * scheduled `rebuildRollups` worker. Otherwise the incrementally maintained
 * counters already include every usage event (dirty merely means the rollup
 * docs lag the counters), so a counters-only recompute is sufficient.
 *
 * The recomputed rollups are ALWAYS written, even when nothing changed:
 * clients treat a stale `computedAt` as a rebuild signal, so serving without
 * refreshing it would put an open dashboard into a callable polling loop.
 */
export async function refreshUserRollups(
  db: Firestore,
  uid: string,
  options: { force?: boolean; gate?: Partial<FullRebuildGateOptions>; drainMaxPages?: number } = {},
): Promise<RefreshUserRollupsResult> {
  const jobSnap = await db.doc(`users/${uid}/rollup_jobs/current`).get();
  const job = jobSnap.exists ? parseRollupJobDoc(jobSnap.data()) : undefined;
  const rebuiltCounters = options.force === true || job == null || job.lastErrorCode != null;
  let rollups: Record<WindowKey, UsageRollupDoc>;
  if (rebuiltCounters) {
    rollups = await refreshViaFullRebuild(db, uid, job, options);
  } else {
    // Fold queued trigger deltas into the counters first so the served
    // rollups include every event enqueued up to this point. A drain failure
    // propagates: the dirty flag survives and the scheduled worker (whose
    // catch records `lastErrorCode`) repairs via the full-rebuild path.
    const drain = await drainPendingCounterDeltas(db, uid, {
      maxPages: options.drainMaxPages ?? getConfig().rollupPendingDeltaDrainMaxPages,
    });
    rollups = await computeUserRollupsFromCounters(db, uid);
    await writeUserRollups(db, uid, rollups, job?.dirtiedAt, { keepDirty: drain.capped });
  }
  return { rollups, rebuiltCounters };
}

export function shouldProcessRollupUserRebuildTask(
  job: RollupJobDoc | undefined,
  taskDirtiedAt: string | undefined,
): { process: true } | { process: false; reason: "not_dirty" | "stale_dirty_epoch"; currentDirtiedAt?: string } {
  if (job?.dirty !== true) {
    return { process: false, reason: "not_dirty", currentDirtiedAt: job?.dirtiedAt };
  }
  if (taskDirtiedAt !== undefined && job.dirtiedAt !== taskDirtiedAt) {
    return { process: false, reason: "stale_dirty_epoch", currentDirtiedAt: job.dirtiedAt };
  }
  return { process: true };
}

/**
 * Rebuilds one user's dirty usage rollups. This is shared by the Cloud Tasks
 * worker and any future direct repair path so the delta drain, full-rebuild
 * gate, and dirty-epoch clear semantics stay identical.
 */
export async function processRollupUserRebuild(
  db: Firestore,
  uid: string,
  options: { taskDirtiedAt?: string } = {},
): Promise<RollupUserRebuildProcessResult> {
  const {
    rollupRepairPageSize,
    rollupMaxConsecutiveFullRebuildFailures,
    rollupFullRebuildCircuitBreakerMinutes,
    rollupPendingDeltaDrainMaxPages,
  } = getConfig();
  let claimedFullRebuildGate = false;
  try {
    const jobSnap = await db.doc(`users/${uid}/rollup_jobs/current`).get();
    const job = jobSnap.exists ? parseRollupJobDoc(jobSnap.data()) : undefined;
    const taskState = shouldProcessRollupUserRebuildTask(job, options.taskDirtiedAt);
    if (!taskState.process) {
      return {
        status: "skipped",
        uid,
        reason: taskState.reason,
        taskDirtiedAt: options.taskDirtiedAt,
        currentDirtiedAt: taskState.currentDirtiedAt,
      };
    }

    const needsFullRebuild = job?.lastErrorCode != null;
    if (needsFullRebuild) {
      const gate = await beginFullRebuildAttempt(db, uid, {
        maxConsecutiveFullRebuildFailures: rollupMaxConsecutiveFullRebuildFailures,
        circuitBreakerMinutes: rollupFullRebuildCircuitBreakerMinutes,
      });
      if (gate.status === "circuit_open") {
        logError({
          event: "rollup.full_rebuild_circuit_open",
          uid,
          error: `full rebuild paused until ${gate.openUntil}`,
        });
        return {
          status: "skipped",
          uid,
          reason: "full_rebuild_circuit_open",
          taskDirtiedAt: options.taskDirtiedAt,
          currentDirtiedAt: job?.dirtiedAt,
        };
      }
      if (gate.status !== "started") {
        return {
          status: "skipped",
          uid,
          reason: "full_rebuild_in_flight",
          taskDirtiedAt: options.taskDirtiedAt,
          currentDirtiedAt: job?.dirtiedAt,
        };
      }
      claimedFullRebuildGate = true;
      const rollups = await computeUserRollups(db, uid, { repairPageSize: rollupRepairPageSize });
      await writeUserRollups(db, uid, rollups, job?.dirtiedAt, { clearFullRebuildAttempt: true });
      return { status: "processed", uid, rebuiltCounters: true };
    }

    const drain = await drainPendingCounterDeltas(db, uid, { maxPages: rollupPendingDeltaDrainMaxPages });
    const rollups = await computeUserRollupsFromCounters(db, uid);
    await writeUserRollups(db, uid, rollups, job?.dirtiedAt, { keepDirty: drain.capped });
    return { status: "processed", uid, rebuiltCounters: false, keepDirty: drain.capped };
  } catch (err) {
    logError({ event: "rollup.rebuild_failed", uid, error: errorMessage(err) });
    await recordRollupRebuildFailure(db, uid, errorMessage(err), {
      maxConsecutiveFullRebuildFailures: rollupMaxConsecutiveFullRebuildFailures,
      circuitBreakerMinutes: rollupFullRebuildCircuitBreakerMinutes,
      clearAttemptMarker: claimedFullRebuildGate,
    });
    throw err;
  }
}

export async function writeUserRollups(
  db: Firestore,
  uid: string,
  rollups: Record<WindowKey, UsageRollupDoc>,
  observedDirtiedAt: string | undefined,
  options: { keepDirty?: boolean; clearFullRebuildAttempt?: boolean } = {},
): Promise<void> {
  const batch = db.batch();

  for (const key of WINDOW_KEYS) {
    const ref = db.doc(`users/${uid}/usage_rollups/${key}`);
    // `mergeFields`, not `merge: true`. `dailyProviderTokens` is a sparse nested
    // map, and a correction that drops a provider/day to zero OMITS that key
    // rather than zeroing it — under a deep merge Firestore keeps the previous
    // nested keys, so the profile shows a provider split for tokens that no
    // longer exist. Listing the computed fields replaces each of them wholesale
    // (killing stale nested keys) while still leaving any field this writer does
    // not own untouched, and it stays ONE write per document.
    const payload = stripUndefinedDocument(rollups[key]);
    batch.set(ref, payload, { mergeFields: Object.keys(payload) });
  }

  await batch.commit();

  // Clear the dirty flag transactionally, and only when `dirtiedAt` still
  // matches the value the caller observed at compute start. Every usage event
  // refreshes `dirtiedAt` (see onUsageWritten), so a mismatch means an event
  // landed mid-compute and the rollups just written may not include it: leave
  // the job dirty so the next worker pass recomputes instead of silently
  // dropping the event. Error/breaker state is cleared only when this same
  // dirty epoch was covered; a newer dirty epoch may have recorded its own
  // failure and must survive so the next worker pass takes the repair path.
  //
  // `keepDirty`: a capped delta drain left queue docs behind — clearing dirty
  // would orphan them until the next usage event, so the job stays dirty for
  // the next tick. Rotate `requeueNonce` with that surviving dirty marker so
  // the scheduler creates a fresh Cloud Task instead of colliding with the
  // completed dirty-epoch task name. `clearFullRebuildAttempt`: only the
  // caller that ran the full rebuild clears its own in-flight marker; clearing
  // unconditionally would let a racing cheap-path write erase another
  // invocation's marker and hide its kill from the breaker (see
  // beginFullRebuildAttempt).
  const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
  await db.runTransaction(async (transaction) => {
    const snap = await transaction.get(jobRef);
    const job = snap.exists ? parseRollupJobDoc(snap.data()) : undefined;
    const lastComputedAt = new Date().toISOString();
    const attemptPatch = options.clearFullRebuildAttempt ? { fullRebuildAttemptInFlightAt: FieldValue.delete() } : {};
    const successPatch = {
      lastComputedAt,
      lastErrorCode: FieldValue.delete(),
      consecutiveFullRebuildFailures: FieldValue.delete(),
      fullRebuildCircuitOpenUntil: FieldValue.delete(),
    };
    if (!options.keepDirty && job?.dirtiedAt === observedDirtiedAt) {
      transaction.set(
        jobRef,
        { dirty: false, requeueNonce: FieldValue.delete(), ...successPatch, ...attemptPatch },
        { merge: true },
      );
    } else {
      transaction.set(
        jobRef,
        {
          lastComputedAt,
          ...(options.keepDirty ? { dirty: true, requeueNonce: randomUUID() } : {}),
          ...attemptPatch,
        },
        { merge: true },
      );
    }
  });
}
