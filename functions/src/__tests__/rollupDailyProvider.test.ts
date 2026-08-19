/**
 * Per-day per-provider token map (`dailyProviderTokens`) on the all_time
 * rollup doc.
 *
 * Pins the rolling nested map on the `usage_counter_totals/all_time` counter
 * doc (`addContribution`), the reference vs pending-delta queue-drain
 * equivalence, the legacy fallback that rebuilds the map from day-doc
 * `providers` subcollections (with the updatedAt-moved guard), and the
 * omit-when-empty output contract. The in-memory Firestore mirrors the fake
 * in rollupExecutionSource.test.ts (same set() merge / FieldValue.increment
 * semantics).
 */
import { describe, expect, it } from "vitest";
import { FieldValue, type Firestore } from "firebase-admin/firestore";

import { applyUsageCounterDelta, COUNTER_SCHEMA_VERSION } from "../rollupCounters.js";
import { computeUserRollupsFromCounters, rebuildUserRollupCounters } from "../rollupCompute.js";
import { drainPendingCounterDeltas, enqueueUsageCounterDelta } from "../rollupPendingDeltas.js";
import type { UsageEventDoc } from "../types.js";

type Doc = Record<string, unknown>;

const DELETE = Symbol("firestore-delete");

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype;
}

function mergeValue(existing: unknown, value: unknown, merge: boolean): unknown {
  if (value instanceof FieldValue) {
    const operand = Object.getOwnPropertyDescriptor(value, "operand")?.value;
    if (typeof operand === "number") {
      return (typeof existing === "number" ? existing : 0) + operand;
    }
    return DELETE;
  }
  if (isPlainObject(value)) {
    const base: Doc = merge && isPlainObject(existing) ? { ...existing } : {};
    for (const [key, entry] of Object.entries(value)) {
      const next = mergeValue(base[key], entry, merge);
      if (next === DELETE) delete base[key];
      else base[key] = next;
    }
    return base;
  }
  return value;
}

class FakeDocRef {
  constructor(
    private readonly fake: FakeFirestore,
    readonly path: string,
  ) {}

  get id(): string {
    return this.path.split("/").at(-1) ?? "";
  }

  async get() {
    const data = this.fake.store.get(this.path);
    return { exists: data !== undefined, data: () => (data === undefined ? undefined : { ...data }) };
  }

  set(data: Doc, options?: { merge?: boolean }) {
    const merge = options?.merge === true;
    const next: Doc = merge ? { ...(this.fake.store.get(this.path) ?? {}) } : {};
    for (const [key, value] of Object.entries(data)) {
      const merged = mergeValue(next[key], value, merge);
      if (merged === DELETE) delete next[key];
      else next[key] = merged;
    }
    this.fake.store.set(this.path, next);
    return Promise.resolve();
  }

  delete() {
    this.fake.store.delete(this.path);
    return Promise.resolve();
  }

  collection(name: string) {
    return new FakeCollectionRef(this.fake, `${this.path}/${name}`);
  }
}

class FakeCollectionRef {
  constructor(
    private readonly fake: FakeFirestore,
    readonly path: string,
    private readonly limitCount?: number,
    private readonly startAfterId?: string,
  ) {}

  doc(id: string) {
    return new FakeDocRef(this.fake, `${this.path}/${id}`);
  }

  where() {
    return this;
  }

  orderBy() {
    return this;
  }

  limit(count: number) {
    return new FakeCollectionRef(this.fake, this.path, count, this.startAfterId);
  }

  startAfter(doc: { id: string }) {
    return new FakeCollectionRef(this.fake, this.path, this.limitCount, doc.id);
  }

  async get() {
    const prefix = `${this.path}/`;
    const docs = [...this.fake.store.keys()]
      .filter((path) => path.startsWith(prefix) && !path.slice(prefix.length).includes("/"))
      .map((path) => ({ id: path.slice(prefix.length), path }))
      .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
      .filter((entry) => !this.startAfterId || entry.id > this.startAfterId)
      .slice(0, this.limitCount)
      .map((entry) => ({
        id: entry.id,
        ref: new FakeDocRef(this.fake, entry.path),
        data: () => ({ ...(this.fake.store.get(entry.path) ?? {}) }),
      }));
    return { empty: docs.length === 0, docs };
  }
}

class FakeFirestore {
  readonly store = new Map<string, Doc>();

  doc(path: string) {
    return new FakeDocRef(this, path);
  }

  collection(path: string) {
    return new FakeCollectionRef(this, path);
  }

  recursiveDelete(collection: FakeCollectionRef) {
    const prefix = `${collection.path}/`;
    for (const path of [...this.store.keys()]) {
      if (path.startsWith(prefix)) this.store.delete(path);
    }
    return Promise.resolve();
  }

