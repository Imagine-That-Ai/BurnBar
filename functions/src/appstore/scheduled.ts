/**
 * @fileoverview Scheduled hosted-entitlement reconciliation.
 *
 * Apple S2S notifications are reliable but not infallible: Apple has
 * documented edge cases where a final state change (e.g. silent expiry,
 * billing-retry failure) reaches us with delay or not at all. A daily
 * reconciliation job rebuilds entitlement state from the App Store
 * Server API for every currently-active hosted entitlement, so we stay
 * eventually consistent even if a webhook delivery is lost.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore } from "firebase-admin/firestore";

import type { HostedQuotaEntitlementDoc } from "../types.js";

import {
  APP_STORE_SECRETS,
  hostedQuotaProductID,
  loadAppStoreRuntimeConfig,
} from "./config.js";
import { fetchLiveSubscriptionStatus } from "./client.js";
import {
  EntitlementReconcileError,
  reconcileEntitlement,
} from "./reconciler.js";
import { JWSVerificationFailure } from "./verifier.js";

const REGION = "us-central1";

/**
 * Daily reconciliation of every active hosted entitlement.
 *
 * Bounded batch — we cap at 250 entitlements per run; if the user base
 * grows past that, the job naturally backlogs by a day per 250 users
 * and we add an explicit cursor.
 */
export const reconcileHostedEntitlementsDaily = onSchedule(
  {
    schedule: "every 24 hours",
    region: REGION,
    secrets: APP_STORE_SECRETS,
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async () => {
    const db = getFirestore();
    const cfg = loadAppStoreRuntimeConfig();
    const productID = hostedQuotaProductID();

    const cg = await db
      .collectionGroup("entitlements")
      .where("id", "==", "hosted_quota_sync")
      .where("active", "==", true)
      .limit(250)
      .get();

    let ok = 0;
    let updated = 0;
    let failed = 0;

    for (const doc of cg.docs) {
      const data = doc.data() as HostedQuotaEntitlementDoc;
      const original = data.originalTransactionID;
      if (!original) continue;
      try {
        const env = data.environment ?? cfg.environment;
        const live = await fetchLiveSubscriptionStatus(cfg, env, original);
        const seedJWS = live.pairs[0]?.signedTransactionInfo;
        if (!seedJWS) {
          // No JWS came back; mark the doc as needing client refresh,
          // but do not flip `active` blindly here.
          continue;
        }
        const result = await reconcileEntitlement(db, cfg, {
          signedTransactionJWS: seedJWS,
          signedRenewalInfoJWS: live.pairs[0]?.signedRenewalInfo,
          source: "scheduled_reconcile",
          productID,
        });
        ok += 1;
        if (result.changed) updated += 1;
      } catch (err) {
        failed += 1;
        if (
          err instanceof JWSVerificationFailure ||
          err instanceof EntitlementReconcileError
        ) {
          console.warn("appstore:scheduled reconcile soft-failed", {
            path: doc.ref.path,
            code:
              err instanceof EntitlementReconcileError
                ? err.code
                : "jws_invalid",
          });
        } else {
          console.error("appstore:scheduled reconcile error", {
            path: doc.ref.path,
            message: (err as Error).message,
          });
        }
      }
    }

    console.info("appstore:scheduled reconcile run", {
      considered: cg.size,
      ok,
      updated,
      failed,
    });
  }
);
