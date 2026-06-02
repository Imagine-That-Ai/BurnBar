/**
 * Thin helpers for wrapping external calls with cockatiel policies.
 * @see resilience.ts
 */

import { randomUUID } from "node:crypto";
import {
  FieldValue,
  Timestamp,
  type DocumentData,
  type DocumentReference,
  type Firestore,
} from "firebase-admin/firestore";

import {
  externalApiPolicy,
  firestorePolicy,
  pushPolicy,
  quotaPolicy,
  stripePolicy,
  withResilience,
} from "./resilience.js";

const PUSH_LEASE_MS = 2 * 60 * 1000;
const PUSH_STALE_PENDING_MS = 2 * 60 * 1000;
const PUSH_RETRY_BASE_MS = 30 * 1000;
const PUSH_RETRY_MAX_MS = 5 * 60 * 1000;

export interface ClaimedPushDocument {
  data: DocumentData;
  leaseId: string;
  attemptCount: number;
}

export interface TransactionalDocumentSnapshot {
  exists: boolean;
  data(): DocumentData | undefined;
}

export interface TransactionalDocumentTransaction {
  get(ref: TransactionalDocumentReference): Promise<TransactionalDocumentSnapshot>;
  update(ref: TransactionalDocumentReference, data: DocumentData): void;
}

export interface TransactionalDocumentReference {
  id?: string;
  path?: string;
  firestore: {
    runTransaction<T>(fn: (transaction: TransactionalDocumentTransaction) => Promise<T>): Promise<T>;
  };
}

export async function stripeWithResilience<T>(label: string, fn: () => Promise<T>): Promise<T> {
  return withResilience(stripePolicy, `stripe:${label}`, fn);
}

export async function pushWithResilience<T>(label: string, fn: () => Promise<T>): Promise<T> {
  return withResilience(pushPolicy, `push:${label}`, fn);
}

export async function firestoreWithResilience<T>(label: string, fn: () => Promise<T>): Promise<T> {
  return withResilience(firestorePolicy, `firestore:${label}`, fn);
}

export async function externalApiWithResilience<T>(label: string, fn: () => Promise<T>): Promise<T> {
  return withResilience(externalApiPolicy, `external:${label}`, fn);
}

export async function quotaWithResilience<T>(label: string, fn: () => Promise<T>): Promise<T> {
  return withResilience(quotaPolicy, `quota:${label}`, fn);
}

/** Outbound HTTP from Functions (quota runner, insights, benchmarks). */
export async function resilientFetch(label: string, url: string | URL, init?: RequestInit): Promise<Response> {
  return externalApiWithResilience(label, () => fetch(url, init));
}

function timestampMillis(value: unknown): number | undefined {
  if (value instanceof Timestamp) return value.toMillis();
  if (value && typeof value === "object" && "toMillis" in value && typeof value.toMillis === "function") {
    const millis = value.toMillis();
    return typeof millis === "number" && Number.isFinite(millis) ? millis : undefined;
  }
  return undefined;
}

function positiveNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0;
}

export function nextPushRetryAt(nowMs = Date.now(), attemptCount = 1): Timestamp {
  const exponent = Math.min(Math.max(attemptCount - 1, 0), 4);
  const delayMs = Math.min(PUSH_RETRY_BASE_MS * 2 ** exponent, PUSH_RETRY_MAX_MS);
  return Timestamp.fromMillis(nowMs + delayMs);
}

export async function claimPendingPush(
  ref: TransactionalDocumentReference,
  options: { nowMs?: number; leaseMs?: number } = {},
): Promise<ClaimedPushDocument | undefined> {
  const nowMs = options.nowMs ?? Date.now();
  const leaseMs = options.leaseMs ?? PUSH_LEASE_MS;
  const leaseId = randomUUID();
  const now = Timestamp.fromMillis(nowMs);
  const leaseExpiresAt = Timestamp.fromMillis(nowMs + leaseMs);

  return ref.firestore.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) return undefined;
    const data = snapshot.data();
    if (!data || typeof data !== "object") return undefined;

    const status = typeof data.status === "string" ? data.status : "pending";
    if (status === "sent" || status === "rejected") return undefined;
    if (status === "sending") {
      const leaseExpiry = timestampMillis(data.leaseExpiresAt);
      if (leaseExpiry === undefined || leaseExpiry > nowMs) return undefined;
    }
    if (status === "pending") {
      const retryAt = timestampMillis(data.retryAt);
      if (retryAt !== undefined && retryAt > nowMs) return undefined;
    }

    const attemptCount = positiveNumber(data.attemptCount) + 1;
    transaction.update(ref, {
      status: "sending",
      leaseId,
      leaseExpiresAt,
      lastAttemptAt: now,
      attemptCount,
      updatedAt: now,
    });
    return {
      data: {
        ...data,
        status: "sending",
        leaseId,
        leaseExpiresAt,
        lastAttemptAt: now,
        attemptCount,
      },
      leaseId,
      attemptCount,
    };
  });
}

export async function finishClaimedPush(
  ref: TransactionalDocumentReference,
  leaseId: string,
  update: DocumentData,
): Promise<boolean> {
  return ref.firestore.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) return false;
    const data = snapshot.data();
    if (!data || data.status !== "sending" || data.leaseId !== leaseId) return false;
    transaction.update(ref, {
      ...update,
      leaseId: FieldValue.delete(),
      leaseExpiresAt: FieldValue.delete(),
      updatedAt: Timestamp.now(),
    });
    return true;
  });
}

export async function collectRetryablePushRefs(
  firestore: Firestore,
  collectionPath: string,
  options: { nowMs?: number; limit?: number } = {},
): Promise<DocumentReference[]> {
  const nowMs = options.nowMs ?? Date.now();
  const limit = Math.max(1, Math.min(options.limit ?? 50, 500));
  const now = Timestamp.fromMillis(nowMs);
  const staleCreatedAt = Timestamp.fromMillis(nowMs - PUSH_STALE_PENDING_MS);
  const collection = firestore.collection(collectionPath);
  const refs = new Map<string, DocumentReference>();

  const addSnapshot = (snapshot: FirebaseFirestore.QuerySnapshot) => {
    for (const doc of snapshot.docs) refs.set(doc.ref.path, doc.ref);
  };

  addSnapshot(await collection.where("retryAt", "<=", now).limit(limit).get());
  addSnapshot(await collection.where("leaseExpiresAt", "<=", now).limit(limit).get());
  addSnapshot(await collection.where("createdAt", "<=", staleCreatedAt).limit(limit).get());

  return Array.from(refs.values()).slice(0, limit);
}
