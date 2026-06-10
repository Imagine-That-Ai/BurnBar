/**
 * Regression: rollup dirty-flag clear race (crosscut-007).
 *
 * onUsageWritten refreshes the job's `dirtiedAt` marker on EVERY usage event,
 * and `writeUserRollups` clears `dirty` only when `dirtiedAt` still matches
 * the value observed at compute start. Without that guard, an event landing
 * after the worker read the counters but before it committed `dirty: false`
 * was silently dropped from rollups — stale dashboards until the NEXT usage
 * write (the last events of a session were exactly the ones at risk).
 */
import { describe, expect, it } from "vitest";
import { FieldValue, type Firestore } from "firebase-admin/firestore";

import { readRollupJobDirtiedAt, writeUserRollups, type WindowKey } from "../rollups.js";
import type { UsageRollupDoc } from "../types.js";

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

class FakeFirestore {
  readonly store = new Map<string, Doc>();

  doc(path: string) {
    return new FakeDocRef(this.store, path);
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
    return this as unknown as Firestore;
  }
}

const UID = "u1";
const JOB_PATH = `users/${UID}/rollup_jobs/current`;
const WINDOW_KEYS: WindowKey[] = ["today", "7d", "30d", "90d", "all_time"];

function rollupDoc(): UsageRollupDoc {
  return {
    today: 0,
    "7d": 0,
    "30d": 0,
    "90d": 0,
    all_time: 0,
    totals: { requests: 1, tokens: 100, costUsd: 0.01 },
    providerSummaries: [],
    accountSummaries: [],
    modelSummaries: [],
    deviceSummaries: [],
    dailyPoints: {},
    computedAt: new Date().toISOString(),
    schemaVersion: 3,
  };
}

function rollups(): Record<WindowKey, UsageRollupDoc> {
  return {
    today: rollupDoc(),
    "7d": rollupDoc(),
    "30d": rollupDoc(),
    "90d": rollupDoc(),
    all_time: rollupDoc(),
  };
}

describe("writeUserRollups dirty-clear guard", () => {
  it("clears dirty (and lastErrorCode) when no usage event landed mid-compute", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: true, dirtiedAt: "2026-06-09T00:00:00.000Z", lastErrorCode: "boom" });

    const observed = await readRollupJobDirtiedAt(fake.asFirestore(), UID);
    expect(observed).toBe("2026-06-09T00:00:00.000Z");

    await writeUserRollups(fake.asFirestore(), UID, rollups(), observed);

    const job = fake.store.get(JOB_PATH);
    expect(job?.dirty).toBe(false);
    expect(job?.lastErrorCode).toBeUndefined();
    expect(typeof job?.lastComputedAt).toBe("string");
    for (const key of WINDOW_KEYS) {
      expect(fake.store.get(`users/${UID}/usage_rollups/${key}`)).toBeDefined();
    }
  });

  it("keeps the job dirty when a usage event re-marks it mid-compute", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: true, dirtiedAt: "2026-06-09T00:00:00.000Z" });

    const observed = await readRollupJobDirtiedAt(fake.asFirestore(), UID);
    // Simulate onUsageWritten firing between the worker's counter reads and
    // its dirty-clear: every event always merge-sets { dirty, dirtiedAt }.
    await fake.doc(JOB_PATH).set({ dirty: true, dirtiedAt: "2026-06-09T00:00:01.000Z" }, { merge: true });

    await writeUserRollups(fake.asFirestore(), UID, rollups(), observed);

    const job = fake.store.get(JOB_PATH);
    expect(job?.dirty).toBe(true);
    expect(job?.dirtiedAt).toBe("2026-06-09T00:00:01.000Z");
    expect(typeof job?.lastComputedAt).toBe("string");
    // Rollup docs are still written: fresh-but-partial data is fine because
    // the surviving dirty flag schedules a recompute on the next worker pass.
    for (const key of WINDOW_KEYS) {
      expect(fake.store.get(`users/${UID}/usage_rollups/${key}`)).toBeDefined();
    }
  });

  it("preserves a mid-compute lastErrorCode so the next pass falls back to a full rebuild", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: true, dirtiedAt: "2026-06-09T00:00:00.000Z" });

    const observed = await readRollupJobDirtiedAt(fake.asFirestore(), UID);
    await fake
      .doc(JOB_PATH)
      .set({ dirty: true, dirtiedAt: "2026-06-09T00:00:01.000Z", lastErrorCode: "delta failed" }, { merge: true });

    await writeUserRollups(fake.asFirestore(), UID, rollups(), observed);

    const job = fake.store.get(JOB_PATH);
    expect(job?.dirty).toBe(true);
    expect(job?.lastErrorCode).toBe("delta failed");
  });

  it("clears cleanly for a fresh user with no job doc (demo-seed path)", async () => {
    const fake = new FakeFirestore();

    const observed = await readRollupJobDirtiedAt(fake.asFirestore(), UID);
    expect(observed).toBeUndefined();

    await writeUserRollups(fake.asFirestore(), UID, rollups(), observed);

    const job = fake.store.get(JOB_PATH);
    expect(job?.dirty).toBe(false);
    expect(typeof job?.lastComputedAt).toBe("string");
  });
});