  batch() {
    const ops: Array<() => Promise<void>> = [];
    return {
      set: (ref: FakeDocRef, data: Doc, options?: { merge?: boolean }) => {
        ops.push(() => ref.set(data, options));
      },
      commit: async () => {
        for (const op of ops) await op();
      },
    };
  }

  async runTransaction<T>(
    fn: (transaction: {
      get: (ref: FakeDocRef) => ReturnType<FakeDocRef["get"]>;
      getAll: (...refs: FakeDocRef[]) => Promise<Awaited<ReturnType<FakeDocRef["get"]>>[]>;
      set: (ref: FakeDocRef, data: Doc, options?: { merge?: boolean }) => void;
      delete: (ref: FakeDocRef) => void;
    }) => Promise<T>,
  ): Promise<T> {
    return fn({
      get: (ref) => ref.get(),
      getAll: (...refs) => Promise.all(refs.map((ref) => ref.get())),
      set: (ref, data, options) => {
        void ref.set(data, options);
      },
      delete: (ref) => {
        void ref.delete();
      },
    });
  }

  asFirestore(): Firestore {
    // The engine takes the nominal admin Firestore class, while this test fake
    // is intentionally structural (same pattern as rollupExecutionSource.test.ts).
    return Object.create(this);
  }
}

const UID = "u-daily-provider";
const ALL_TIME_PATH = `users/${UID}/usage_counter_totals/all_time`;
const DAY_A = "2026-06-09";
const DAY_B = "2026-06-08";
const T_A = `${DAY_A}T12:00:00.000Z`;
const T_B = `${DAY_B}T12:00:00.000Z`;

function usageEvent(overrides: Partial<UsageEventDoc> = {}): UsageEventDoc {
  return {
    provider: "codex",
    providerID: "codex",
    schemaVersion: 1,
    sessionId: "codex-session-1",
    model: "gpt-5.5",
    inputTokens: 100,
    outputTokens: 25,
    totalTokens: 125,
    cost: 0.001,
    recordedAt: T_A,
    startTime: T_A,
    ...overrides,
  };
}

function seedUsageDocs(fake: FakeFirestore): void {
  fake.store.set(`users/${UID}/usage/000000`, { ...usageEvent() });
  fake.store.set(`users/${UID}/usage/000001`, {
    ...usageEvent({
      provider: "claude-code",
      providerID: "claude-code",
      sessionId: "claude-code-session-1",
      model: "claude-opus-4.7",
      totalTokens: 200,
    }),
  });
  fake.store.set(`users/${UID}/usage/000002`, {
    ...usageEvent({ sessionId: "codex-session-2", recordedAt: T_B, startTime: T_B }),
  });
}

const EXPECTED_MAP = {
  [DAY_A]: { codex: 125, "claude-code": 200 },
  [DAY_B]: { codex: 125 },
};

