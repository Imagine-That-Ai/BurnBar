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

import { BURNBAR_PRO_ENTITLEMENT_ID, writeBurnBarProEntitlement } from "../callables/shared.js";

const UID = "stripe-user-1";
const SUBSCRIPTION_ID = "sub_ordering_1";
const ENTITLEMENT_PATH = `users/${UID}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`;

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
});
