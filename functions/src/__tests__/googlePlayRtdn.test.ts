import { createHash } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const state = vi.hoisted(() => {
  const documents = new Map<string, Record<string, unknown>>();
  const writes: Array<{ path: string; data: Record<string, unknown> }> = [];
  return {
    documents,
    writes,
    transactionTail: Promise.resolve(),
    subscriptionsGet: vi.fn(),
    writeEntitlement: vi.fn(),
    reconcileTopUp: vi.fn(),
    logInfo: vi.fn(),
    logError: vi.fn(),
  };
});

vi.mock("firebase-functions/v2/pubsub", () => ({
  onMessagePublished: vi.fn((_options, handler) => ({ run: handler })),
}));

vi.mock("googleapis", () => ({
  google: {
    auth: { getClient: vi.fn(async () => ({})) },
    androidpublisher: vi.fn(() => ({
      purchases: {
        subscriptionsv2: { get: state.subscriptionsGet },
      },
    })),
  },
}));

vi.mock("../adminRuntime.js", () => ({
  db: {
    doc: (path: string) => {
      const ref = {
        path,
        get: async () => {
          const data = state.documents.get(path);
          return {
            exists: data !== undefined,
            get: (field: string) => data?.[field],
            data: () => data,
          };
        },
        set: async (data: Record<string, unknown>, options?: { merge?: boolean }) => {
          const next = options?.merge ? { ...(state.documents.get(path) ?? {}), ...data } : data;
          state.documents.set(path, next);
          state.writes.push({ path, data });
        },
      };
      return ref;
    },
    runTransaction: async <T>(
      operation: (transaction: {
        get: (ref: { path: string }) => Promise<{
          exists: boolean;
          get: (field: string) => unknown;
          data: () => Record<string, unknown> | undefined;
        }>;
        set: (
          ref: { path: string },
          data: Record<string, unknown>,
          options?: { merge?: boolean },
        ) => void;
      }) => Promise<T>,
    ): Promise<T> => {
      const previous = state.transactionTail;
      let release: () => void = () => undefined;
      state.transactionTail = new Promise<void>((resolve) => {
        release = resolve;
      });
      await previous;
      const staged: Array<{
        path: string;
        data: Record<string, unknown>;
        options?: { merge?: boolean };
      }> = [];
      try {
        const result = await operation({
          get: async (ref) => {
            const data = state.documents.get(ref.path);
            return {
              exists: data !== undefined,
              get: (field: string) => data?.[field],
              data: () => data,
            };
          },
          set: (ref, data, options) => {
            staged.push({ path: ref.path, data, options });
          },
        });
        for (const write of staged) {
          const next = write.options?.merge
            ? { ...(state.documents.get(write.path) ?? {}), ...write.data }
            : write.data;
          state.documents.set(write.path, next);
          state.writes.push({ path: write.path, data: write.data });
        }
        return result;
      } finally {
        release();
      }
    },
  },
}));

vi.mock("../config.js", () => ({
  getConfig: () => ({
    googlePlayPackageName: "com.openburnbar",
  }),
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
  GOOGLE_PLAY_RTDN_TOPIC: "play-billing-notifications",
}));

vi.mock("../callables/shared.js", async () => {
  const actualGuards = await import("../guards.js");
  return {
    GOOGLE_PLAY_ACTIVE_STATES: new Set([
      "SUBSCRIPTION_STATE_ACTIVE",
      "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
      "SUBSCRIPTION_STATE_CANCELED",
    ]),
    reconcileCloudProTopUpReversal: state.reconcileTopUp,
    safeCloudDocumentID: (value: unknown) => String(value),
    selectGooglePlaySubscriptionLineItem: (
      purchase: { lineItems?: Array<{ productId?: unknown; expiryTime?: unknown }> },
      preferredProductIDs: string[],
    ) => {
      const lineItem =
        purchase.lineItems?.find((item) => preferredProductIDs.includes(String(item.productId))) ??
        purchase.lineItems?.[0] ??
        {};
      return {
        lineItem,
        target: {
          entitlementID: "burnbar_pro",
          canonicalProductID: String(lineItem.productId),
          tierRank: 1,
        },
        expiresAtMillis:
          typeof lineItem.expiryTime === "string" ? Date.parse(lineItem.expiryTime) : Date.now() + 60_000,
      };
    },
    sha256Hex: (value: string) => createHash("sha256").update(value).digest("hex"),
    stripUndefinedObject: actualGuards.stripUndefinedObject,
    writeBurnBarProEntitlement: state.writeEntitlement,
  };
});

