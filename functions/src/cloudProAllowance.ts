/**
 * @fileoverview Cloud Pro prepaid allowance reservation callables.
 */

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "./adminRuntime.js";
import { getConfig } from "./config.js";
import { enforceAuthAndAppCheck } from "./auth.js";
import { wrapCallableHandler } from "./logging.js";
import {
  allowanceDocPath,
  CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
  CLOUD_PRO_INCLUDED_HOSTED_ACTIONS_MONTHLY,
  CLOUD_PRO_INCLUDED_RELAY_GB_MONTHLY,
  CLOUD_PRO_MONTHLY_HOSTED_ACTION_CAP,
  CLOUD_PRO_MONTHLY_RELAY_GB_CAP,
  defaultsForAllowanceMeter,
  evaluateCloudProAllowanceReservation,
  monthKeyForDate,
  type CloudProAllowanceMeter,
} from "./cloudProAllowanceCore.js";
import {
  assertActiveBurnBarCloudProEntitlement,
  boundedTrimmedString,
  requiredIdentifier,
} from "./callables/shared.js";

interface ReserveAllowanceRequest {
  sessionId?: unknown;
  reservationId?: unknown;
  actionCount?: unknown;
  relayGB?: unknown;
}

interface ReserveAllowanceResponse {
  monthKey: string;
  reservationId: string;
  meter: CloudProAllowanceMeter;
  requestedUnits: number;
  usedAfter: number;
  availableUnitsBefore: number;
  monthlyCapRemainingBefore: number;
  idempotent: boolean;
}

