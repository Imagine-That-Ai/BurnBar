/**
 * Characterization test pinning the CURRENT observable behavior of the three
 * functions targeted by the U3 complexity/max-lines refactor of rollups.ts:
 *
 *   - `sameCounterCandidate` (module-private) — exercised through its nearest
 *     exported caller `planPendingDeltaDrain`, whose winner-flip suppression is
 *     driven entirely by `sameCounterCandidate(previousWinner, nextWinner)`.
 *   - `computeUserRollupsFromCounters` (exported) — full counter -> rollup
 *     aggregation across every window key.
 *   - the async transaction arrow inside `beginFullRebuildAttempt` (exported) —
 *     the gate state machine (started / in_flight / circuit_open /
 *     force_cooldown / stale-marker accounting).
 *
 * These are pure relocations in the refactor, so the assertions below must hold
 * byte-for-byte before and after. The in-memory Firestore mirrors the set()
 * merge / FieldValue.increment / nested-increment semantics the production code
 * relies on (same shape used by rollupFullRebuildCircuitBreaker.test.ts).
 */
import { describe, expect, it } from "vitest";
import { FieldValue, type Firestore } from "firebase-admin/firestore";

import {
  beginFullRebuildAttempt,
  buildPendingCounterDelta,
  computeUserRollupsFromCounters,
  FULL_REBUILD_ATTEMPT_STALE_MS,
  planPendingDeltaDrain,
  rebuildUserRollupCounters,
  type UsageCounterCandidate,
} from "../rollups.js";
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
    // is intentionally structural. `Object.create(this)` keeps the same method
    // and store lookup chain without adding a type assertion to the debt budget.
    return Object.create(this);
  }
}

const UID = "u-char";
const JOB_PATH = `users/${UID}/rollup_jobs/current`;
const T0 = "2026-06-09T00:00:00.000Z";
const NOW_ISO = new Date().toISOString();
const GATE = { maxConsecutiveFullRebuildFailures: 3, circuitBreakerMinutes: 60 };
const STALE_MARKER = new Date(Date.now() - FULL_REBUILD_ATTEMPT_STALE_MS - 60_000).toISOString();
const FRESH_MARKER = new Date(Date.now() - 60_000).toISOString();

function codexEvent(overrides: Partial<UsageEventDoc> = {}): UsageEventDoc {
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
    recordedAt: NOW_ISO,
    startTime: NOW_ISO,
    ...overrides,
  };
}

function delta(usageDoc: string, before: UsageEventDoc | undefined, after: UsageEventDoc | undefined) {
  const built = buildPendingCounterDelta(usageDoc, before, after, T0);
  if (!built) throw new Error(`expected a pending delta for ${usageDoc}`);
  return built;
}

function seedUsage(fake: FakeFirestore, count: number, tokens = 10): void {
  for (let i = 0; i < count; i += 1) {
    const id = String(i).padStart(6, "0");
    fake.store.set(`users/${UID}/usage/${id}`, {
      ...codexEvent({
        sessionId: `session-${id}`,
        totalTokens: tokens,
        inputTokens: tokens,
        outputTokens: 0,
        cost: 0.002,
      }),
    });
  }
}