import { processGooglePlayDeveloperNotification } from "../googlePlayRtdn.js";

const FUTURE_EXPIRY = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();

function tokenHash(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function eventPath(eventID: string): string {
  return `google_play_rtdn_events/${eventID}`;
}

describe("Google Play RTDN", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.documents.clear();
    state.writes.length = 0;
    state.transactionTail = Promise.resolve();
    state.reconcileTopUp.mockResolvedValue({
      adjusted: true,
      reversedUnits: 100,
      deltaUnits: 100,
      monthKey: "2026-07",
    });
    state.writeEntitlement.mockResolvedValue({});
    state.subscriptionsGet.mockResolvedValue({
      data: {
        subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
        lineItems: [{ productId: "cloud-monthly", expiryTime: FUTURE_EXPIRY }],
      },
    });
  });

  it("accepts a Play Console test notification without calling the Developer API", async () => {
    await processGooglePlayDeveloperNotification(
      {
        packageName: "com.openburnbar",
        eventTimeMillis: String(Date.now()),
        testNotification: { version: "1.0" },
      },
      { eventID: "event-test" },
    );
    expect(state.documents.get(eventPath("event-test"))).toMatchObject({
      status: "processed",
      notificationKind: "test",
      testNotification: true,
    });
    expect(state.subscriptionsGet).not.toHaveBeenCalled();
  });

  it("rejects a notification for another package", async () => {
    await processGooglePlayDeveloperNotification(
      {
        packageName: "com.attacker",
        eventTimeMillis: String(Date.now()),
        testNotification: { version: "1.0" },
      },
      { eventID: "event-package-mismatch" },
    );
    expect(state.documents.get(eventPath("event-package-mismatch"))).toMatchObject({
      status: "rejected",
      reason: "package_mismatch",
    });
  });

  it("acknowledges an unclaimed token without persisting the raw purchase token", async () => {
    const token = "raw-purchase-token-that-must-not-persist";
    await processGooglePlayDeveloperNotification(
      {
        packageName: "com.openburnbar",
        eventTimeMillis: String(Date.now()),
        subscriptionNotification: {
          notificationType: 2,
          purchaseToken: token,
          subscriptionId: "cloud-monthly",
        },
      },
      { eventID: "event-unclaimed" },
    );
    expect(state.documents.get(eventPath("event-unclaimed"))).toMatchObject({
      status: "ignored",
      reason: "unclaimed_purchase_token",
      purchaseTokenHash: tokenHash(token),
    });
    expect(JSON.stringify([...state.documents.values()])).not.toContain(token);
  });

  it("reconciles a claimed canceled subscription as active through its paid expiry", async () => {
    const token = "claimed-subscription-token";
    const hash = tokenHash(token);
    state.documents.set(`google_play_token_claims/${hash}`, {
      uid: "user-123",
      productID: "cloud-monthly",
      kind: "subscription",
    });
    state.subscriptionsGet.mockResolvedValueOnce({
      data: {
        subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
        lineItems: [{ productId: "cloud-monthly", expiryTime: FUTURE_EXPIRY }],
      },
    });

    await processGooglePlayDeveloperNotification(
      {
        packageName: "com.openburnbar",
        eventTimeMillis: String(Date.now()),
        subscriptionNotification: {
          notificationType: 3,
          purchaseToken: token,
          subscriptionId: "cloud-monthly",
        },
      },
      { eventID: "event-canceled" },
    );

    expect(state.subscriptionsGet).toHaveBeenCalledWith({
      packageName: "com.openburnbar",
      token,
    });
    expect(state.writeEntitlement).toHaveBeenCalledWith(
      expect.objectContaining({
        uid: "user-123",
        productID: "cloud-monthly",
        source: "google_play_verified",
        activeOverride: true,
        purchaseTokenHash: hash,
        sourceEventID: "event-canceled",
      }),
    );
    expect(state.documents.get(eventPath("event-canceled"))).toMatchObject({
      status: "processed",
      purchaseTokenHash: hash,
      uid: "user-123",
    });
    expect(JSON.stringify([...state.documents.values()])).not.toContain(token);
  });

  it("fully reverses a claimed top-up when Play voids the purchase", async () => {
    const token = "voided-topup-token";
    const hash = tokenHash(token);
    state.documents.set(`google_play_token_claims/${hash}`, {
      uid: "user-topup",
      productID: "agent-actions-100",
      kind: "topup",
    });

    await processGooglePlayDeveloperNotification(
      {
        packageName: "com.openburnbar",
        eventTimeMillis: String(Date.now()),
        voidedPurchaseNotification: {
          purchaseToken: token,
          orderId: "order-redacted",
          productType: 2,
          refundType: 1,
        },
      },
      { eventID: "event-voided-topup" },
    );

    expect(state.reconcileTopUp).toHaveBeenCalledWith(
      expect.objectContaining({
        uid: "user-topup",
        receiptID: `google_play_${hash}`,
        fullReversalReason: "google_play_voided_purchase",
        sourceEventID: "event-voided-topup",
      }),
    );
    expect(state.documents.get(eventPath("event-voided-topup"))).toMatchObject({
      status: "processed",
      claimKind: "topup",
    });
  });

  it("does not reprocess an already-terminal event", async () => {
    state.documents.set(eventPath("event-duplicate"), { status: "processed" });
    await processGooglePlayDeveloperNotification(
      {
        packageName: "com.openburnbar",
        eventTimeMillis: String(Date.now()),
        testNotification: { version: "1.0" },
      },
      { eventID: "event-duplicate" },
    );
    expect(state.writes).toHaveLength(0);
  });

  it("reserves concurrent PubSub delivery so the Developer API runs once", async () => {
    const token = "concurrent-subscription-token";
    const hash = tokenHash(token);
    state.documents.set(`google_play_token_claims/${hash}`, {
      uid: "user-concurrent",
      productID: "cloud-monthly",
      kind: "subscription",
    });

    let releaseDeveloperAPI: () => void = () => undefined;
    const developerAPIGate = new Promise<void>((resolve) => {
      releaseDeveloperAPI = resolve;
    });
    let signalDeveloperAPIStarted: () => void = () => undefined;
    const developerAPIStarted = new Promise<void>((resolve) => {
      signalDeveloperAPIStarted = resolve;
    });
    state.subscriptionsGet.mockImplementationOnce(async () => {
      signalDeveloperAPIStarted();
      await developerAPIGate;
      return {
        data: {
          subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
          lineItems: [{ productId: "cloud-monthly", expiryTime: FUTURE_EXPIRY }],
        },
      };
    });
    const payload = {
      packageName: "com.openburnbar",
      eventTimeMillis: String(Date.now()),
      subscriptionNotification: {
        notificationType: 2,
        purchaseToken: token,
        subscriptionId: "cloud-monthly",
      },
    };

    const first = processGooglePlayDeveloperNotification(payload, { eventID: "event-concurrent" });
    await developerAPIStarted;
    // The concurrent delivery must NOT be silently acked while another worker
    // holds the lease: if that worker crashed, an ack would lose the event.
    // Throwing makes Pub/Sub redeliver after the lease expires.
    await expect(
      processGooglePlayDeveloperNotification(payload, { eventID: "event-concurrent" }),
    ).rejects.toThrow(/being processed by another worker/);

    expect(state.subscriptionsGet).toHaveBeenCalledTimes(1);
    expect(state.documents.get(eventPath("event-concurrent"))).toMatchObject({
      status: "processing",
    });

    releaseDeveloperAPI();
    await first;
    expect(state.documents.get(eventPath("event-concurrent"))).toMatchObject({
      status: "processed",
      uid: "user-concurrent",
    });
  });
});
