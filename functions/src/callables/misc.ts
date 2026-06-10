/**
 * @fileoverview Miscellaneous callable functions
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { refreshUserRollups } from "../rollups.js";
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
  wrapCallableHandler("rebuildUsageRollups", async (request: CallableRequest<{ force?: boolean }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);

    try {
      // `force: true` is the explicit repair path: rebuild the counters from
      // raw usage history. Routine dashboard refreshes omit it and are served
      // from the incremental counters whenever those are healthy.
      const force = request.data?.force === true;
      const { rollups, rebuiltCounters } = await refreshUserRollups(db, uid, { force });
      logInfo({
        event: "callable_info",
        message: "rebuild_usage_rollups_succeeded",
        user_id_hash: uid.slice(0, 8),
        computed_at: rollups.all_time.computedAt,
        counters_rebuilt: rebuiltCounters,
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
