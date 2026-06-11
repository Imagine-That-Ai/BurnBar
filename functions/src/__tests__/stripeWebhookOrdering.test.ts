import { beforeEach, describe, expect, it, vi } from "vitest";

const firestoreState = vi.hoisted(() => {
  type Doc = Record<string, unknown>;
  const docs = new Map<string, Doc>();

  class FakeDocSnapshot {
    constructor(private readonly value: Doc | undefined) {}

    get exists() {
      return this.value !== undefined;
    }

    data() {
      return this.value === undefined ? undefined : { ...this.value };
    }

    get(field: string) {
      return this.value === undefined ? undefined : this.value[field];
    }
  }

  class FakeDocRef {
    constructor(readonly path: string) {}

    async get() {
      return new FakeDocSnapshot(docs.get(this.path));
    }

    set(data: Doc, options?: { merge?: boolean }) {
      const next = options?.merge ? { ...(docs.get(this.path) ?? {}) } : {};
      for (const [key, value] of Object.entries(data)) {
        if (typeof value === "object" && value !== null && value.constructor.name === "DeleteTransform") {
          delete next[key];
        } else {
          next[key] = value;
        }
      }
      docs.set(this.path, next);
      return Promise.resolve();
    }
  }

  const db = {
    doc: (path: string) => new FakeDocRef(path),
    runTransaction: async <T>(
      fn: (transaction: {
        get: (ref: FakeDocRef) => ReturnType<FakeDocRef["get"]>;
        set: (ref: FakeDocRef, data: Doc, options?: { merge?: boolean }) => void;
      }) => Promise<T>,
    ): Promise<T> =>
      fn({
        get: (ref) => ref.get(),
        set: (ref, data, options) => {
          void ref.set(data, options);
        },
      }),
  };

  return { docs, db };
});

vi.mock("../adminRuntime.js", () => ({
  auth: {},
  db: firestoreState.db,
}));

vi.mock("../cloudProAllowanceRemoteConfig.js", () => ({
  loadCloudProAllowanceConfig: vi.fn(),
}));

import type Stripe from "stripe";

import {
  applyStripeCheckoutSession,
  BURNBAR_PRO_ENTITLEMENT_ID,
  writeBurnBarProEntitlement,
} from "../callables/shared.js";
import {
  markStripeWebhookEventFailed,
  markStripeWebhookEventProcessed,
  reserveStripeWebhookEvent,
} from "../callables/stripe.js";

const UID = "stripe-user-1";
const SUBSCRIPTION_ID = "sub_ordering_1";
const ENTITLEMENT_PATH = `users/${UID}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`;

function activeSubscriptionWrite(overrides: Partial<Parameters<typeof writeBurnBarProEntitlement>[0]> = {}) {
  return writeBurnBarProEntitlement({
    uid: UID,
    productID: "com.openburnbar.pro.monthly",
    expiresAtMillis: Date.parse("2026-07-10T00:00:00.000Z"),
    source: "stripe_webhook_verified",
    platform: "stripe",
    externalSubscriptionID: SUBSCRIPTION_ID,
    rawStatus: "active",
    environment: "Production",
    activeOverride: true,
    ...overrides,
  });
}

beforeEach(() => {
  firestoreState.docs.clear();
});

