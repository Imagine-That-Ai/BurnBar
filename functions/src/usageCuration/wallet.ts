/**
 * @fileoverview Transaction-safe memory Power-Up wallet.
 *
 * Fable's usage-curation spend callable should call {@link debitWallet} and
 * {@link getWalletBalances} *inside the same Firestore transaction* that
 * meters curation spend. This module never opens a nested transaction for
 * those two functions.
 *
 * Invariants:
 *  - Refunds/revokes touch only this grant's remaining tokens. They cannot
 *    steal another pack.
 *  - The `memoryWallet/current` cache is always rewritten as the sum of
 *    unexpired remaining tokens in the same transaction (no increment drift).
 *  - Debit replay of the same `reservationId` is success.
 *  - Insufficient balance throws {@link MemoryWalletInsufficientError}, not
 *    `HttpsError`, so webhooks do not see callable error types.
 *  - Lazy expiry runs inside the caller's transaction.
 */

import { Timestamp, type DocumentReference, type Transaction } from "firebase-admin/firestore";

import { db } from "../adminRuntime.js";
import { stripUndefinedObject } from "../guards.js";
import { requiredIdentifier } from "../callables/shared/validators.js";
import { proportionalTopUpReversalUnits } from "../callables/shared/stripeTopUpReversal.js";
import {
  DEFAULT_MEMORY_PACKS,
  MEMORY_PACK_SCHEMA_VERSION,
  MEMORY_PACK_TTL_MS,
  type MemoryLane,
  type MemoryPackId,
  type MemoryPackSource,
} from "./catalog.js";
import {
  memoryPackDebitLedgerId,
  memoryPackGrantEntryId,
  memoryPackTransactionDocPath,
  memoryWalletDocPath,
  memoryWalletGrantDocPath,
  memoryWalletLedgerDocPath,
} from "./paths.js";

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

export type MemoryGrantStatus = "active" | "pending" | "expired" | "exhausted" | "revoked";

export interface MemoryWalletBalances {
  textTokens: number;
  multimodalTokens: number;
}

export interface GrantMemoryPackArgs {
  uid: string;
  source: MemoryPackSource;
  transactionId: string;
  packId: MemoryPackId;
  visionEligible: boolean;
  originalTransactionId?: string;
  amountMinor?: number;
  currency?: string;
}

export interface GrantMemoryPackResult {
  granted: boolean;
  pending: boolean;
  alreadyGranted: boolean;
  packId: MemoryPackId;
  lane: MemoryLane;
  tokens: number;
  remainingTokens: number;
  status: MemoryGrantStatus;
}

