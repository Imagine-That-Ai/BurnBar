/** Immediate, idempotent server metering for immutable Computer Use headers. */
import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { onDocumentCreated, onDocumentUpdated } from "firebase-functions/v2/firestore";
import type { DocumentData } from "firebase-admin/firestore";
import { numberField, stringField } from "./guards.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

interface QuotaDelta {
  browserActionsExecuted: number;
  browserActionsRejected: number;
  systemActionsExecuted: number;
  systemActionsRejected: number;
  phoneControlIntentsExecuted: number;
  phoneControlIntentsRejected: number;
  sessionsStarted: number;
  sessionsCompleted: number;
  totalSessionSeconds: number;
  visionModelSpendUSD: number;
}

const ZERO_DELTA: QuotaDelta = {
  browserActionsExecuted: 0,
  browserActionsRejected: 0,
  systemActionsExecuted: 0,
  systemActionsRejected: 0,
  phoneControlIntentsExecuted: 0,
  phoneControlIntentsRejected: 0,
  sessionsStarted: 0,
  sessionsCompleted: 0,
  totalSessionSeconds: 0,
  visionModelSpendUSD: 0,
};

function dayKeyUTC(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function nonNegative(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0;
}

function actionQuotaDelta(data: DocumentData): QuotaDelta {
  const delta = { ...ZERO_DELTA };
  const status = stringField(data, "status") ?? "";
  const toolKind = stringField(data, "toolKind") ?? "";
  const executed = status === "executed";
  const rejected = status === "denied" || status === "rejected" || status === "error";
  const browser = toolKind.startsWith("browser_");
  const system = toolKind.startsWith("mac_input_") || toolKind === "mac_inspect_accessibility";
  const phone = stringField(data, "approvedBy") === "phone";

  if (browser && executed) delta.browserActionsExecuted = 1;
  if (browser && rejected) delta.browserActionsRejected = 1;
  if (system && executed) delta.systemActionsExecuted = 1;
  if (system && rejected) delta.systemActionsRejected = 1;
  if (phone && executed) delta.phoneControlIntentsExecuted = 1;
  if (phone && rejected) delta.phoneControlIntentsRejected = 1;
  delta.visionModelSpendUSD = Math.min(25, nonNegative(numberField(data, "visionTokensCostUSD")));
  return delta;
}

function nextQuotaUsage(current: DocumentData | undefined, dayKey: string, delta: QuotaDelta, now: Date): DocumentData {
  const next: DocumentData = { dayKey, updatedAt: Timestamp.fromDate(now) };
  for (const [field, increment] of Object.entries(delta)) {
    next[field] = nonNegative(current?.[field]) + increment;
  }
  return next;
}

interface MeteringDocumentSnapshot {
  readonly exists: boolean;
  data(): DocumentData | undefined;
  get(field: string): unknown;
}

interface MeteringTransaction<Reference> {
  get(reference: Reference): Promise<MeteringDocumentSnapshot>;
  set(reference: Reference, data: DocumentData, options: { merge: false }): void;
  update(reference: Reference, data: DocumentData): void;
}

interface MeteringFirestore<Reference> {
  doc(path: string): Reference;
  runTransaction<T>(body: (transaction: MeteringTransaction<Reference>) => Promise<T>): Promise<T>;
}

async function applyDeltaOnce<Reference>(options: {
  firestore: MeteringFirestore<Reference>;
  sourceRef: Reference;
  uid: string;
  eventId: string;
  markerPrefix: "quotaMetered" | "quotaStartMetered" | "quotaCompletionMetered";
  occurredAt: Date;
  delta: QuotaDelta;
}): Promise<boolean> {
  const { firestore, sourceRef, uid, eventId, markerPrefix, occurredAt, delta } = options;
  const eventField = `${markerPrefix}EventId`;
  const dayField = `${markerPrefix}DayKey`;
  const atField = `${markerPrefix}At`;
  const dayKey = dayKeyUTC(occurredAt);
  const quotaRef = firestore.doc(`users/${uid}/computer_use_quota_usage/${dayKey}`);

  return firestore.runTransaction(async (transaction) => {
    const [source, quota] = await Promise.all([transaction.get(sourceRef), transaction.get(quotaRef)]);
    if (!source.exists) return false;
    if (source.get(eventField) != null) return false;

    transaction.set(quotaRef, nextQuotaUsage(quota.data(), dayKey, delta, occurredAt), { merge: false });
    transaction.update(sourceRef, {
      [eventField]: eventId,
      [dayField]: dayKey,
      [atField]: Timestamp.fromDate(occurredAt),
    });
    return true;
  });
}

function eventDate(value: string | undefined): Date {
  const parsed = value ? new Date(value) : new Date();
  return Number.isFinite(parsed.getTime()) ? parsed : new Date();
}

function timestampDate(value: unknown): Date | undefined {
  if (value instanceof Timestamp) return value.toDate();
  if (value instanceof Date && Number.isFinite(value.getTime())) return value;
  if (typeof value !== "string") return undefined;
  const parsed = new Date(value);
  return Number.isFinite(parsed.getTime()) ? parsed : undefined;
}

function sourceEventDate(
  snapshot: MeteringDocumentSnapshot,
  field: string,
  fallbackEventTime: string | undefined,
): Date {
  return timestampDate(snapshot.get(field)) ?? eventDate(fallbackEventTime);
}

export const __testing__ = {
  applyDeltaOnce,
  actionQuotaDelta,
  dayKeyUTC,
  nextQuotaUsage,
  sourceEventDate,
};

export const meterComputerUseAction = onDocumentCreated(
  {
    document: "users/{uid}/computer_use_actions/{actionId}",
    region: FUNCTIONS_REGION,
    memory: "256MiB",
    timeoutSeconds: 60,
  },
  async (event) => {
    const snapshot = event.data;
    const uid = event.params.uid;
    if (!snapshot || typeof uid !== "string" || !uid) return;
    await applyDeltaOnce({
      firestore: getFirestore(),
      sourceRef: snapshot.ref,
      uid,
      eventId: event.id,
      markerPrefix: "quotaMetered",
      occurredAt: sourceEventDate(snapshot, "recordedAt", event.time),
      delta: actionQuotaDelta(snapshot.data()),
    });
  },
);

export const meterComputerUseSessionStart = onDocumentCreated(
  {
    document: "users/{uid}/computer_use_sessions/{sessionId}",
    region: FUNCTIONS_REGION,
    memory: "256MiB",
    timeoutSeconds: 60,
  },
  async (event) => {
    const snapshot = event.data;
    const uid = event.params.uid;
    if (!snapshot || typeof uid !== "string" || !uid) return;
    await applyDeltaOnce({
      firestore: getFirestore(),
      sourceRef: snapshot.ref,
      uid,
      eventId: event.id,
      markerPrefix: "quotaStartMetered",
      occurredAt: sourceEventDate(snapshot, "startedAt", event.time),
      delta: { ...ZERO_DELTA, sessionsStarted: 1 },
    });
  },
);

export const meterComputerUseSessionCompletion = onDocumentUpdated(
  {
    document: "users/{uid}/computer_use_sessions/{sessionId}",
    region: FUNCTIONS_REGION,
    memory: "256MiB",
    timeoutSeconds: 60,
  },
  async (event) => {
    const before = event.data?.before;
    const after = event.data?.after;
    const uid = event.params.uid;
    if (!before || !after || typeof uid !== "string" || !uid) return;
    if (before.get("endedAt") != null || after.get("endedAt") == null) return;
    const startedAt = after.get("startedAt");
    const endedAt = after.get("endedAt");
    const elapsed =
      startedAt instanceof Timestamp && endedAt instanceof Timestamp
        ? Math.max(0, Math.floor((endedAt.toMillis() - startedAt.toMillis()) / 1_000))
        : 0;
    await applyDeltaOnce({
      firestore: getFirestore(),
      sourceRef: after.ref,
      uid,
      eventId: event.id,
      markerPrefix: "quotaCompletionMetered",
      occurredAt: sourceEventDate(after, "endedAt", event.time),
      delta: { ...ZERO_DELTA, sessionsCompleted: 1, totalSessionSeconds: elapsed },
    });
  },
);