describe("Stripe webhook entitlement ordering", () => {
  it("keeps a cancellation when a stale active subscription update replays later", async () => {
    await writeBurnBarProEntitlement({
      uid: UID,
      productID: "com.openburnbar.pro.monthly",
      expiresAtMillis: Date.parse("2026-06-10T00:00:00.000Z"),
      source: "stripe_webhook_verified",
      platform: "stripe",
      externalSubscriptionID: SUBSCRIPTION_ID,
      rawStatus: "canceled",
      environment: "Production",
      activeOverride: false,
      sourceEventID: "evt_deleted",
      sourceEventCreatedMillis: 2_000,
    });

    await writeBurnBarProEntitlement({
      uid: UID,
      productID: "com.openburnbar.pro.monthly",
      expiresAtMillis: Date.parse("2026-07-10T00:00:00.000Z"),
      source: "stripe_webhook_verified",
      platform: "stripe",
      externalSubscriptionID: SUBSCRIPTION_ID,
      rawStatus: "active",
      environment: "Production",
      activeOverride: true,
      sourceEventID: "evt_stale_update",
      sourceEventCreatedMillis: 1_000,
    });

    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.active).toBe(false);
    expect(entitlement?.rawStatus).toBe("canceled");
    expect(entitlement?.sourceEventID).toBe("evt_deleted");
    expect(entitlement?.sourceEventCreatedMillis).toBe(2_000);
  });

  it("preserves the watermark when a write carries none (checkout-path erasure regression, LB-5)", async () => {
    await activeSubscriptionWrite({ sourceEventID: "evt_first", sourceEventCreatedMillis: 2_000 });

    // A write with no event context (the pre-fix checkout path, or any
    // non-webhook caller) must still apply — and must NOT erase the
    // watermark, or the next buffered stale event would sail through.
    await activeSubscriptionWrite({
      expiresAtMillis: Date.parse("2026-08-10T00:00:00.000Z"),
      rawStatus: "active_renewed",
    });

    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.rawStatus).toBe("active_renewed");
    expect(entitlement?.expiresAt).toBe("2026-08-10T00:00:00.000Z");
    expect(entitlement?.sourceEventID).toBe("evt_first");
    expect(entitlement?.sourceEventCreatedMillis).toBe(2_000);

    // The preserved watermark still rejects the stale replay.
    await activeSubscriptionWrite({
      rawStatus: "stale_replay",
      activeOverride: false,
      sourceEventID: "evt_stale",
      sourceEventCreatedMillis: 1_000,
    });
    expect(firestoreState.docs.get(ENTITLEMENT_PATH)?.rawStatus).toBe("active_renewed");
  });

  it("rejects a same-second write from a DIFFERENT event (second-granularity tie-break)", async () => {
    await writeBurnBarProEntitlement({
      uid: UID,
      productID: "com.openburnbar.pro.monthly",
      expiresAtMillis: Date.parse("2026-06-10T00:00:00.000Z"),
      source: "stripe_webhook_verified",
      platform: "stripe",
      externalSubscriptionID: SUBSCRIPTION_ID,
      rawStatus: "canceled",
      environment: "Production",
      activeOverride: false,
      sourceEventID: "evt_deleted",
      sourceEventCreatedMillis: 2_000,
    });

    // Stripe's event.created is second-granular: a stale update sharing the
    // cancellation's second used to slip past the strict > watermark check
    // and resurrect the entitlement.
    await activeSubscriptionWrite({
      rawStatus: "stale_same_second",
      sourceEventID: "evt_stale_update",
      sourceEventCreatedMillis: 2_000,
    });

    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.active).toBe(false);
    expect(entitlement?.rawStatus).toBe("canceled");
    expect(entitlement?.sourceEventID).toBe("evt_deleted");
  });

  it("re-applies a redelivery of the SAME event id (idempotent, not blocked by the tie-break)", async () => {
    await activeSubscriptionWrite({ sourceEventID: "evt_same", sourceEventCreatedMillis: 2_000 });

    // The webhook re-fetches the subscription, so a redelivered event can
    // legitimately carry fresher state under the same event id.
    await activeSubscriptionWrite({
      expiresAtMillis: Date.parse("2026-09-10T00:00:00.000Z"),
      rawStatus: "active_refetched",
      sourceEventID: "evt_same",
      sourceEventCreatedMillis: 2_000,
    });

    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.rawStatus).toBe("active_refetched");
    expect(entitlement?.expiresAt).toBe("2026-09-10T00:00:00.000Z");
  });
});

