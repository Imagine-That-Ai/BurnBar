import { createHash } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const state = vi.hoisted(() => ({
  list: vi.fn(),
  process: vi.fn(),
  logInfo: vi.fn(),
  logError: vi.fn(),
}));

vi.mock("firebase-functions/v2/scheduler", () => ({
  onSchedule: vi.fn((_options, handler) => ({ run: handler })),
}));

vi.mock("googleapis", () => ({
  google: {
    auth: { getClient: vi.fn(async () => ({})) },
    androidpublisher: vi.fn(() => ({
      purchases: {
        voidedpurchases: { list: state.list },
      },
    })),
  },
}));

vi.mock("../config.js", () => ({
  getConfig: () => ({ googlePlayPackageName: "com.openburnbar" }),
}));

vi.mock("../googlePlayRtdn.js", () => ({
  processGooglePlayDeveloperNotification: state.process,
}));

vi.mock("../logging.js", () => ({
  logInfo: state.logInfo,
  logError: state.logError,
}));

vi.mock("../resilienceHelpers.js", () => ({
  externalApiWithResilience: vi.fn(async <T>(_label: string, operation: () => Promise<T>) => operation()),
}));

vi.mock("../runtimeOptions.js", () => ({
  FUNCTIONS_REGION: "us-central1",
}));

vi.mock("../scheduledOps.js", () => ({
  runScheduledJob: vi.fn(async <T>(_name: string, operation: () => Promise<T>) => operation()),
}));

import { reconcileGooglePlayVoidedPurchasesDaily } from "../googlePlayVoidedPurchaseReconciler.js";

function eventDigest(token: string, orderID: string, voidedTimeMillis: string): string {
  return createHash("sha256")
    .update(token)
    .update("\0")
    .update(orderID)
    .update("\0")
    .update(voidedTimeMillis)
    .digest("hex");
}

async function runScheduled(): Promise<void> {
  await reconcileGooglePlayVoidedPurchasesDaily.run({
    scheduleTime: "2026-07-26T12:00:00.000Z",
  });
}

describe("Google Play voided-purchase scheduled reconciliation", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-26T12:00:00.000Z"));
    state.process.mockResolvedValue(undefined);
  });

  it("paginates the 30-day window and routes every valid token through the RTDN reconciler", async () => {
    state.list
      .mockResolvedValueOnce({
        data: {
          voidedPurchases: [
            {
              purchaseToken: "subscription-token",
              orderId: "GPA.1-2-3..0",
              voidedTimeMillis: "1785060000000",
              voidedReason: 7,
            },
            { orderId: "missing-token", voidedTimeMillis: "1785060000001" },
          ],
          tokenPagination: { nextPageToken: "page-2" },
        },
      })
      .mockResolvedValueOnce({
        data: {
          voidedPurchases: [
            {
              purchaseToken: "topup-token",
              orderId: "GPA.4-5-6",
              voidedTimeMillis: "1785060000002",
              voidedReason: 1,
            },
          ],
          tokenPagination: {},
        },
      });

    await runScheduled();

    expect(state.list).toHaveBeenNthCalledWith(1, {
      packageName: "com.openburnbar",
      startTime: String(Date.now() - 30 * 24 * 60 * 60 * 1000),
      endTime: String(Date.now()),
      maxResults: 1_000,
      includeQuantityBasedPartialRefund: false,
      // type=1 includes voided subscription purchases; the endpoint default
      // (type=0) silently returns only voided in-app purchases.
      type: 1,
    });
    expect(state.list).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        token: "page-2",
      }),
    );
    expect(state.process).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        packageName: "com.openburnbar",
        eventTimeMillis: "1785060000000",
        voidedPurchaseNotification: expect.objectContaining({
          purchaseToken: "subscription-token",
          orderId: "GPA.1-2-3..0",
          refundType: 1,
        }),
      }),
      expect.objectContaining({
        eventID: `google-play-voided-sweep-${eventDigest("subscription-token", "GPA.1-2-3..0", "1785060000000")}`,
      }),
    );
    expect(state.process).toHaveBeenCalledTimes(2);
    expect(state.logInfo).toHaveBeenCalledWith({
      event: "google_play_voided_purchase_reconcile_run",
      pages: 2,
      considered: 3,
      processed: 2,
      skipped: 1,
      failed: 0,
    });
    expect(JSON.stringify(state.logInfo.mock.calls)).not.toContain("subscription-token");
    expect(JSON.stringify(state.logInfo.mock.calls)).not.toContain("topup-token");
  });

  it("attempts the full page and throws so Scheduler retries failed items", async () => {
    state.list.mockResolvedValueOnce({
      data: {
        voidedPurchases: [
          {
            purchaseToken: "first-token",
            orderId: "GPA.first",
            voidedTimeMillis: "1785060000000",
          },
          {
            purchaseToken: "second-token",
            orderId: "GPA.second",
            voidedTimeMillis: "1785060000001",
          },
        ],
      },
    });
    state.process.mockRejectedValueOnce(new Error("transient")).mockResolvedValueOnce(undefined);

    await expect(runScheduled()).rejects.toThrow(/failed for 1 purchase/);

    expect(state.process).toHaveBeenCalledTimes(2);
    expect(state.logError).toHaveBeenCalledWith({
      event: "google_play_voided_purchase_reconcile_failed",
      error: "Error",
    });
  });

  it("skips malformed tokens and timestamps without inventing unstable event ids", async () => {
    state.list.mockResolvedValueOnce({
      data: {
        voidedPurchases: [
          {
            purchaseToken: "valid-token-without-time",
            orderId: "GPA.no-time",
          },
          {
            purchaseToken: "x".repeat(4_097),
            orderId: "GPA.oversized-token",
            voidedTimeMillis: "1785060000000",
          },
        ],
      },
    });

    await runScheduled();

    expect(state.process).not.toHaveBeenCalled();
    expect(state.logInfo).toHaveBeenCalledWith({
      event: "google_play_voided_purchase_reconcile_run",
      pages: 1,
      considered: 2,
      processed: 0,
      skipped: 2,
      failed: 0,
    });
  });

  it("fails closed when Google returns a repeated pagination token", async () => {
    state.list
      .mockResolvedValueOnce({
        data: {
          voidedPurchases: [],
          tokenPagination: { nextPageToken: "loop" },
        },
      })
      .mockResolvedValueOnce({
        data: {
          voidedPurchases: [],
          tokenPagination: { nextPageToken: "loop" },
        },
      });

    await expect(runScheduled()).rejects.toThrow(/repeated token/);
    expect(state.list).toHaveBeenCalledTimes(2);
  });
});
