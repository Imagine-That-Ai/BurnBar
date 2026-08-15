/**
 * @fileoverview Usage-memory curation token allowance — transactional Firestore counters.
 *
 * Ledger shape (server-written ONLY, via the Admin SDK — firestore.rules never
 * grants client access to this collection, so no rules change is needed):
 *
 *   users/{uid}/usageCurationAllowance/{monthKey}
 *     { schemaVersion, textTokensUsed, multimodalTokensUsed,
 *       textTokensUsedToday, multimodalTokensUsedToday, dayKey, updatedAt }
 *
 *   users/{uid}/usageCurationAllowance/{monthKey}/reservations/{reservationId}
 *     { uid, monthKey, dayKey, lane, reservationId, estimatedTokens,
 *       settledTokens?, status: "reserved" | "settled", createdAt, updatedAt,
 *       schemaVersion }
 *
 * COPIES the cloudProAllowance reservation pattern: reserve(estimate) inside a
 * transaction BEFORE the cloud call (fail-closed — no reservation, no spend),
 * settle(actual) after, idempotent by reservation doc id in both directions.
 * The daily meter resets by comparing `dayKey` INSIDE the transaction — no
 * scheduled job; a rollover simply zeroes both lanes' daily counters before the
 * new reservation applies. Monthly reset is structural (a new monthKey doc).
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { monthKeyForDate } from "../cloudProAllowanceCore.js";
import {
  USAGE_CURATION_SCHEMA_VERSION,
  dayKeyForDate,
  evaluateUsageCurationReservation,
  nextDailyResetISO,
  nextMonthlyResetISO,
  type UsageCurationLane,
  type UsageCurationLaneLimits,
} from "./limits.js";

export function usageCurationAllowanceDocPath(uid: string, monthKey: string): string {
  return `users/${uid}/usageCurationAllowance/${monthKey}`;
}

export function usageCurationReservationDocPath(uid: string, monthKey: string, reservationId: string): string {
  return `${usageCurationAllowanceDocPath(uid, monthKey)}/reservations/${reservationId}`;
}

export type UsageCurationReservationStatus = "reserved" | "settled";

/** Live counters after a reserve/settle, with any dayKey rollover already applied. */
export interface UsageCurationAllowanceCounters {
  monthKey: string;
  dayKey: string;
  textTokensUsed: number;
  multimodalTokensUsed: number;
  textTokensUsedToday: number;
  multimodalTokensUsedToday: number;
}

export interface UsageCurationReserveResult extends UsageCurationAllowanceCounters {
  reservationId: string;
  estimatedTokens: number;
  idempotent: boolean;
  reservationStatus: UsageCurationReservationStatus;
}

export interface UsageCurationSettleResult extends UsageCurationAllowanceCounters {
  reservationId: string;
  settledTokens: number;
  deltaTokens: number;
  idempotent: boolean;
}

function counterNumber(raw: FirebaseFirestore.DocumentData | undefined, field: string): number {
  const value = raw?.[field];
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0;
}

function laneMonthlyUsed(counters: UsageCurationAllowanceCounters, lane: UsageCurationLane): number {
  return lane === "text" ? counters.textTokensUsed : counters.multimodalTokensUsed;
}

function laneDailyUsed(counters: UsageCurationAllowanceCounters, lane: UsageCurationLane): number {
  return lane === "text" ? counters.textTokensUsedToday : counters.multimodalTokensUsedToday;
}

/** Apply a token delta to one lane's monthly + (optionally) daily counters, clamped at ≥ 0. */
function withLaneDelta(
  counters: UsageCurationAllowanceCounters,
  lane: UsageCurationLane,
  deltaTokens: number,
  options: { applyDaily: boolean },
): UsageCurationAllowanceCounters {
  const isText = lane === "text";
  const dailyDelta = options.applyDaily ? deltaTokens : 0;
  return {
    ...counters,
    textTokensUsed: Math.max(0, counters.textTokensUsed + (isText ? deltaTokens : 0)),
    multimodalTokensUsed: Math.max(0, counters.multimodalTokensUsed + (isText ? 0 : deltaTokens)),
    textTokensUsedToday: Math.max(0, counters.textTokensUsedToday + (isText ? dailyDelta : 0)),
    multimodalTokensUsedToday: Math.max(0, counters.multimodalTokensUsedToday + (isText ? 0 : dailyDelta)),
  };
}

/**
 * Read the allowance doc's counters, applying the in-transaction daily reset:
 * a stored `dayKey` that differs from `dayKey` zeroes BOTH lanes' daily counters.
 */