function numericUnits(raw: unknown, fieldName: string, options: { integer: boolean; max: number }): number {
  const value = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(value) || value <= 0 || value > options.max) {
    throw new HttpsError("invalid-argument", `${fieldName} must be greater than 0 and at most ${options.max}.`);
  }
  if (options.integer && !Number.isInteger(value)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an integer.`);
  }
  return value;
}

function numberFromDoc(raw: FirebaseFirestore.DocumentData | undefined, field: string, fallback: number): number {
  const value = raw?.[field];
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function reservationDocumentID(meter: CloudProAllowanceMeter, sessionId: string, reservationId: string | undefined) {
  const scoped = reservationId ?? sessionId;
  return requiredIdentifier(`${meter}_${scoped}`, "reservationId");
}

function allowanceFieldNames(meter: CloudProAllowanceMeter): {
  included: string;
  used: string;
  topUp: string;
  cap: string;
} {
  if (meter === "relay_gb") {
    return {
      included: "includedRelayGB",
      used: "relayGBUsed",
      topUp: "topupRelayGBPurchased",
      cap: "monthlyRelayGBCap",
    };
  }
  return {
    included: "includedHostedActions",
    used: "hostedActionsUsed",
    topUp: "topupActionsPurchased",
    cap: "monthlyHostedActionCap",
  };
}

async function reserveCloudProAllowance(args: {
  uid: string;
  meter: CloudProAllowanceMeter;
  sessionId: string;
  reservationId?: string;
  requestedUnits: number;
}): Promise<ReserveAllowanceResponse> {
  const monthKey = monthKeyForDate(new Date());
  const allowanceRef = db.doc(allowanceDocPath(args.uid, monthKey));
  const reservationDocID = reservationDocumentID(args.meter, args.sessionId, args.reservationId);
  const reservationRef = allowanceRef.collection("reservations").doc(reservationDocID);
  const fields = allowanceFieldNames(args.meter);
  const defaults = defaultsForAllowanceMeter(args.meter);

  return db.runTransaction(async (transaction) => {
    const existingReservation = await transaction.get(reservationRef);
    if (existingReservation.exists) {
      const existing = existingReservation.data();
      const requestedUnits = numberFromDoc(existing, "requestedUnits", args.requestedUnits);
      return {
        monthKey,
        reservationId: reservationDocID,
        meter: args.meter,
        requestedUnits,
        usedAfter: numberFromDoc(existing, "usedAfter", requestedUnits),
        availableUnitsBefore: numberFromDoc(existing, "availableUnitsBefore", 0),
        monthlyCapRemainingBefore: numberFromDoc(existing, "monthlyCapRemainingBefore", 0),
        idempotent: true,
      };
    }

    const allowance = await transaction.get(allowanceRef);
    const data = allowance.data();
    const snapshot = {
      includedUnits: numberFromDoc(data, fields.included, defaults.includedUnits),
      usedUnits: numberFromDoc(data, fields.used, defaults.usedUnits),
      topUpUnits: numberFromDoc(data, fields.topUp, defaults.topUpUnits),
      monthlyCap: numberFromDoc(data, fields.cap, defaults.monthlyCap),
    };
    const evaluation = evaluateCloudProAllowanceReservation({
      ...snapshot,
      requestedUnits: args.requestedUnits,
    });

    if (!evaluation.ok) {
      throw new HttpsError(
        "resource-exhausted",
        evaluation.reason === "monthly_cap_exceeded"
          ? "Cloud Pro monthly cap reached for this meter."
          : "Cloud Pro prepaid allowance is exhausted for this meter.",
        {
          meter: args.meter,
          monthKey,
          requestedUnits: args.requestedUnits,
          availableUnits: evaluation.availableUnits,
          monthlyCapRemaining: evaluation.monthlyCapRemaining,
          reason: evaluation.reason,
        },
      );
    }

    const now = Timestamp.now();
    transaction.set(
      allowanceRef,
      {
        includedHostedActions: CLOUD_PRO_INCLUDED_HOSTED_ACTIONS_MONTHLY,
        includedRelayGB: CLOUD_PRO_INCLUDED_RELAY_GB_MONTHLY,
        hostedActionsUsed:
          args.meter === "hosted_actions" ? FieldValue.increment(args.requestedUnits) : FieldValue.increment(0),
        relayGBUsed: args.meter === "relay_gb" ? FieldValue.increment(args.requestedUnits) : FieldValue.increment(0),
        topupActionsPurchased: FieldValue.increment(0),
        topupRelayGBPurchased: FieldValue.increment(0),
        monthlyHostedActionCap: CLOUD_PRO_MONTHLY_HOSTED_ACTION_CAP,
        monthlyRelayGBCap: CLOUD_PRO_MONTHLY_RELAY_GB_CAP,
        updatedAt: now,
        schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
      },
      { merge: true },
    );
    transaction.set(reservationRef, {
      uid: args.uid,
      monthKey,
      meter: args.meter,
      sessionId: args.sessionId,
      reservationId: reservationDocID,
      requestedUnits: args.requestedUnits,
      availableUnitsBefore: evaluation.availableUnits,
      monthlyCapRemainingBefore: evaluation.monthlyCapRemaining,
      usedAfter: evaluation.usedAfter,
      createdAt: now,
      schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
    });

    return {
      monthKey,
      reservationId: reservationDocID,
      meter: args.meter,
      requestedUnits: args.requestedUnits,
      usedAfter: evaluation.usedAfter,
      availableUnitsBefore: evaluation.availableUnits,
      monthlyCapRemainingBefore: evaluation.monthlyCapRemaining,
      idempotent: false,
    };
  });
}

export const reserveAgentControlActionBudget = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("reserveAgentControlActionBudget", async (request: CallableRequest<ReserveAllowanceRequest>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before reserving Agent Control budget.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarCloudProEntitlement(uid);
    const sessionId = boundedTrimmedString(request.data.sessionId, "sessionId", 256, true);
    const reservationId = boundedTrimmedString(request.data.reservationId, "reservationId", 256, false);
    const requestedUnits = numericUnits(request.data.actionCount, "actionCount", { integer: true, max: 100 });
    return reserveCloudProAllowance({
      uid,
      meter: "hosted_actions",
      sessionId,
      reservationId,
      requestedUnits,
    });
  }),
);

export const reserveFlooRelayBudget = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("reserveFlooRelayBudget", async (request: CallableRequest<ReserveAllowanceRequest>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before reserving Floo relay budget.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarCloudProEntitlement(uid);
    const sessionId = boundedTrimmedString(request.data.sessionId, "sessionId", 256, true);
    const reservationId = boundedTrimmedString(request.data.reservationId, "reservationId", 256, false);
    const requestedUnits = numericUnits(request.data.relayGB, "relayGB", { integer: false, max: 50 });
    return reserveCloudProAllowance({
      uid,
      meter: "relay_gb",
      sessionId,
      reservationId,
      requestedUnits,
    });
  }),
);
