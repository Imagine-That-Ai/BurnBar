import type { MemoryLane, MemoryPackId, MemoryPackSource } from "./catalog.js";

export class MemoryWalletInsufficientError extends Error {
  readonly lane: MemoryLane;
  readonly requested: number;
  readonly available: number;

  constructor(lane: MemoryLane, requested: number, available: number) {
    super(`Insufficient ${lane} memory credits: requested ${requested}, available ${available}.`);
    this.name = "MemoryWalletInsufficientError";
    this.lane = lane;
    this.requested = requested;
    this.available = available;
  }
}

type MemoryGrantStatus = "active" | "pending" | "expired" | "exhausted" | "revoked";

interface MemoryWalletBalances {
  textTokens: number;
  multimodalTokens: number;
}

interface GrantMemoryPackArgs {
  uid: string;
  source: MemoryPackSource;
  transactionId: string;
  packId: MemoryPackId;
  visionEligible: boolean;
  originalTransactionId?: string;
  amountMinor?: number;
  currency?: string;
}

interface GrantMemoryPackResult {
  granted: boolean;
  pending: boolean;
  alreadyGranted: boolean;
  packId: MemoryPackId;
  lane: MemoryLane;
  tokens: number;
  remainingTokens: number;
  status: MemoryGrantStatus;
}

interface ReverseMemoryPackGrantArgs {
  uid: string;
  source: MemoryPackSource;
  transactionId: string;
  originalTransactionId?: string;
  refundedAmountMinor?: number;
  originalAmountMinor?: number;
  disputeStatus?: "open" | "lost" | "won" | "prevented" | "closed";
  fullReversal?: boolean;
  /** Apple REFUND_REVERSED / Stripe refund cancel: clear this grant's refund clawback. */
  restoreRefund?: boolean;
  /** Apple REFUND: claw back this grant via refundReversedTokens, restorable later. */
  refundFull?: boolean;
}

export type {
  GrantMemoryPackArgs,
  GrantMemoryPackResult,
  MemoryGrantStatus,
  MemoryWalletBalances,
  ReverseMemoryPackGrantArgs,
};