function countersFromDoc(
  data: FirebaseFirestore.DocumentData | undefined,
  monthKey: string,
  dayKey: string,
): UsageCurationAllowanceCounters {
  const sameDay = data?.dayKey === dayKey;
  return {
    monthKey,
    dayKey,
    textTokensUsed: counterNumber(data, "textTokensUsed"),
    multimodalTokensUsed: counterNumber(data, "multimodalTokensUsed"),
    textTokensUsedToday: sameDay ? counterNumber(data, "textTokensUsedToday") : 0,
    multimodalTokensUsedToday: sameDay ? counterNumber(data, "multimodalTokensUsedToday") : 0,
  };
}

function allowanceDocWrite(counters: UsageCurationAllowanceCounters, now: Timestamp): Record<string, unknown> {
  return {
    schemaVersion: USAGE_CURATION_SCHEMA_VERSION,
    textTokensUsed: counters.textTokensUsed,
    multimodalTokensUsed: counters.multimodalTokensUsed,
    textTokensUsedToday: counters.textTokensUsedToday,
    multimodalTokensUsedToday: counters.multimodalTokensUsedToday,
    dayKey: counters.dayKey,
    updatedAt: now,
  };
}

/**
 * Reserve `estimatedTokens` on one lane before the cloud call.
 *
 * Idempotent by `reservationId`: replaying the same reservation (same uid,
 * lane, estimate) returns the stored outcome WITHOUT a second deduction — the
 * caller must inspect `reservationStatus` and refuse to place a NEW cloud call
 * on an already-settled reservation (otherwise a replayed id would buy
 * unmetered inference). The same id with different parameters is rejected
 * (`already-exists`) so a client cannot mutate a priced reservation in place.
 * On shortfall throws `resource-exhausted` with details `{ lane, resetsAt }` —
 * `resetsAt` names the boundary that actually unblocks the caller (next UTC
 * midnight for a daily shortfall, first of next UTC month for a monthly one).
 */
export async function reserveUsageCurationTokens(args: {
  uid: string;
  lane: UsageCurationLane;
  reservationId: string;
  estimatedTokens: number;
  limits: UsageCurationLaneLimits;
  now?: Date;
}): Promise<UsageCurationReserveResult> {
  const now = args.now ?? new Date();
  const monthKey = monthKeyForDate(now);
  const dayKey = dayKeyForDate(now);
  const allowanceRef = db.doc(usageCurationAllowanceDocPath(args.uid, monthKey));
  const reservationRef = db.doc(usageCurationReservationDocPath(args.uid, monthKey, args.reservationId));

  return db.runTransaction(async (transaction) => {
    const existingSnap = await transaction.get(reservationRef);
    if (existingSnap.exists) {
      const existing = existingSnap.data() ?? {};
      if (
        existing.uid !== args.uid ||
        existing.lane !== args.lane ||
        existing.estimatedTokens !== args.estimatedTokens
      ) {
        throw new HttpsError("already-exists", "reservationId was already used for a different curation reservation.", {
          lane: args.lane,
          monthKey,
          reservationId: args.reservationId,
        });
      }
      const allowanceSnap = await transaction.get(allowanceRef);
      return {
        ...countersFromDoc(allowanceSnap.data(), monthKey, dayKey),
        reservationId: args.reservationId,
        estimatedTokens: args.estimatedTokens,
        idempotent: true,
        reservationStatus: existing.status === "settled" ? ("settled" as const) : ("reserved" as const),
      };
    }

    const allowanceSnap = await transaction.get(allowanceRef);
    const counters = countersFromDoc(allowanceSnap.data(), monthKey, dayKey);
    const evaluation = evaluateUsageCurationReservation({
      requestedTokens: args.estimatedTokens,
      monthlyUsed: laneMonthlyUsed(counters, args.lane),
      dailyUsed: laneDailyUsed(counters, args.lane),
      limits: args.limits,
    });
    if (!evaluation.ok) {
      if (evaluation.reason === "invalid_request") {
        throw new HttpsError("invalid-argument", "estimatedTokens must be a positive integer.");
      }
      const daily = evaluation.reason === "daily_exhausted";
      throw new HttpsError(
        "resource-exhausted",
        daily
          ? `Daily usage-curation token allowance is exhausted for the ${args.lane} lane.`
          : `Monthly usage-curation token allowance is exhausted for the ${args.lane} lane.`,
        {
          lane: args.lane,
          resetsAt: daily ? nextDailyResetISO(now) : nextMonthlyResetISO(now),
          reason: evaluation.reason,
          monthlyRemaining: evaluation.monthlyRemaining,
          dailyRemaining: evaluation.dailyRemaining,
        },
      );
    }

    const next = withLaneDelta(counters, args.lane, args.estimatedTokens, { applyDaily: true });
    const nowStamp = Timestamp.now();
    // Explicit counter writes (not FieldValue.increment): the transaction read
    // already owns the doc, and the dayKey rollover must be able to REPLACE the
    // daily counters rather than add to a stale day's total.
    transaction.set(allowanceRef, allowanceDocWrite(next, nowStamp), { merge: true });
    transaction.set(reservationRef, {
      uid: args.uid,
      monthKey,
      dayKey,
      lane: args.lane,
      reservationId: args.reservationId,
      estimatedTokens: args.estimatedTokens,
      status: "reserved",
      createdAt: nowStamp,
      updatedAt: nowStamp,
      schemaVersion: USAGE_CURATION_SCHEMA_VERSION,
    });
    return {
      ...next,
      reservationId: args.reservationId,
      estimatedTokens: args.estimatedTokens,
      idempotent: false,
      reservationStatus: "reserved" as const,
    };
  });
}

