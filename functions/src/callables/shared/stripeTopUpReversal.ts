/**
 * @fileoverview Pure validation and arithmetic for Stripe top-up reversals.
 */

import { HttpsError } from "firebase-functions/v2/https";

import { type CloudProAllowanceMeter } from "../../cloudProAllowanceCore.js";

export type StripeTopUpDisputeStatus =
  | "warning_needs_response"
  | "warning_under_review"
  | "warning_closed"
  | "needs_response"
  | "under_review"
  | "won"
  | "lost"
  | "prevented";

interface StripeTopUpReceiptState {
  monthKey: string;
  units: number;
  meter: CloudProAllowanceMeter;
  priorRefundUnits: number;
  priorDisputeUnits: number;
  priorReversedUnits: number;
}

function nonNegativeInteger(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  return Math.max(0, Math.floor(value));
}

function isCloudProAllowanceMeter(value: unknown): value is CloudProAllowanceMeter {
  return value === "hosted_actions" || value === "relay_gb" || value === "fusion_searches";
}

export function proportionalTopUpReversalUnits(
  units: number,
  refundedAmountMinor: number,
  originalAmountMinor: number,
): number {
  if (refundedAmountMinor <= 0) return 0;
  if (originalAmountMinor <= 0) return units;
  const ratio = Math.min(1, refundedAmountMinor / originalAmountMinor);
  return Math.min(units, Math.ceil(units * ratio));
}

export function disputeTopUpReversalUnits(units: number, status: StripeTopUpDisputeStatus): number {
  switch (status) {
    case "won":
    case "warning_closed":
    case "prevented":
      return 0;
    case "warning_needs_response":
    case "warning_under_review":
    case "needs_response":
    case "under_review":
    case "lost":
      return units;
  }
}

export function stripeTopUpReceiptState(receipt: Record<string, unknown>): StripeTopUpReceiptState {
  const monthKey = typeof receipt.firstMonthKey === "string" ? receipt.firstMonthKey : undefined;
  const units = nonNegativeInteger(receipt.units) ?? 0;
  const meter = receipt.meter;
  if (!monthKey || units <= 0 || !isCloudProAllowanceMeter(meter)) {
    throw new HttpsError("failed-precondition", "Cloud Pro top-up receipt is incomplete and cannot be reconciled.");
  }

  const priorRefundUnits = nonNegativeInteger(receipt.refundReversedUnits) ?? 0;
  const priorDisputeUnits = nonNegativeInteger(receipt.disputeReversedUnits) ?? 0;
  const storedReversedUnits = nonNegativeInteger(receipt.reversedUnits);
  const priorReversedUnits =
    storedReversedUnits === undefined
      ? Math.max(priorRefundUnits, priorDisputeUnits)
      : Math.min(units, storedReversedUnits);
  return {
    monthKey,
    units,
    meter,
    priorRefundUnits,
    priorDisputeUnits,
    priorReversedUnits,
  };
}

export function stripeTopUpAmount(provided: unknown, stored: unknown): number {
  return nonNegativeInteger(provided) ?? nonNegativeInteger(stored) ?? 0;
}

export function stripeTopUpIncrementField(meter: CloudProAllowanceMeter): string {
  if (meter === "relay_gb") return "topupRelayGBPurchased";
  if (meter === "fusion_searches") return "topupFusionSearchesPurchased";
  return "topupActionsPurchased";
}

export function stripeTopUpReversalState(reversedUnits: number, units: number): "reversed" | "partial" | "active" {
  if (reversedUnits >= units) return "reversed";
  if (reversedUnits > 0) return "partial";
  return "active";
}
