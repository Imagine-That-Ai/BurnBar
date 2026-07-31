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

    collection(name: string) {
      return {
        doc: (id: string) => new FakeDocRef(`${this.path}/${name}/${id}`),
      };
    }

    async get() {
      return new FakeDocSnapshot(docs.get(this.path));
    }

    set(data: Doc, options?: { merge?: boolean }) {
      const next = options?.merge ? { ...(docs.get(this.path) ?? {}) } : {};
      for (const [key, value] of Object.entries(data)) {
        if (typeof value === "object" && value !== null && value.constructor.name === "NumericIncrementTransform") {
          const operand = Reflect.get(value, "operand");
          const prior = typeof next[key] === "number" ? next[key] : 0;
          next[key] = prior + (typeof operand === "number" ? operand : 0);
        } else {
          next[key] = value;
        }
      }
      docs.set(this.path, next);
    }
  }

  const db = {
    doc: (path: string) => new FakeDocRef(path),
    runTransaction: async <T>(
      operation: (transaction: {
        get: (ref: FakeDocRef) => ReturnType<FakeDocRef["get"]>;
        set: (ref: FakeDocRef, data: Doc, options?: { merge?: boolean }) => void;
      }) => Promise<T>,
    ): Promise<T> =>
      operation({
        get: (ref) => ref.get(),
        set: (ref, data, options) => ref.set(data, options),
      }),
  };

  return { db, docs };
});

vi.mock("../adminRuntime.js", () => ({
  db: firestoreState.db,
}));

import { reconcileCloudProTopUpReversal } from "../callables/shared/entitlements.js";

const UID = "google-play-user";

describe("Google Play top-up reversal", () => {
  beforeEach(() => {
    firestoreState.docs.clear();
  });

  it("fully reverses a voided top-up without refund amount metadata", async () => {
    const receiptID = "google_play_voided_topup_1";
    const monthKey = "2026-07";
    const receiptPath = `users/${UID}/billing/cloud_pro_topups/receipts/${receiptID}`;
    const allowancePath = `users/${UID}/billing/allowances/months/${monthKey}`;
    firestoreState.docs.set(receiptPath, {
      uid: UID,
      firstMonthKey: monthKey,
      latestMonthKey: monthKey,
      meter: "hosted_actions",
      units: 100,
      reversedUnits: 0,
    });
    firestoreState.docs.set(allowancePath, { topupActionsPurchased: 100 });

    const reversal = await reconcileCloudProTopUpReversal({
      uid: UID,
      receiptID,
      fullReversalReason: "google_play_voided_purchase",
      sourceEventID: "play-event-1",
      sourceEventCreatedMillis: 12_000,
    });

    expect(reversal).toMatchObject({
      adjusted: true,
      reversedUnits: 100,
      deltaUnits: 100,
      monthKey,
    });
    expect(firestoreState.docs.get(allowancePath)?.topupActionsPurchased).toBe(0);
    expect(firestoreState.docs.get(receiptPath)).toMatchObject({
      fullReversalReason: "google_play_voided_purchase",
      forcedReversalUnits: 100,
      reversedUnits: 100,
      reversalState: "reversed",
      sourceEventID: "play-event-1",
    });
  });
});