/**
 * Settle a reservation with the ACTUAL token count after the cloud call.
 *
 * Applies `actual - estimated` to the lane's monthly counter (clamped at ≥ 0)
 * and to the daily counter only while the allowance doc is still on the
 * reservation's dayKey (a rollover between reserve and settle makes the old
 * day's counter moot). Never throws resource-exhausted — the spend already
 * happened; an under-estimate overage lands in the counters and fail-closes
 * the NEXT reservation instead. Idempotent: settling an already-settled
 * reservation is a no-op that returns the live counters.
 */
export async function settleUsageCurationTokens(args: {
  uid: string;
  lane: UsageCurationLane;
  reservationId: string;
  monthKey: string;
  actualTokens: number;
}): Promise<UsageCurationSettleResult> {
  if (!Number.isFinite(args.actualTokens) || !Number.isInteger(args.actualTokens) || args.actualTokens < 0) {
    throw new HttpsError("invalid-argument", "actualTokens must be a non-negative integer.");
  }
  const allowanceRef = db.doc(usageCurationAllowanceDocPath(args.uid, args.monthKey));
  const reservationRef = db.doc(usageCurationReservationDocPath(args.uid, args.monthKey, args.reservationId));

  return db.runTransaction(async (transaction) => {
    const reservationSnap = await transaction.get(reservationRef);
    const reservation = reservationSnap.data();
    if (!reservationSnap.exists || !reservation) {
      throw new HttpsError("failed-precondition", "Cannot settle a curation reservation that was never reserved.", {
        lane: args.lane,
        monthKey: args.monthKey,
        reservationId: args.reservationId,
      });
    }
    if (reservation.uid !== args.uid || reservation.lane !== args.lane) {
      throw new HttpsError("failed-precondition", "Curation reservation does not match the settling caller.", {
        lane: args.lane,
        monthKey: args.monthKey,
        reservationId: args.reservationId,
      });
    }

    const allowanceSnap = await transaction.get(allowanceRef);
    const allowanceData = allowanceSnap.data();
    // Counters keyed to the STORED dayKey: settle must not roll the day
    // forward — only reserve does that — so a same-day settle adjusts today's
    // counters and a cross-midnight settle leaves the fresh day untouched.
    const liveDayKey = typeof allowanceData?.dayKey === "string" ? allowanceData.dayKey : dayKeyForDate(new Date());
    const counters = countersFromDoc(allowanceData, args.monthKey, liveDayKey);

    if (reservation.status === "settled") {
      const settledTokens =
        typeof reservation.settledTokens === "number" ? reservation.settledTokens : args.actualTokens;
      return {
        ...counters,
        reservationId: args.reservationId,
        settledTokens,
        deltaTokens: 0,
        idempotent: true,
      };
    }

    const estimatedTokens = counterNumber(reservation, "estimatedTokens");
    const deltaTokens = args.actualTokens - estimatedTokens;
    const next = withLaneDelta(counters, args.lane, deltaTokens, {
      applyDaily: reservation.dayKey === liveDayKey,
    });
    const nowStamp = Timestamp.now();
    transaction.set(allowanceRef, allowanceDocWrite(next, nowStamp), { merge: true });
    transaction.set(
      reservationRef,
      {
        status: "settled",
        settledTokens: args.actualTokens,
        updatedAt: nowStamp,
      },
      { merge: true },
    );
    return {
      ...next,
      reservationId: args.reservationId,
      settledTokens: args.actualTokens,
      deltaTokens,
      idempotent: false,
    };
  });
}
