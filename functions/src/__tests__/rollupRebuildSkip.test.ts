/**
 * Regression: routine dashboard refreshes must not pay for a full counter
 * rebuild (crosscut-001).
 *
 * The `rebuildUsageRollups` callable used to run `computeUserRollups`
 * unconditionally: recursiveDelete of all three counter collections plus a
 * full `users/{uid}/usage` history rescan on EVERY stale-dashboard open —
 * and clients flagged rollups stale on wall-clock age alone, so every idle
 * user's app open fired it. `refreshUserRollups` now serves healthy counters
 * with a counters-only recompute and reserves the destructive rebuild for
 * `force` (the clients' repair entry point), a missing job doc, or a recorded
 * incremental-delta failure (`lastErrorCode`) — the scheduled worker's rule.
 * It always rewrites the rollups so `computedAt` advances; serving without
 * the write would leave clients polling the callable on their 60s cooldown.
 */
import { describe, expect, it } from "vitest";
import { FieldValue, type Firestore } from "firebase-admin/firestore";

import { refreshUserRollups, type WindowKey } from "../rollups.js";

type Doc = Record<string, unknown>;

class FakeDocRef {
  constructor(
    private readonly store: Map<string, Doc>,
    readonly path: string,
  ) {}

  async get() {
    const data = this.store.get(this.path);
    return {
      exists: data !== undefined,
      data: () => (data === undefined ? undefined : { ...data }),
    };
  }

  set(data: Doc, options?: { merge?: boolean }) {
    const next: Doc = options?.merge ? { ...(this.store.get(this.path) ?? {}) } : {};
    for (const [key, value] of Object.entries(data)) {
      if (value instanceof FieldValue) {
        // Only FieldValue.delete() flows through this surface.
        delete next[key];
      } else {
        next[key] = value;
      }
    }
    this.store.set(this.path, next);
    return Promise.resolve();
  }
}

class FakeCollectionRef {
  constructor(
    private readonly fake: FakeFirestore,
    readonly path: string,
  ) {}

  // documentId range filters are irrelevant to the fixtures; the production
  // code re-filters hits against its day-id set anyway.
  where() {
    return this;
  }

  // The pending-delta drain pages with limit(); fixtures are tiny.
  limit() {
    return this;
  }

  async get() {
    this.fake.collectionGets.push(this.path);
    const docs = this.fake.collections.get(this.path) ?? [];
    return {
      empty: docs.length === 0,
      docs: docs.map((entry) => ({ id: entry.id, data: () => ({ ...entry.data }) })),
    };
  }
}

class FakeFirestore {
  readonly store = new Map<string, Doc>();
  readonly collections = new Map<string, Array<{ id: string; data: Doc }>>();
  readonly collectionGets: string[] = [];
  readonly recursiveDeletes: string[] = [];

  doc(path: string) {
    return new FakeDocRef(this.store, path);
  }

  collection(path: string) {
    return new FakeCollectionRef(this, path);
  }

  recursiveDelete(collection: FakeCollectionRef) {
    this.recursiveDeletes.push(collection.path);
    this.collections.delete(collection.path);
    for (const path of [...this.store.keys()]) {
      if (path.startsWith(`${collection.path}/`)) this.store.delete(path);
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
      set: (ref: FakeDocRef, data: Doc, options?: { merge?: boolean }) => void;
    }) => Promise<T>,
  ): Promise<T> {
    return fn({
      get: (ref) => ref.get(),
      set: (ref, data, options) => {
        void ref.set(data, options);
      },
    });
  }

  asFirestore(): Firestore {
    // `refreshUserRollups` takes the nominal admin `Firestore` class, which a
    // structural in-memory fake can never satisfy; widen through `unknown`.
    return this as unknown as Firestore;
  }
}

