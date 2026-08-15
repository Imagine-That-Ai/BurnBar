/**
 * @fileoverview Firestore paths for the memory Power-Up wallet.
 *
 * `users/{uid}/memoryWallet/current` is the client-readable cache.
 * Active grants live in its `grants` subcollection (server-only).
 * `memoryWalletLedger` is append-only audit and is never on the debit hot path.
 */

import { requiredIdentifier } from "../callables/shared/validators.js";
import type { MemoryPackSource } from "./catalog.js";

export function memoryWalletDocPath(uid: string): string {
  return `users/${uid}/memoryWallet/current`;
}

export function memoryWalletGrantDocPath(uid: string, entryId: string): string {
  return `users/${uid}/memoryWallet/current/grants/${entryId}`;
}

export function memoryWalletLedgerDocPath(uid: string, entryId: string): string {
  return `users/${uid}/memoryWalletLedger/${entryId}`;
}

export function memoryPackTransactionDocPath(source: MemoryPackSource, transactionId: string): string {
  return `memory_pack_transactions/${requiredIdentifier(`${source}_${transactionId}`, "memoryPackTransactionID")}`;
}

export function stripeMemoryPackPaymentDocPath(kind: "charge" | "payment_intent", externalID: string): string {
  return `stripe_memory_pack_payments/${requiredIdentifier(`${kind}_${externalID}`, "stripeMemoryPackPaymentID")}`;
}

export function memoryPackGrantEntryId(source: MemoryPackSource, transactionId: string): string {
  return requiredIdentifier(`${source}_${transactionId}`, "memoryPackGrantID");
}

export function memoryPackDebitLedgerId(reservationId: string): string {
  return `debit_${requiredIdentifier(reservationId, "reservationId")}`;
}
