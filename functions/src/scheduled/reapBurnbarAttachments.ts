import { onSchedule } from "firebase-functions/v2/scheduler";

import { db } from "../adminRuntime.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { logInfo } from "../logging.js";
import { activeBurnbarStoragePort } from "../callables/burnbarAttachments.js";

type ReaperPort = ReturnType<typeof activeBurnbarStoragePort>;
let reaperPort: ReaperPort = activeBurnbarStoragePort();
export function setReaperStoragePort(port: ReaperPort): void {
  reaperPort = port;
}

const DAY_MS = 24 * 60 * 60 * 1000;

export async function reapExpiredBurnbarAttachments(nowMs: number = Date.now()): Promise<{ reaped: number; gatewayReaped: number }> {
    const cutoff = nowMs - DAY_MS;
    const pending = await db.collectionGroup("burnbar_attachments").get();
    let reaped = 0;
    for (const doc of pending.docs ?? []) {
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
    const gateway = await db.collectionGroup("hermes_gateway_attachments").get();
    let gatewayReaped = 0;
    for (const doc of gateway.docs ?? []) {
      const expiresAt = doc.get("expiresAt");
      const millis = typeof expiresAt?.toMillis === "function" ? expiresAt.toMillis() : Date.parse(String(expiresAt ?? ""));
      if (Number.isFinite(millis) && millis < nowMs) {
        const path = doc.get("storagePath");
        if (typeof path === "string") await reaperPort.delete(path);
        await doc.ref.delete();
        gatewayReaped += 1;
      }
    }
    logInfo({ event: "callable_info", message: "burnbar_attachments_reaped", reaped, gatewayReaped });
    return { reaped, gatewayReaped };
}

export const reapBurnbarAttachments = onSchedule(
  { schedule: "every 60 minutes", region: FUNCTIONS_REGION },
  async () => {
    await reapExpiredBurnbarAttachments();
  },
);