describe("Stripe checkout watermark stamping", () => {
  it("stamps the checkout event's watermark on the entitlement so later stale events are rejected", async () => {
    const eventCreatedMillis = Date.parse("2026-06-11T10:00:05.000Z");
    const periodEndSeconds = Math.floor(Date.parse("2030-01-01T00:00:00.000Z") / 1000);
    const retrieve = vi.fn(async () => ({
      id: SUBSCRIPTION_ID,
      status: "active",
      customer: "cus_checkout_1",
      metadata: { firebaseUID: UID },
      current_period_end: periodEndSeconds,
      items: { data: [] },
    }));
    const stripe = { subscriptions: { retrieve } } as unknown as Stripe;
    const session = {
      id: "cs_test_1",
      metadata: { firebaseUID: UID },
      subscription: SUBSCRIPTION_ID,
      payment_status: "paid",
    } as unknown as Stripe.Checkout.Session;

    await applyStripeCheckoutSession(stripe, session, {
      eventID: "evt_checkout_1",
      eventCreatedMillis,
    });

    // The subscription was re-fetched fresh, so stamping the checkout
    // event's watermark is safe (state is at least as new as event.created).
    expect(retrieve).toHaveBeenCalledWith(SUBSCRIPTION_ID);
    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.active).toBe(true);
    expect(entitlement?.sourceEventID).toBe("evt_checkout_1");
    expect(entitlement?.sourceEventCreatedMillis).toBe(eventCreatedMillis);

    // A buffered pre-checkout subscription event can no longer rewind it.
    await activeSubscriptionWrite({
      rawStatus: "stale_pre_checkout",
      activeOverride: false,
      sourceEventID: "evt_pre_checkout",
      sourceEventCreatedMillis: eventCreatedMillis - 5_000,
    });
    expect(firestoreState.docs.get(ENTITLEMENT_PATH)?.active).toBe(true);
    expect(firestoreState.docs.get(ENTITLEMENT_PATH)?.sourceEventID).toBe("evt_checkout_1");
  });
});

describe("stripe_webhook_events ledger TTL", () => {
  const RETENTION_MS = 90 * 24 * 60 * 60 * 1000;

  function fakeEvent(id: string, createdSeconds: number): Stripe.Event {
    return { id, type: "customer.subscription.updated", created: createdSeconds } as unknown as Stripe.Event;
  }

  function ledgerExpireAtMillis(eventID: string): number | undefined {
    const doc = firestoreState.docs.get(`stripe_webhook_events/${eventID}`);
    const expireAt = doc?.expireAt as { toMillis?: () => number } | undefined;
    return typeof expireAt?.toMillis === "function" ? expireAt.toMillis() : undefined;
  }

  it("writes expireAt = event time + 90 days on reserve, processed, and failed ledger writes", async () => {
    const createdSeconds = Math.floor(Date.parse("2026-06-11T09:00:00.000Z") / 1000);
    const expected = createdSeconds * 1000 + RETENTION_MS;

    const processedEvent = fakeEvent("evt_ledger_processed", createdSeconds);
    await reserveStripeWebhookEvent(processedEvent);
    expect(ledgerExpireAtMillis("evt_ledger_processed")).toBe(expected);
    await markStripeWebhookEventProcessed(processedEvent);
    const processedDoc = firestoreState.docs.get("stripe_webhook_events/evt_ledger_processed");
    expect(processedDoc?.status).toBe("processed");
    expect(ledgerExpireAtMillis("evt_ledger_processed")).toBe(expected);

    const failedEvent = fakeEvent("evt_ledger_failed", createdSeconds);
    await reserveStripeWebhookEvent(failedEvent);
    await markStripeWebhookEventFailed(failedEvent, new Error("handler exploded"));
    const failedDoc = firestoreState.docs.get("stripe_webhook_events/evt_ledger_failed");
    expect(failedDoc?.status).toBe("failed");
    expect(ledgerExpireAtMillis("evt_ledger_failed")).toBe(expected);
  });
});
