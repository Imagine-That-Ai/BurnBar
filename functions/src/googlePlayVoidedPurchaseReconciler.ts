/**
 * @fileoverview Daily Google Play voided-purchase reconciliation backstop.
 *
 * RTDN remains the low-latency path. This scheduled sweep covers a missed
 * cancellation/refund/chargeback signal without persisting raw purchase tokens:
 * Google returns the affected token transiently, and the shared RTDN processor
 * immediately hashes it, resolves the server-owned claim, and re-verifies the
 * authoritative subscription before changing an entitlement.
 */

import { createHash } from "node:crypto";
import { onSchedule } from "firebase-functions/v2/scheduler";

import { getConfig } from "./config.js";
import { processGooglePlayDeveloperNotification } from "./googlePlayRtdn.js";
import { logError, logInfo } from "./logging.js";
import { externalApiWithResilience } from "./resilienceHelpers.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";
import { runScheduledJob } from "./scheduledOps.js";

const GOOGLE_PLAY_VOIDED_LOOKBACK_MS = 30 * 24 * 60 * 60 * 1000;
const GOOGLE_PLAY_VOIDED_PAGE_SIZE = 1_000;

function boundedPurchaseToken(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 && value.length <= 4096 ? value : undefined;
}

function positiveMillis(value: unknown): number | undefined {
  const parsed = typeof value === "string" ? Number(value) : Number.NaN;
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

function voidedSweepEventID(purchaseToken: string, orderID: unknown, voidedTimeMillis: number): string {
  const digest = createHash("sha256")
    .update(purchaseToken)
    .update("\0")
    .update(typeof orderID === "string" ? orderID : "")
    .update("\0")
    .update(String(voidedTimeMillis))
    .digest("hex");
  return `google-play-voided-sweep-${digest}`;
}

async function runGooglePlayVoidedPurchaseSweep(nowMillis = Date.now()): Promise<void> {
  const cfg = getConfig();
  const { google } = await import("googleapis");
  const authClient = await google.auth.getClient({
    scopes: ["https://www.googleapis.com/auth/androidpublisher"],
  });
  const androidpublisher = google.androidpublisher({ version: "v3", auth: authClient });

  let pageToken: string | undefined;
  const seenPageTokens = new Set<string>();
  let pages = 0;
  let considered = 0;
  let processed = 0;
  let skipped = 0;
  let failed = 0;

  do {
    const response = await externalApiWithResilience("googleplay.voidedpurchases.list", () =>
      androidpublisher.purchases.voidedpurchases.list({
        packageName: cfg.googlePlayPackageName,
        startTime: String(nowMillis - GOOGLE_PLAY_VOIDED_LOOKBACK_MS),
        endTime: String(nowMillis),
        maxResults: GOOGLE_PLAY_VOIDED_PAGE_SIZE,
        // OpenBurnBar currently issues one unit per Play top-up purchase, so
        // quantity-based partial-refund rows are not actionable and remain
        // excluded. Subscriptions and one-time purchases are both included by
        // the v3 endpoint default.
        includeQuantityBasedPartialRefund: false,
        ...(pageToken ? { token: pageToken } : {}),
      }),
    );
    pages += 1;

    for (const purchase of response.data.voidedPurchases ?? []) {
      considered += 1;
      const purchaseToken = boundedPurchaseToken(purchase.purchaseToken);
      if (!purchaseToken) {
        skipped += 1;
        continue;
      }
      const voidedTimeMillis = positiveMillis(purchase.voidedTimeMillis);
      if (!voidedTimeMillis) {
        skipped += 1;
        continue;
      }
      const eventID = voidedSweepEventID(purchaseToken, purchase.orderId, voidedTimeMillis);
      try {
        await processGooglePlayDeveloperNotification(
          {
            packageName: cfg.googlePlayPackageName,
            eventTimeMillis: String(voidedTimeMillis),
            voidedPurchaseNotification: {
              purchaseToken,
              orderId: purchase.orderId,
              // VoidedPurchase.voidedReason describes why the purchase was
              // voided, not RTDN's refundType. The current catalog is
              // single-quantity, so every listed void is a full reversal.
              refundType: 1,
            },
          },
          {
            eventID,
            publishTime: new Date(nowMillis).toISOString(),
          },
        );
        processed += 1;
      } catch (error) {
        failed += 1;
        logError({
          event: "google_play_voided_purchase_reconcile_failed",
          error: error instanceof Error ? error.name : "unknown",
        });
      }
    }

    const nextPageToken = response.data.tokenPagination?.nextPageToken;
    pageToken = typeof nextPageToken === "string" && nextPageToken.length > 0 ? nextPageToken : undefined;
    if (pageToken) {
      if (seenPageTokens.has(pageToken)) {
        throw new Error("Google Play voided-purchase pagination returned a repeated token.");
      }
      seenPageTokens.add(pageToken);
    }
  } while (pageToken);

  logInfo({
    event: "google_play_voided_purchase_reconcile_run",
    pages,
    considered,
    processed,
    skipped,
    failed,
  });

  if (failed > 0) {
    throw new Error(`Google Play voided-purchase reconciliation failed for ${failed} purchase(s).`);
  }
}

export const reconcileGooglePlayVoidedPurchasesDaily = onSchedule(
  {
    schedule: "every 24 hours",
    region: FUNCTIONS_REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    retryCount: 3,
    minBackoffSeconds: 60,
    maxBackoffSeconds: 3_600,
  },
  async () => {
    await runScheduledJob("reconcileGooglePlayVoidedPurchasesDaily", runGooglePlayVoidedPurchaseSweep);
  },
);