describe("sameCounterCandidate (via planPendingDeltaDrain winner-flip suppression)", () => {
  it("input A: replaying an identical winner is a no-op (sameCounterCandidate => true)", () => {
    const created = delta("doc-1", undefined, codexEvent());
    const firstPlan = planPendingDeltaDrain([created], new Map());
    const keyStates = new Map<string, Record<string, UsageCounterCandidate>>();
    for (const write of firstPlan.keyWrites) keyStates.set(write.logicalKey, write.candidates);

    const replay = planPendingDeltaDrain([created], keyStates);

    // previousWinner deep-equals nextWinner => no signed bucket contributions.
    expect(replay.bucketContributions).toHaveLength(0);
    expect(replay.keyWrites[0].winner?.candidateKey).toBe(firstPlan.keyWrites[0].winner?.candidateKey);
  });

  it("input B: a differing winner is NOT suppressed (sameCounterCandidate => false)", () => {
    const poor = codexEvent({ model: "unknown" });
    const good = codexEvent();
    const seededPlan = planPendingDeltaDrain(
      [delta("doc-poor", undefined, poor), delta("doc-good", undefined, good)],
      new Map(),
    );
    const keyStates = new Map<string, Record<string, UsageCounterCandidate>>();
    for (const write of seededPlan.keyWrites) keyStates.set(write.logicalKey, write.candidates);

    // Remove the winning candidate: winner flips good -> poor, different model
    // bucket identities, so BOTH the negation and the promotion are emitted.
    const plan = planPendingDeltaDrain([delta("doc-good", good, undefined)], keyStates);
    expect(plan.bucketContributions).toHaveLength(2);
    const negated = plan.bucketContributions.find((c) => c.model === "gpt-5.5");
    const promoted = plan.bucketContributions.find((c) => c.model === "unknown");
    expect(negated?.requests).toBe(-1);
    expect(promoted?.requests).toBe(1);
    expect(plan.keyWrites[0].winner?.modelRank).toBe(0);
  });

  it("input C: a winner whose only difference is undefined-vs-defined optional fields is NOT equal", () => {
    // Seed an existing winner that lacks deviceId, then drain a delta that moves
    // the SAME usage doc to carry a deviceId. deviceId is a component of
    // logicalUsageKey, so withoutDevice and withDevice map to two DISTINCT
    // logical keys: the no-device key loses its only candidate (winner =>
    // undefined) while the dev-7 key gains one (winner => dev-7). The
    // before/after winners on each key are undefined-vs-defined, which
    // sameCounterCandidate reports as NOT equal, so both keys flip and emit
    // signed contributions (-old no-device winner, +new dev-7 winner).
    const withoutDevice = codexEvent();
    const withDevice = codexEvent({ deviceId: "dev-7" });
    const seededPlan = planPendingDeltaDrain([delta("doc-1", undefined, withoutDevice)], new Map());
    const keyStates = new Map<string, Record<string, UsageCounterCandidate>>();
    for (const write of seededPlan.keyWrites) keyStates.set(write.logicalKey, write.candidates);

    const plan = planPendingDeltaDrain([delta("doc-1", withoutDevice, withDevice)], keyStates);
    // -old no-device winner and +new dev-7 winner: distinct bucket identities
    // (deviceId differs), so neither cancels — two signed contributions.
    expect(plan.bucketContributions).toHaveLength(2);

    // touchedKeys order is first-touch: delta.before (no-device key) is seeded
    // before delta.after (dev-7 key), so the drained no-device key is index 0
    // with no surviving winner, and the dev-7 key is index 1.
    const noDeviceWrite = plan.keyWrites[0];
    const deviceWrite = plan.keyWrites[1];
    expect(noDeviceWrite.winner).toBeUndefined();
    expect(deviceWrite.winner?.deviceId).toBe("dev-7");
  });
});