const UID = "u1";
const JOB_PATH = `users/${UID}/rollup_jobs/current`;
const USAGE_PATH = `users/${UID}/usage`;
const ALL_TIME_PATH = `users/${UID}/usage_counter_totals/all_time`;
const COUNTER_COLLECTIONS = [
  `users/${UID}/usage_counter_days`,
  `users/${UID}/usage_counter_totals`,
  `users/${UID}/usage_counter_keys`,
  // The pending-delta queue (crosscut-011) is superseded by the raw usage
  // rescan, so the full rebuild purges it alongside the counters.
  `users/${UID}/pending_counter_deltas`,
];
const WINDOW_KEYS: WindowKey[] = ["today", "7d", "30d", "90d", "all_time"];
const T0 = "2026-06-09T00:00:00.000Z";

function seedHealthyCounters(fake: FakeFirestore): void {
  fake.store.set(ALL_TIME_PATH, {
    requests: 2,
    tokens: 100,
    costUsd: 0.5,
    dailyTokens: { "2026-06-08": 100 },
    updatedAt: T0,
  });
}

describe("refreshUserRollups counter-rebuild gating", () => {
  it("serves a clean job from counters: no recursiveDelete, no usage rescan, computedAt still advances", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: false, dirtiedAt: T0, lastComputedAt: T0 });
    seedHealthyCounters(fake);

    const { rollups, rebuiltCounters } = await refreshUserRollups(fake.asFirestore(), UID);

    expect(rebuiltCounters).toBe(false);
    expect(fake.recursiveDeletes).toEqual([]);
    expect(fake.collectionGets).not.toContain(USAGE_PATH);
    expect(rollups.all_time.totals.tokens).toBe(100);
    // The write-back is what breaks the client polling loop: stale
    // `computedAt` is the clients' rebuild signal.
    for (const key of WINDOW_KEYS) {
      const doc = fake.store.get(`users/${UID}/usage_rollups/${key}`);
      expect(doc).toBeDefined();
      expect(typeof doc?.computedAt).toBe("string");
      expect(doc?.computedAt).not.toBe(T0);
    }
    const job = fake.store.get(JOB_PATH);
    expect(job?.dirty).toBe(false);
    expect(job?.lastComputedAt).not.toBe(T0);
  });

  it("serves a dirty-but-healthy job from counters and clears dirty (mirrors the scheduled worker)", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: true, dirtiedAt: T0 });
    seedHealthyCounters(fake);

    const { rebuiltCounters } = await refreshUserRollups(fake.asFirestore(), UID);

    expect(rebuiltCounters).toBe(false);
    expect(fake.recursiveDeletes).toEqual([]);
    expect(fake.store.get(JOB_PATH)?.dirty).toBe(false);
  });

  it("falls back to the full rebuild when lastErrorCode marks the counters corrupt, then clears it", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: false, dirtiedAt: T0, lastErrorCode: "delta failed" });
    seedHealthyCounters(fake);

    const { rebuiltCounters } = await refreshUserRollups(fake.asFirestore(), UID);

    expect(rebuiltCounters).toBe(true);
    expect(fake.recursiveDeletes).toEqual(COUNTER_COLLECTIONS);
    expect(fake.collectionGets).toContain(USAGE_PATH);
    const job = fake.store.get(JOB_PATH);
    expect(job?.dirty).toBe(false);
    expect(job?.lastErrorCode).toBeUndefined();
  });

  it("force rebuilds healthy counters — the explicit client repair path stays reachable", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: false, dirtiedAt: T0 });
    seedHealthyCounters(fake);

    const { rebuiltCounters } = await refreshUserRollups(fake.asFirestore(), UID, { force: true });

    expect(rebuiltCounters).toBe(true);
    expect(fake.recursiveDeletes).toEqual(COUNTER_COLLECTIONS);
    expect(fake.collectionGets).toContain(USAGE_PATH);
  });

  it("takes the full rebuild path when no job doc exists, then seeds a clean job", async () => {
    const fake = new FakeFirestore();

    const { rebuiltCounters } = await refreshUserRollups(fake.asFirestore(), UID);

    expect(rebuiltCounters).toBe(true);
    expect(fake.recursiveDeletes).toEqual(COUNTER_COLLECTIONS);
    const job = fake.store.get(JOB_PATH);
    expect(job?.dirty).toBe(false);
    expect(typeof job?.lastComputedAt).toBe("string");
  });
});