export interface ReverseMemoryPackGrantArgs {
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

interface GrantRecord {
  schemaVersion: number;
  type: "grant";
  status: MemoryGrantStatus;
  source: MemoryPackSource;
  transactionId: string;
  originalTransactionId?: string;
  packId: MemoryPackId;
  lane: MemoryLane;
  tokens: number;
  spentTokens: number;
  remainingTokens: number;
  refundReversedTokens: number;
  disputeReversedTokens: number;
  reversedTokens: number;
  expiresAt: Timestamp;
  amountMinor?: number;
  currency?: string;
  createdAt: Timestamp;
  updatedAt: Timestamp;
}

const MAX_GRANTS_PER_WALLET = 400;

function nowTimestamp(): Timestamp {
  return Timestamp.now();
}

function timestampMillis(value: unknown): number {
  if (value instanceof Timestamp) return value.toMillis();
  if (value && typeof value === "object") {
    const withToMillis = value as { toMillis?: unknown; millis?: unknown };
    if (typeof withToMillis.toMillis === "function") {
      const millis = withToMillis.toMillis();
      if (typeof millis === "number" && Number.isFinite(millis)) return millis;
    }
    if (typeof withToMillis.millis === "number" && Number.isFinite(withToMillis.millis)) {
      return withToMillis.millis;
    }
  }
  return 0;
}

function nonNegativeInt(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;
  return Math.max(0, Math.floor(value));
}

function liveRemaining(grant: GrantRecord): number {
  if (grant.status === "pending") return 0;
  const reversed = Math.max(grant.refundReversedTokens, grant.disputeReversedTokens, grant.reversedTokens);
  return Math.max(0, grant.tokens - grant.spentTokens - reversed);
}

function parseGrant(id: string, raw: Record<string, unknown> | undefined): (GrantRecord & { id: string }) | undefined {
  if (!raw) return undefined;
  if (raw.type !== "grant") return undefined;
  if (raw.lane !== "text" && raw.lane !== "multimodal") return undefined;
  if (raw.packId !== "text_1m" && raw.packId !== "text_5m" && raw.packId !== "vision_1m") return undefined;
  const status = raw.status;
  if (
    status !== "active" &&
    status !== "pending" &&
    status !== "expired" &&
    status !== "exhausted" &&
    status !== "revoked"
  ) {
    return undefined;
  }
  const source = raw.source;
  if (source !== "stripe" && source !== "app_store" && source !== "google_play") return undefined;
  const tokens = nonNegativeInt(raw.tokens);
  const spentTokens = nonNegativeInt(raw.spentTokens);
  const refundReversedTokens = nonNegativeInt(raw.refundReversedTokens);
  const disputeReversedTokens = nonNegativeInt(raw.disputeReversedTokens);
  const reversedTokens = nonNegativeInt(raw.reversedTokens);
  const remainingTokens = nonNegativeInt(raw.remainingTokens);
  const transactionId = typeof raw.transactionId === "string" ? raw.transactionId : "";
  if (!transactionId || tokens <= 0) return undefined;
  return {
    id,
    schemaVersion: MEMORY_PACK_SCHEMA_VERSION,
    type: "grant",
    status,
    source,
    transactionId,
    originalTransactionId: typeof raw.originalTransactionId === "string" ? raw.originalTransactionId : undefined,
    packId: raw.packId,
    lane: raw.lane,
    tokens,
    spentTokens,
    remainingTokens,
    refundReversedTokens,
    disputeReversedTokens,
    reversedTokens,
    expiresAt: raw.expiresAt as Timestamp,
    amountMinor: typeof raw.amountMinor === "number" ? raw.amountMinor : undefined,
    currency: typeof raw.currency === "string" ? raw.currency : undefined,
    createdAt: raw.createdAt as Timestamp,
    updatedAt: raw.updatedAt as Timestamp,
  };
}

interface LoadedGrant {
  id: string;
  ref: DocumentReference;
  grant: GrantRecord;
}

async function loadGrants(transaction: Transaction, uid: string): Promise<LoadedGrant[]> {
  const walletRef = db.doc(memoryWalletDocPath(uid));
  const snap = await transaction.get(walletRef.collection("grants"));
  const loaded: LoadedGrant[] = [];
  for (const doc of snap.docs) {
    const parsed = parseGrant(doc.id, doc.data());
    if (!parsed) continue;
    const { id, ...grant } = parsed;
    loaded.push({ id, ref: doc.ref, grant });
  }
  return loaded;
}

function sweepExpired(grants: LoadedGrant[], now: Timestamp): LoadedGrant[] {
  const nowMs = timestampMillis(now);
  for (const item of grants) {
    if (item.grant.status !== "active" && item.grant.status !== "pending") continue;
    if (timestampMillis(item.grant.expiresAt) > nowMs) continue;
    item.grant.status = "expired";
    item.grant.remainingTokens = 0;
    item.grant.updatedAt = now;
  }
  return grants;
}

function persistFreshExpiries(
  transaction: Transaction,
  uid: string,
  grants: LoadedGrant[],
  now: Timestamp,
): void {
  for (const item of grants) {
    if (item.grant.status !== "expired") continue;
    if (timestampMillis(item.grant.updatedAt) !== timestampMillis(now)) continue;
    writeGrant(transaction, item);
    writeLedger(transaction, uid, `expire_${item.id}`, {
      type: "expire",
      lane: item.grant.lane,
      tokens: item.grant.tokens,
      source: item.grant.source,
      transactionId: item.grant.transactionId,
      packId: item.grant.packId,
      createdAt: now,
      schemaVersion: MEMORY_PACK_SCHEMA_VERSION,
    });
  }
}

function balancesFromGrants(grants: LoadedGrant[]): MemoryWalletBalances {
  let textTokens = 0;
  let multimodalTokens = 0;
  for (const item of grants) {
    const remaining = item.grant.status === "active" ? liveRemaining(item.grant) : 0;
    item.grant.remainingTokens = item.grant.status === "pending" ? 0 : remaining;
    if (item.grant.status === "active" && remaining > 0) {
      if (item.grant.lane === "text") textTokens += remaining;
      else multimodalTokens += remaining;
    }
  }
  return { textTokens, multimodalTokens };
}

function pendingFromGrants(grants: LoadedGrant[]): { pendingTextTokens: number; pendingMultimodalTokens: number } {
  let pendingTextTokens = 0;
  let pendingMultimodalTokens = 0;
  for (const item of grants) {
    if (item.grant.status !== "pending") continue;
    if (item.grant.lane === "text") pendingTextTokens += item.grant.tokens;
    else pendingMultimodalTokens += item.grant.tokens;
  }
  return { pendingTextTokens, pendingMultimodalTokens };
}

function writeWalletCache(transaction: Transaction, uid: string, grants: LoadedGrant[], now: Timestamp): MemoryWalletBalances {
  const balances = balancesFromGrants(grants);
  const pending = pendingFromGrants(grants);
  transaction.set(
    db.doc(memoryWalletDocPath(uid)),
    {
      schemaVersion: MEMORY_PACK_SCHEMA_VERSION,
      textTokens: balances.textTokens,
      multimodalTokens: balances.multimodalTokens,
      pendingTextTokens: pending.pendingTextTokens,
      pendingMultimodalTokens: pending.pendingMultimodalTokens,
      updatedAt: now,
    },
    { merge: true },
  );
  return balances;
}

function writeGrant(transaction: Transaction, item: LoadedGrant): void {
  transaction.set(item.ref, stripUndefinedObject({ ...item.grant }), { merge: true });
}

function writeLedger(
  transaction: Transaction,
  uid: string,
  entryId: string,
  payload: Record<string, unknown>,
): void {
  transaction.set(db.doc(memoryWalletLedgerDocPath(uid, entryId)), stripUndefinedObject(payload), { merge: true });
}

function writeMapping(
  transaction: Transaction,
  uid: string,
  source: MemoryPackSource,
  transactionId: string,
  originalTransactionId: string | undefined,
  packId: MemoryPackId,
  entryId: string,
  now: Timestamp,
): void {
  const body = {
    uid,
    source,
    transactionId,
    originalTransactionId,
    packId,
    entryId,
    updatedAt: now,
    schemaVersion: MEMORY_PACK_SCHEMA_VERSION,
  };
  transaction.set(db.doc(memoryPackTransactionDocPath(source, transactionId)), stripUndefinedObject(body), {
    merge: true,
  });
  if (originalTransactionId && originalTransactionId !== transactionId) {
    transaction.set(
      db.doc(memoryPackTransactionDocPath(source, originalTransactionId)),
      stripUndefinedObject(body),
      { merge: true },
    );
  }
}

/**
 * Spendable balances after a lazy expiry sweep. Must run inside the caller's
 * transaction so Fable's meter and this wallet stay atomic.
 */
export async function getWalletBalances(transaction: Transaction, uid: string): Promise<MemoryWalletBalances> {
  const now = nowTimestamp();
  const grants = sweepExpired(await loadGrants(transaction, uid), now);
  persistFreshExpiries(transaction, uid, grants, now);
  return writeWalletCache(transaction, uid, grants, now);
}

/**
 * FIFO debit by `expiresAt`. Replay of `reservationId` is a no-op success.
 */
export async function debitWallet(
  transaction: Transaction,
  uid: string,
  lane: MemoryLane,
  tokens: number,
  reservationId: string,
): Promise<MemoryWalletBalances> {
  if (!Number.isInteger(tokens) || tokens <= 0) {
    throw new Error("debitWallet tokens must be a positive integer.");
  }
  const debitId = memoryPackDebitLedgerId(reservationId);
  const existingDebit = await transaction.get(db.doc(memoryWalletLedgerDocPath(uid, debitId)));
  if (existingDebit.exists) {
    return getWalletBalances(transaction, uid);
  }

  const now = nowTimestamp();
  const grants = sweepExpired(await loadGrants(transaction, uid), now);
  persistFreshExpiries(transaction, uid, grants, now);
  const eligible = grants
    .filter((item) => item.grant.status === "active" && item.grant.lane === lane && liveRemaining(item.grant) > 0)
    .sort((a, b) => {
      const expires = timestampMillis(a.grant.expiresAt) - timestampMillis(b.grant.expiresAt);
      if (expires !== 0) return expires;
      return timestampMillis(a.grant.createdAt) - timestampMillis(b.grant.createdAt);
    });

  let remainingToTake = tokens;
  const takes: Array<{ item: LoadedGrant; take: number }> = [];
  for (const item of eligible) {
    if (remainingToTake <= 0) break;
    const available = liveRemaining(item.grant);
    const take = Math.min(available, remainingToTake);
    if (take <= 0) continue;
    takes.push({ item, take });
    remainingToTake -= take;
  }

  if (remainingToTake > 0) {
    const available = tokens - remainingToTake;
    throw new MemoryWalletInsufficientError(lane, tokens, available);
  }

  for (const { item, take } of takes) {
    item.grant.spentTokens += take;
    const nextRemaining = liveRemaining(item.grant);
    item.grant.remainingTokens = nextRemaining;
    if (nextRemaining === 0) item.grant.status = "exhausted";
    item.grant.updatedAt = now;
  }

  for (const item of grants) writeGrant(transaction, item);
  writeLedger(transaction, uid, debitId, {
    type: "debit",
    lane,
    tokens,
    reservationId: requiredIdentifier(reservationId, "reservationId"),
    createdAt: now,
    schemaVersion: MEMORY_PACK_SCHEMA_VERSION,
  });
  const balances = writeWalletCache(transaction, uid, grants, now);
  return balances;
}

function activateGrant(grant: GrantRecord, now: Timestamp): void {
  grant.status = "active";
  grant.remainingTokens = liveRemaining(grant);
  grant.updatedAt = now;
}

export async function grantMemoryPack(args: GrantMemoryPackArgs): Promise<GrantMemoryPackResult> {
  const pack = DEFAULT_MEMORY_PACKS[args.packId];
  const entryId = memoryPackGrantEntryId(args.source, args.transactionId);
  const uid = args.uid;
  const originalTransactionId = args.originalTransactionId ?? args.transactionId;

  return db.runTransaction(async (transaction) => {
    const grantRef = db.doc(memoryWalletGrantDocPath(uid, entryId));
    const existingSnap = await transaction.get(grantRef);
    const now = nowTimestamp();
    const grants = sweepExpired(await loadGrants(transaction, uid), now);
    persistFreshExpiries(transaction, uid, grants, now);
    const existing = parseGrant(entryId, existingSnap.data());

    if (existing) {
      let item = grants.find((g) => g.id === entryId);
      if (!item) {
        item = { id: entryId, ref: grantRef, grant: existing };
        grants.push(item);
      }
      if (
        item.grant.status === "pending" &&
        timestampMillis(item.grant.expiresAt) > timestampMillis(now) &&
        (!pack.requiresVisionEntitlement || args.visionEligible)
      ) {
        activateGrant(item.grant, now);
        writeGrant(transaction, item);
        writeLedger(transaction, uid, `settle_${entryId}`, {
          type: "grant",
          lane: pack.lane,
          tokens: pack.tokens,
          source: args.source,
          transactionId: args.transactionId,
          packId: args.packId,
          createdAt: now,
          schemaVersion: MEMORY_PACK_SCHEMA_VERSION,
        });
        writeWalletCache(transaction, uid, grants, now);
        return {
          granted: true,
          pending: false,
          alreadyGranted: false,
          packId: args.packId,
          lane: pack.lane,
          tokens: pack.tokens,
          remainingTokens: item.grant.remainingTokens,
          status: item.grant.status,
        };
      }
      return {
        granted: item.grant.status === "active",
        pending: item.grant.status === "pending",
        alreadyGranted: true,
        packId: args.packId,
        lane: pack.lane,
        tokens: pack.tokens,
        remainingTokens: item.grant.remainingTokens,
        status: item.grant.status,
      };
    }

    const liveGrantCount = grants.filter((item) => item.grant.status === "active" || item.grant.status === "pending")
      .length;
    if (liveGrantCount >= MAX_GRANTS_PER_WALLET) {
      throw new Error(`memory wallet grant cap (${MAX_GRANTS_PER_WALLET}) reached`);
    }

    const pending = pack.requiresVisionEntitlement && !args.visionEligible;
    const grant: GrantRecord = {
      schemaVersion: MEMORY_PACK_SCHEMA_VERSION,
      type: "grant",
      status: pending ? "pending" : "active",
      source: args.source,
      transactionId: args.transactionId,
      originalTransactionId,
      packId: args.packId,
      lane: pack.lane,
      tokens: pack.tokens,
      spentTokens: 0,
      remainingTokens: pending ? 0 : pack.tokens,
      refundReversedTokens: 0,
      disputeReversedTokens: 0,
      reversedTokens: 0,
      expiresAt: Timestamp.fromMillis(timestampMillis(now) + MEMORY_PACK_TTL_MS),
      amountMinor: args.amountMinor,
      currency: args.currency,
      createdAt: now,
      updatedAt: now,
    };
    const item: LoadedGrant = { id: entryId, ref: grantRef, grant };
    grants.push(item);
    writeGrant(transaction, item);
    writeMapping(transaction, uid, args.source, args.transactionId, originalTransactionId, args.packId, entryId, now);
    writeLedger(transaction, uid, pending ? `pending_${entryId}` : entryId, {
      type: pending ? "pending" : "grant",
      lane: pack.lane,
      tokens: pack.tokens,
      source: args.source,
      transactionId: args.transactionId,
      packId: args.packId,
      expiresAt: grant.expiresAt,
      unitPriceUsd: args.amountMinor !== undefined ? args.amountMinor / 100 : undefined,
      createdAt: now,
      schemaVersion: MEMORY_PACK_SCHEMA_VERSION,
    });
    writeWalletCache(transaction, uid, grants, now);
    return {
      granted: !pending,
      pending,
      alreadyGranted: false,
      packId: args.packId,
      lane: pack.lane,
      tokens: pack.tokens,
      remainingTokens: grant.remainingTokens,
      status: grant.status,
    };
  });
}

export async function settlePendingMemoryPacks(uid: string, visionEligible: boolean): Promise<number> {
  if (!visionEligible) return 0;
  return db.runTransaction(async (transaction) => {
    const now = nowTimestamp();
    const grants = sweepExpired(await loadGrants(transaction, uid), now);
    persistFreshExpiries(transaction, uid, grants, now);
    let settled = 0;
    for (const item of grants) {
      if (item.grant.status !== "pending") continue;
      activateGrant(item.grant, now);
      writeGrant(transaction, item);
      writeLedger(transaction, uid, `settle_${item.id}`, {
        type: "grant",
        lane: item.grant.lane,
        tokens: item.grant.tokens,
        source: item.grant.source,
        transactionId: item.grant.transactionId,
        packId: item.grant.packId,
        createdAt: now,
        schemaVersion: MEMORY_PACK_SCHEMA_VERSION,
      });
      settled += 1;
    }
    writeWalletCache(transaction, uid, grants, now);
    return settled;
  });
}

async function lookupUidForTransaction(
  source: MemoryPackSource,
  transactionId: string,
  originalTransactionId?: string,
): Promise<{ uid: string; entryId: string } | undefined> {
  const ids = [transactionId, originalTransactionId].filter((value): value is string => !!value);
  for (const id of ids) {
    const snap = await db.doc(memoryPackTransactionDocPath(source, id)).get();
    const data = snap.data();
    if (data && typeof data.uid === "string" && typeof data.entryId === "string") {
      return { uid: data.uid, entryId: data.entryId };
    }
  }
  return undefined;
}

function applyReversalToGrant(
  grant: GrantRecord,
  args: ReverseMemoryPackGrantArgs,
): { priorRemaining: number; nextRemaining: number } {
  const priorRemaining = liveRemaining(grant);
  if (args.restoreRefund) {
    grant.refundReversedTokens = 0;
  }
  if (args.refundFull) {
    grant.refundReversedTokens = grant.tokens;
  }
  if (args.fullReversal) {
    grant.reversedTokens = grant.tokens;
  }
  if (args.refundedAmountMinor !== undefined) {
    const originalAmount = args.originalAmountMinor ?? grant.amountMinor ?? 0;
    grant.refundReversedTokens = proportionalTopUpReversalUnits(
      grant.tokens,
      args.refundedAmountMinor,
      originalAmount,
    );
  }
  if (args.disputeStatus === "open" || args.disputeStatus === "lost") {
    grant.disputeReversedTokens = grant.tokens;
  } else if (args.disputeStatus === "won" || args.disputeStatus === "prevented" || args.disputeStatus === "closed") {
    grant.disputeReversedTokens = 0;
  }
  const nextRemaining = liveRemaining(grant);
  grant.remainingTokens = nextRemaining;
  if (grant.status === "active" && nextRemaining === 0) {
    grant.status = grant.spentTokens >= grant.tokens ? "exhausted" : "revoked";
  } else if (grant.status === "revoked" && nextRemaining > 0) {
    grant.status = "active";
  }
  return { priorRemaining, nextRemaining };
}

/**
 * Claw back only this grant's remaining tokens. Missing grants throw so the
 * webhook retries when refund-before-grant races.
 */
export async function reverseMemoryPackGrant(args: ReverseMemoryPackGrantArgs): Promise<{
  adjusted: boolean;
  clawedBack: number;
}> {
  const mapped = await lookupUidForTransaction(args.source, args.transactionId, args.originalTransactionId);
  const uid = args.uid || mapped?.uid;
  if (!uid) {
    throw new Error("memory_pack_grant_missing");
  }
  const entryId =
    mapped?.entryId ??
    memoryPackGrantEntryId(args.source, args.transactionId);

  return db.runTransaction(async (transaction) => {
    const now = nowTimestamp();
    const grants = sweepExpired(await loadGrants(transaction, uid), now);
    persistFreshExpiries(transaction, uid, grants, now);
    const item = grants.find((g) => g.id === entryId);
    if (!item) {
      throw new Error("memory_pack_grant_missing");
    }
    const { priorRemaining, nextRemaining } = applyReversalToGrant(item.grant, args);
    item.grant.updatedAt = now;
    writeGrant(transaction, item);
    const clawedBack = Math.max(0, priorRemaining - nextRemaining);
    if (clawedBack > 0 || priorRemaining !== nextRemaining) {
      writeLedger(transaction, uid, `revoke_${entryId}_${timestampMillis(now)}`, {
        type: "revoke",
        lane: item.grant.lane,
        tokens: clawedBack,
        source: item.grant.source,
        transactionId: item.grant.transactionId,
        packId: item.grant.packId,
        createdAt: now,
        schemaVersion: MEMORY_PACK_SCHEMA_VERSION,
      });
    }
    writeWalletCache(transaction, uid, grants, now);
    return { adjusted: clawedBack > 0, clawedBack };
  });
}

export async function revokeGrant(uid: string, source: MemoryPackSource, transactionId: string): Promise<void> {
  await reverseMemoryPackGrant({ uid, source, transactionId, fullReversal: true });
}

export async function grantExists(uid: string, source: MemoryPackSource, transactionId: string): Promise<boolean> {
  const snap = await db.doc(memoryWalletGrantDocPath(uid, memoryPackGrantEntryId(source, transactionId))).get();
  return snap.exists;
}
