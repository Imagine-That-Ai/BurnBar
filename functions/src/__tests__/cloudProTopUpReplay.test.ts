import { beforeEach, describe, expect, it, vi } from "vitest";

type StoredDoc = Record<string, unknown>;

interface DocRef {
  path: string;
  collection(name: string): {
    doc(id: string): DocRef;
  };
  get(): Promise<DocSnapshot>;
}

interface DocSnapshot {
  exists: boolean;
  data(): StoredDoc | undefined;
  get(field: string): unknown;
}

const { dbMock, store } = vi.hoisted(() => {
  const docs = new Map<string, StoredDoc>();

  const isIncrement = (value: unknown): value is { __fieldValue: "increment"; value: number } =>
    Boolean(value && typeof value === "object" && Reflect.get(value, "__fieldValue") === "increment");

  const applySet = (path: string, data: StoredDoc, options?: { merge?: boolean }) => {
    const existing = options?.merge === true ? { ...(docs.get(path) ?? {}) } : {};
    const next: StoredDoc = { ...existing };
    for (const [key, value] of Object.entries(data)) {
      if (isIncrement(value)) {
        const prior = typeof next[key] === "number" ? next[key] : 0;
        next[key] = prior + value.value;
      } else {
        next[key] = value;
      }
    }
    docs.set(path, next);
  };

  const snapshotFor = (path: string): DocSnapshot => ({
    exists: docs.has(path),
    data: () => docs.get(path),
    get: (field: string) => docs.get(path)?.[field],
  });

  const doc = (path: string): DocRef => ({
    path,
    collection: (name: string) => ({
      doc: (id: string) => doc(`${path}/${name}/${id}`),
    }),
    get: async () => snapshotFor(path),
  });

  const db = {
    doc,
    runTransaction: async <T>(fn: (transaction: unknown) => Promise<T>): Promise<T> =>
      fn({
        get: async (ref: DocRef) => snapshotFor(ref.path),
        set: (ref: DocRef, data: StoredDoc, options?: { merge?: boolean }) => {
          applySet(ref.path, data, options);
        },
      }),
  };

  return { dbMock: db, store: docs };
});

vi.mock("firebase-admin/firestore", () => ({
  FieldValue: {
    increment: (value: number) => ({ __fieldValue: "increment", value }),
  },
  Timestamp: {
    now: () => ({ iso: new Date().toISOString() }),
    fromMillis: (millis: number) => ({ millis }),
  },
}));

vi.mock("../adminRuntime.js", () => ({
  db: dbMock,
}));

vi.mock("../cloudFeatureSuspensions.js", () => ({
  assertCloudFeatureNotSuspended: vi.fn(async () => undefined),
}));

vi.mock("../cloudProAllowanceRemoteConfig.js", () => ({
  loadCloudProAllowanceConfig: vi.fn(async () => ({
    includedHostedActionsMonthly: 500,
    includedRelayGBMonthly: 50,
    includedFusionSearchesMonthly: 100,
    includedUltraFusionSearchesMonthly: 300,
    actionTopUpUnit: 100,
    relayTopUpUnitGB: 50,
    fusionSearchTopUpUnit: 100,
    fusionSearchLargeTopUpUnit: 500,
    monthlyHostedActionCap: 2_000,
    monthlyRelayGBCap: 300,
    monthlyFusionSearchCap: 1_000,
    monthlyUltraFusionSearchCap: 2_000,
  })),
}));

import { BURNBAR_PRO_MAX_ENTITLEMENT_ID, creditCloudProTopUp } from "../callables/shared/entitlements.js";

const UID = "uid-topup-replay";
const PAYMENT_ID = "google-pay-token-hash";

function seedCloudProEntitlement() {
  store.set(`users/${UID}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`, {
    active: true,
    productID: "com.openburnbar.proMax.v2.monthly",
    expiresAt: "2999-01-01T00:00:00.000Z",
  });
}

describe("Cloud Pro top-up replay accounting", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-06-15T12:00:00.000Z"));
    store.clear();
    seedCloudProEntitlement();
  });

  it("does not re-credit the same external payment in a later month", async () => {
    const first = await creditCloudProTopUp({
      uid: UID,
      kind: "agent_control_actions_100",
      source: "google_play",
      externalPaymentID: PAYMENT_ID,
    });

    expect(first).toMatchObject({
      credited: true,
      monthKey: "2026-06",
      units: 100,
      kind: "agent_control_actions_100",
    });
    expect(store.get(`users/${UID}/billing/allowances/months/2026-06`)?.topupActionsPurchased).toBe(100);
    expect(store.has(`users/${UID}/billing/cloud_pro_topups/receipts/google_play_${PAYMENT_ID}`)).toBe(true);

    vi.setSystemTime(new Date("2026-07-02T12:00:00.000Z"));

    const replay = await creditCloudProTopUp({
      uid: UID,
      kind: "agent_control_actions_100",
      source: "google_play",
      externalPaymentID: PAYMENT_ID,
    });

    expect(replay).toMatchObject({
      credited: false,
      monthKey: "2026-07",
      units: 100,
      kind: "agent_control_actions_100",
    });
    expect(store.get(`users/${UID}/billing/allowances/months/2026-06`)?.topupActionsPurchased).toBe(100);
    expect(store.get(`users/${UID}/billing/allowances/months/2026-07`)?.topupActionsPurchased).toBeUndefined();
    expect(store.has(`users/${UID}/billing/allowances/months/2026-07/topups/google_play_${PAYMENT_ID}`)).toBe(false);
  });
});
