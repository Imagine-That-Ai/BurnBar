import { onSchedule } from "firebase-functions/v2/scheduler";
import type { QueryDocumentSnapshot, DocumentData } from "firebase-admin/firestore";

import { db } from "../adminRuntime.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { logInfo, logWarn } from "../logging.js";
import { activeBurnbarStoragePort } from "../callables/burnbarAttachments.js";

type ReaperPort = ReturnType<typeof activeBurnbarStoragePort>;
let reaperPort: ReaperPort = activeBurnbarStoragePort();
export function setReaperStoragePort(port: ReaperPort): void {
  reaperPort = port;
}

const DAY_MS = 24 * 60 * 60 * 1000;
const DEFAULT_BATCH_SIZE = 100;
const DEFAULT_MAX_BATCHES = 10;
const DEFAULT_TIMEOUT_MS = 50_000; // 50s execution budget

export interface ReaperOptions {
  nowMs?: number;
  batchSize?: number;
  maxBatches?: number;
  timeoutMs?: number;
}

export interface ReaperResult {
  reaped: number;
  gatewayReaped: number;
  hasMore?: boolean;
}

export async function reapExpiredBurnbarAttachments(
  optionsOrNowMs?: number | ReaperOptions,
): Promise<ReaperResult> {
  const options: ReaperOptions =
    typeof optionsOrNowMs === "number"
      ? { nowMs: optionsOrNowMs }
      : optionsOrNowMs ?? {};

  const nowMs = options.nowMs ?? Date.now();
  const batchSize = options.batchSize ?? DEFAULT_BATCH_SIZE;
  const maxBatches = options.maxBatches ?? DEFAULT_MAX_BATCHES;
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const startTime = Date.now();
  const cutoff = nowMs - DAY_MS;

  let reaped = 0;
  let gatewayReaped = 0;
  let hasMore = false;

  // 1. Process burnbar_attachments with indexed state predicate and cursor pagination
  let lastBurnbarDoc: QueryDocumentSnapshot<DocumentData> | undefined;
  for (let batchIdx = 0; batchIdx < maxBatches; batchIdx++) {
    if (Date.now() - startTime >= timeoutMs) {
      logWarn({ event: "callable_warning", message: "reaper_timeout_burnbar_attachments", batchIdx, reaped });
      hasMore = true;
      break;
    }

    let query = db
      .collectionGroup("burnbar_attachments")
      .where("state", "in", ["pending_upload", "composing"]);

    if (lastBurnbarDoc) {
      query = query.startAfter(lastBurnbarDoc);
    }
    query = query.limit(batchSize);

    const snapshot = await query.get();
    const docs = (snapshot.docs ?? []) as QueryDocumentSnapshot<DocumentData>[];
    if (docs.length === 0) {
      break;
    }

    for (const doc of docs) {
      const state = doc.get("state");
      if (state !== "pending_upload" && state !== "composing") continue;
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
        reaped += 1;
      }
    }

    lastBurnbarDoc = docs[docs.length - 1];
    if (docs.length < batchSize) {
      break;
    }
    if (batchIdx === maxBatches - 1) {
      hasMore = true;
    }
  }

  // 2. Process hermes_gateway_attachments with cursor pagination
  let lastGatewayDoc: QueryDocumentSnapshot<DocumentData> | undefined;
  for (let batchIdx = 0; batchIdx < maxBatches; batchIdx++) {
    if (Date.now() - startTime >= timeoutMs) {
      logWarn({ event: "callable_warning", message: "reaper_timeout_gateway_attachments", batchIdx, gatewayReaped });
      hasMore = true;
      break;
    }

    let query = db.collectionGroup("hermes_gateway_attachments");
    if (lastGatewayDoc) {
      query = query.startAfter(lastGatewayDoc);
    }
    query = query.limit(batchSize);

    const snapshot = await query.get();
    const docs = (snapshot.docs ?? []) as QueryDocumentSnapshot<DocumentData>[];
    if (docs.length === 0) {
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
        gatewayReaped += 1;
      }
    }

    lastGatewayDoc = docs[docs.length - 1];
    if (docs.length < batchSize) {
      break;
    }
    if (batchIdx === maxBatches - 1) {
      hasMore = true;
    }
  }

  logInfo({ event: "callable_info", message: "burnbar_attachments_reaped", reaped, gatewayReaped, hasMore });
  return { reaped, gatewayReaped, hasMore };
}

export const reapBurnbarAttachments = onSchedule(
  { schedule: "every 60 minutes", region: FUNCTIONS_REGION },
  async () => {
    await reapExpiredBurnbarAttachments();
  },
);
