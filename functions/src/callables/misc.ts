/**
 * @fileoverview Miscellaneous callable functions
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { computeUserRollups, writeUserRollups } from "../rollups.js";
import { seedAndroidDemoAccount as seedAndroidDemoAccountForUser } from "../demoSeed.js";
import { logError, logInfo, wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

// ---------------------------------------------------------------------------
// Callable: rebuildUsageRollups
// ---------------------------------------------------------------------------

export const rebuildUsageRollups = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 10,
  },
  wrapCallableHandler("rebuildUsageRollups", async (request: CallableRequest<Record<string, never>>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);

    try {
      const rollups = await computeUserRollups(db, uid);
      await writeUserRollups(db, uid, rollups);
      logInfo({
        event: "callable_info",
        message: "rebuild_usage_rollups_succeeded",
        user_id_hash: uid.slice(0, 8),
        computed_at: rollups.all_time.computedAt,
      });
      return {
        success: true,
        computedAt: rollups.all_time.computedAt,
        windows: ["today", "7d", "30d", "90d", "all_time"] as const,
      };
    } catch (err) {
      logError({
        event: "callable_error",
        message: "rebuild_usage_rollups_failed",
        user_id_hash: uid.slice(0, 8),
        detail: String(err),
      });
      throw err;
    }
  }),
);

// ---------------------------------------------------------------------------
// Callable: seedAndroidDemoAccount
// ---------------------------------------------------------------------------

export const seedAndroidDemoAccount = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
  },
  wrapCallableHandler("seedAndroidDemoAccount", async (request: CallableRequest<Record<string, never>>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before loading demo data.");
    }
    enforceAuthAndAppCheck(request, uid);

    return seedAndroidDemoAccountForUser(db, uid);
  }),
);
