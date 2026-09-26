import { onSchedule } from "firebase-functions/v2/scheduler";
import type { Query, QueryDocumentSnapshot, DocumentData } from "firebase-admin/firestore";

import { db } from "@openburnbar/functions-shared/adminRuntime.js";
import { FUNCTIONS_REGION } from "@openburnbar/functions-shared/runtimeOptions.js";
import { logInfo, logWarn } from "@openburnbar/functions-shared/logging.js";
import { activeBurnbarStoragePort } from "./burnbarAttachments.js";

type ReaperPort = ReturnType<typeof activeBurnbarStoragePort>;
let reaperPort: ReaperPort = activeBurnbarStoragePort();
export function setReaperStoragePort(port: ReaperPort): void {
  reaperPort = port;
}

const DAY_MS = 24 * 60 * 60 * 1000;
const DEFAULT_BATCH_SIZE = 100;
const DEFAULT_MAX_BATCHES = 10;
const DEFAULT_TIMEOUT_MS = 50_000; // 50s execution budget

interface ReaperOptions {
  nowMs?: number;
  batchSize?: number;
  maxBatches?: number;
  timeoutMs?: number;
}

interface ReaperResult {
  reaped: number;
  gatewayReaped: number;
  hasMore?: boolean;
}

interface LoopBudget {
  batchSize: number;
  maxBatches: number;
  timeoutMs: number;
  startTime: number;
}

interface LoopOutcome {
  count: number;
  hasMore: boolean;
}

/** Reads one batch page of burnbar_attachments with the indexed state predicate. */
async function fetchBurnbarPage(
  lastDoc: QueryDocumentSnapshot<DocumentData> | undefined,
  budget: LoopBudget,
): Promise<QueryDocumentSnapshot<DocumentData>[]> {
  let query: Query<DocumentData> = db
    .collectionGroup("burnbar_attachments")
    .where("state", "in", ["pending_upload", "composing"]);
  if (lastDoc) {
    query = query.startAfter(lastDoc);
  }
  query = query.limit(budget.batchSize);
  const snapshot = await query.get();
  return snapshot.docs;
}

/** Reads one batch page of hermes_gateway_attachments. */
async function fetchGatewayPage(
  lastDoc: QueryDocumentSnapshot<DocumentData> | undefined,
  budget: LoopBudget,
): Promise<QueryDocumentSnapshot<DocumentData>[]> {
  let query: Query<DocumentData> = db.collectionGroup("hermes_gateway_attachments");
  if (lastDoc) {
    query = query.startAfter(lastDoc);
  }
  query = query.limit(budget.batchSize);
  const snapshot = await query.get();
  return snapshot.docs;
}

/** Expires stale burnbar_attachments in bounded batches; leaves partial uploads revoked. */
async function reapBurnbarCollection(cutoff: number, budget: LoopBudget): Promise<LoopOutcome> {
  let count = 0;
  let lastDoc: QueryDocumentSnapshot<DocumentData> | undefined;
  let exhausted = false;
  for (let batchIdx = 0; batchIdx < budget.maxBatches; batchIdx++) {
    if (Date.now() - budget.startTime >= budget.timeoutMs) {
      logWarn({ event: "callable_warning", message: "reaper_timeout_burnbar_attachments", batchIdx, count });
      return { count, hasMore: true };
    }
    const docs = await fetchBurnbarPage(lastDoc, budget);
    if (docs.length === 0) {
      exhausted = true;
      break;
    }

    for (const doc of docs) {
      const updated = doc.get("updatedAt");
      const millis = typeof updated?.toMillis === "function" ? updated.toMillis() : 0;
      if (millis && millis < cutoff) {
        const path = doc.get("storagePath");
        if (typeof path === "string") {
          await reaperPort.delete(path);
          const prefix = path.replace(/\/final$/, "");
          await reaperPort.revokePuts(`${prefix}/parts/`);
          await reaperPort.revokePuts(`${prefix}/mid/`);
        }
        await doc.ref.set({ state: "expired" }, { merge: true });
        count += 1;
      }
    }

    lastDoc = docs[docs.length - 1];
    if (docs.length < budget.batchSize) {
      exhausted = true;
      break;
    }
  }
  return { count, hasMore: !exhausted };
}

/** Deletes expired hermes_gateway_attachments in bounded batches. */
async function reapGatewayCollection(nowMs: number, budget: LoopBudget): Promise<LoopOutcome> {
  let count = 0;
  let lastDoc: QueryDocumentSnapshot<DocumentData> | undefined;
  let exhausted = false;
  for (let batchIdx = 0; batchIdx < budget.maxBatches; batchIdx++) {
    if (Date.now() - budget.startTime >= budget.timeoutMs) {
      logWarn({ event: "callable_warning", message: "reaper_timeout_gateway_attachments", batchIdx, count });
      return { count, hasMore: true };
    }
    const docs = await fetchGatewayPage(lastDoc, budget);
    if (docs.length === 0) {
      exhausted = true;
      break;
    }

    for (const doc of docs) {
      const expiresAt = doc.get("expiresAt");
      const millis =
        typeof expiresAt?.toMillis === "function"
          ? expiresAt.toMillis()
          : Date.parse(String(expiresAt ?? ""));
      if (Number.isFinite(millis) && millis < nowMs) {
        const path = doc.get("storagePath");
        if (typeof path === "string") await reaperPort.delete(path);
        await doc.ref.delete();
        count += 1;
      }
    }

    lastDoc = docs[docs.length - 1];
    if (docs.length < budget.batchSize) {
      exhausted = true;
      break;
    }
  }
  return { count, hasMore: !exhausted };
}

export async function reapExpiredBurnbarAttachments(
  optionsOrNowMs?: number | ReaperOptions,
): Promise<ReaperResult> {
  const options: ReaperOptions =
    typeof optionsOrNowMs === "number"
      ? { nowMs: optionsOrNowMs }
      : optionsOrNowMs ?? {};

  const nowMs = options.nowMs ?? Date.now();
  const budget: LoopBudget = {
    batchSize: options.batchSize ?? DEFAULT_BATCH_SIZE,
    maxBatches: options.maxBatches ?? DEFAULT_MAX_BATCHES,
    timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    startTime: Date.now(),
  };

  const burnbar = await reapBurnbarCollection(nowMs - DAY_MS, budget);
  const gateway = await reapGatewayCollection(nowMs, budget);
  const hasMore = burnbar.hasMore || gateway.hasMore;

  logInfo({ event: "callable_info", message: "burnbar_attachments_reaped", reaped: burnbar.count, gatewayReaped: gateway.count, hasMore });
  return { reaped: burnbar.count, gatewayReaped: gateway.count, hasMore };
}

export const reapBurnbarAttachments = onSchedule(
  { schedule: "every 60 minutes", region: FUNCTIONS_REGION },
  async () => {
    await reapExpiredBurnbarAttachments();
  },
);