describe("computeUserRollupsFromCounters", () => {
  it("input A: empty counters yield zeroed, fully-populated window docs", async () => {
    const fake = new FakeFirestore();
    const rollups = await computeUserRollupsFromCounters(fake.asFirestore(), UID);

    for (const key of ["today", "7d", "30d", "90d", "all_time"] as const) {
      expect(rollups[key].totals).toEqual({ requests: 0, tokens: 0, costUsd: 0 });
      expect(rollups[key].providerSummaries).toEqual([]);
      expect(rollups[key].accountSummaries).toEqual([]);
      expect(rollups[key].modelSummaries).toEqual([]);
      expect(rollups[key].deviceSummaries).toEqual([]);
      expect(rollups[key].executionSourceSummaries).toEqual([]);
      expect(rollups[key].comboSummaries).toEqual([]);
      expect(rollups[key].dailyPoints).toEqual({});
      expect(rollups[key].schemaVersion).toBe(3);
      expect(typeof rollups[key].computedAt).toBe("string");
    }
    expect(rollups.today.today).toBe(0);
    expect(rollups.all_time.all_time).toBe(0);
  });

  it("input B: a populated history aggregates totals/providers/accounts/models across windows", async () => {
    const fake = new FakeFirestore();
    seedUsage(fake, 3, 10);
    await rebuildUserRollupCounters(fake.asFirestore(), UID, { pageSize: 500 });

    const rollups = await computeUserRollupsFromCounters(fake.asFirestore(), UID);

    expect(rollups.all_time.totals.requests).toBe(3);
    expect(rollups.all_time.totals.tokens).toBe(30);
    expect(rollups.all_time.totals.costUsd).toBeCloseTo(0.006, 9);
    expect(rollups.all_time.all_time).toBe(30);
    // Same-day usage => today window mirrors all_time totals.
    expect(rollups.today.totals.requests).toBe(3);
    expect(rollups.today.today).toBe(30);

    const provider = rollups.all_time.providerSummaries.find((p) => p.provider === "codex");
    expect(provider?.totalRequests).toBe(3);
    expect(provider?.totalTokens).toBe(30);

    const model = rollups.all_time.modelSummaries.find((m) => m.model === "gpt-5.5");
    expect(model?.requests).toBe(3);
    expect(model?.tokens).toBe(30);

    // Three distinct sessions => three distinct unattributed accounts collapse
    // by accountID; with no providerAccountID each maps to codex:unattributed.
    const accountSummaries = rollups.all_time.accountSummaries;
    expect(accountSummaries).toBeDefined();
    expect(accountSummaries).toHaveLength(1);
    expect(accountSummaries?.[0].id).toBe("codex:unattributed");
    expect(accountSummaries?.[0].totalRequests).toBe(3);

    // dailyPoints carries the single populated UTC day with nonzero tokens.
    expect(Object.values(rollups.all_time.dailyPoints)).toContain(30);
  });
});

describe("beginFullRebuildAttempt (gate transaction state machine)", () => {
  it("input A: a clean job claims the attempt and stamps an in-flight marker", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: false, dirtiedAt: T0 });

    const gate = await beginFullRebuildAttempt(fake.asFirestore(), UID, GATE);

    expect(gate).toEqual({ status: "started", countedStaleAttempt: false });
    const job = fake.store.get(JOB_PATH);
    expect(Date.parse(String(job?.fullRebuildAttemptInFlightAt))).toBeGreaterThan(Date.now() - 5_000);
  });

  it("input B: a fresh in-flight marker is refused as in_flight without mutating the counter", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: true, lastErrorCode: "x", fullRebuildAttemptInFlightAt: FRESH_MARKER });

    const gate = await beginFullRebuildAttempt(fake.asFirestore(), UID, GATE);

    expect(gate).toEqual({ status: "in_flight", attemptStartedAt: FRESH_MARKER });
    expect(fake.store.get(JOB_PATH)?.consecutiveFullRebuildFailures).toBeUndefined();
  });

  it("input C: a stale marker at the ceiling is counted and opens the breaker", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, {
      dirty: true,
      lastErrorCode: "x",
      consecutiveFullRebuildFailures: 2,
      fullRebuildAttemptInFlightAt: STALE_MARKER,
    });

    const gate = await beginFullRebuildAttempt(fake.asFirestore(), UID, GATE);

    expect(gate.status).toBe("circuit_open");
    const job = fake.store.get(JOB_PATH);
    expect(job?.consecutiveFullRebuildFailures).toBe(3);
    expect(job?.fullRebuildAttemptInFlightAt).toBeUndefined();
    expect(Date.parse(String(job?.fullRebuildCircuitOpenUntil))).toBeGreaterThan(Date.now());
  });

  it("input D: a force cooldown inside the interval is refused with the computed retryAt", async () => {
    const fake = new FakeFirestore();
    const lastForceAt = new Date(Date.now() - 60_000).toISOString();
    fake.store.set(JOB_PATH, { dirty: false, dirtiedAt: T0, lastForceRebuildAt: lastForceAt });

    const gate = await beginFullRebuildAttempt(fake.asFirestore(), UID, {
      ...GATE,
      forceMinIntervalMillis: 10 * 60 * 1000,
    });

    expect(gate).toEqual({
      status: "force_cooldown",
      retryAt: new Date(Date.parse(lastForceAt) + 10 * 60 * 1000).toISOString(),
    });
  });
});