describe("dailyProviderTokens rolling counter map", () => {
  it("addContribution increments the nested per-day per-provider map on the all_time totals doc", async () => {
    const fake = new FakeFirestore();
    seedUsageDocs(fake);
    await rebuildUserRollupCounters(fake.asFirestore(), UID, { pageSize: 500 });

    const totals = fake.store.get(ALL_TIME_PATH);
    expect(totals?.schemaVersion).toBe(COUNTER_SCHEMA_VERSION);
    expect(totals?.dailyProviderTokens).toEqual(EXPECTED_MAP);
    expect(totals?.dailyTokens).toEqual({ [DAY_A]: 325, [DAY_B]: 125 });
  });

  it("emits identical dailyProviderTokens from the reference and pending-delta queue-drain paths", async () => {
    const events = [
      usageEvent(),
      usageEvent({
        provider: "claude-code",
        providerID: "claude-code",
        sessionId: "claude-code-session-1",
        model: "claude-opus-4.7",
        totalTokens: 200,
      }),
      usageEvent({ sessionId: "codex-session-2", recordedAt: T_B, startTime: T_B }),
    ];

    const reference = new FakeFirestore();
    for (const [index, event] of events.entries()) {
      await applyUsageCounterDelta(reference.asFirestore(), UID, `usage-${index}`, undefined, event);
    }

    const queued = new FakeFirestore();
    for (const [index, event] of events.entries()) {
      await enqueueUsageCounterDelta(queued.asFirestore(), UID, `usage-${index}`, undefined, event);
    }
    await drainPendingCounterDeltas(queued.asFirestore(), UID);

    expect(queued.store.get(ALL_TIME_PATH)?.dailyProviderTokens).toEqual(
      reference.store.get(ALL_TIME_PATH)?.dailyProviderTokens,
    );

    const referenceRollups = await computeUserRollupsFromCounters(reference.asFirestore(), UID);
    const queuedRollups = await computeUserRollupsFromCounters(queued.asFirestore(), UID);
    expect(queuedRollups.all_time.dailyProviderTokens).toEqual(EXPECTED_MAP);
    expect(queuedRollups.all_time.dailyProviderTokens).toEqual(referenceRollups.all_time.dailyProviderTokens);
  });

  it("puts dailyProviderTokens on the all_time window only", async () => {
    const fake = new FakeFirestore();
    seedUsageDocs(fake);
    await rebuildUserRollupCounters(fake.asFirestore(), UID, { pageSize: 500 });

    const rollups = await computeUserRollupsFromCounters(fake.asFirestore(), UID);

    expect(rollups.all_time.dailyProviderTokens).toEqual(EXPECTED_MAP);
    for (const key of ["today", "7d", "30d", "90d"] as const) {
      expect("dailyProviderTokens" in rollups[key]).toBe(false);
    }
  });

  it("legacy totals docs fall back to the day-doc providers subcollections and persist the derived map", async () => {
    const fake = new FakeFirestore();
    seedUsageDocs(fake);
    await rebuildUserRollupCounters(fake.asFirestore(), UID, { pageSize: 500 });
    // Simulate a totals doc written before the map existed (schema v2).
    const legacyTotals = { ...fake.store.get(ALL_TIME_PATH) };
    delete legacyTotals.dailyProviderTokens;
    fake.store.set(ALL_TIME_PATH, legacyTotals);

    const rollups = await computeUserRollupsFromCounters(fake.asFirestore(), UID);

    expect(rollups.all_time.dailyProviderTokens).toEqual(EXPECTED_MAP);
    expect(fake.store.get(ALL_TIME_PATH)?.dailyProviderTokens).toEqual(EXPECTED_MAP);
  });

  it("skips the fallback persist when a counter write lands mid-scan (updatedAt moved)", async () => {
    const fake = new FakeFirestore();
    seedUsageDocs(fake);
    await rebuildUserRollupCounters(fake.asFirestore(), UID, { pageSize: 500 });
    const legacyTotals = { ...fake.store.get(ALL_TIME_PATH) };
    delete legacyTotals.dailyProviderTokens;
    fake.store.set(ALL_TIME_PATH, legacyTotals);

    // The fallback scans usage_counter_days without a where() filter; the
    // 90-day union query filters by documentId. Mutate updatedAt only on the
    // unfiltered scan to simulate an in-flight increment.
    const originalCollection = fake.collection.bind(fake);
    fake.collection = (path: string) => {
      const result = originalCollection(path);
      if (path === `users/${UID}/usage_counter_days`) {
        let filtered = false;
        const originalWhere = result.where.bind(result);
        result.where = () => {
          filtered = true;
          return originalWhere();
        };
        const originalGet = result.get.bind(result);
        result.get = async () => {
          const snapshot = await originalGet();
          if (!filtered) {
            fake.store.set(ALL_TIME_PATH, {
              ...fake.store.get(ALL_TIME_PATH),
              updatedAt: "2099-01-01T00:00:00.000Z",
            });
          }
          return snapshot;
        };
      }
      return result;
    };

    const rollups = await computeUserRollupsFromCounters(fake.asFirestore(), UID);
    fake.collection = originalCollection;

    // The computed doc still carries the map; the stale absolute write is skipped.
    expect(rollups.all_time.dailyProviderTokens).toEqual(EXPECTED_MAP);
    expect(fake.store.get(ALL_TIME_PATH)?.dailyProviderTokens).toBeUndefined();

    // The next pass persists the backfill once the totals doc is quiet.
    const retried = await computeUserRollupsFromCounters(fake.asFirestore(), UID);
    expect(retried.all_time.dailyProviderTokens).toEqual(EXPECTED_MAP);
    expect(fake.store.get(ALL_TIME_PATH)?.dailyProviderTokens).toEqual(EXPECTED_MAP);
  });

  it("omits the field entirely when there is no provider-attributed usage", async () => {
    const fake = new FakeFirestore();

    const rollups = await computeUserRollupsFromCounters(fake.asFirestore(), UID);

    for (const key of ["today", "7d", "30d", "90d", "all_time"] as const) {
      expect("dailyProviderTokens" in rollups[key]).toBe(false);
    }
  });

  it("omits days/providers whose tokens decrement back to zero", async () => {
    const fake = new FakeFirestore();
    const event = usageEvent();
    await applyUsageCounterDelta(fake.asFirestore(), UID, "usage-0", undefined, event);
    await applyUsageCounterDelta(fake.asFirestore(), UID, "usage-0", event, undefined);

    // The rolling map keeps the zeroed entry (like dailyTokens)…
    expect(fake.store.get(ALL_TIME_PATH)?.dailyProviderTokens).toEqual({ [DAY_A]: { codex: 0 } });

    // …but the rollup output filters it and omits the now-empty field.
    const rollups = await computeUserRollupsFromCounters(fake.asFirestore(), UID);
    expect("dailyProviderTokens" in rollups.all_time).toBe(false);
  });
});
